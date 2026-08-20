"""OpenAI Responses API adapter for :class:`rqe.visual_review.VisionProvider`.

The adapter intentionally uses only the Python standard library.  Credentials
are read exclusively from ``OPENAI_API_KEY`` and are never copied into request
metadata, returned values, errors, or artifacts.  The engine remains the final
validator of rubric coverage and citations; this module only turns a complete,
strictly structured Responses API result into a provider mapping.
"""

from __future__ import annotations

import base64
import copy
import hashlib
import json
import os
import urllib.error
import urllib.request
from collections.abc import Mapping
from typing import Any, Protocol

from .schema_validation import SchemaDefinitionError, validate_schema_instance
from .visual_review import ReviewRequest, VisualReviewError


OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses"
OPENAI_PROVIDER_NAME = "openai-responses"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
_IMAGE_DETAILS = {"auto", "low", "high", "original"}


class OpenAIResponsesError(VisualReviewError):
    """A fail-closed provider failure with a stable machine-readable code."""

    def __init__(self, code: str, message: str, *, status: str = "INCONCLUSIVE") -> None:
        super().__init__(message)
        self.code = code
        self.status = status

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": OPENAI_PROVIDER_NAME,
            "status": self.status,
            "validationLevel": "NOT_VALIDATED",
            "reasonCode": self.code,
            "reason": str(self),
            "authorizesRelease": False,
        }


class JsonPostTransport(Protocol):
    """Injectable HTTP boundary used by the provider and transport tests."""

    def post_json(
        self,
        url: str,
        *,
        headers: Mapping[str, str],
        payload: Mapping[str, Any],
        timeout_seconds: float,
    ) -> Mapping[str, Any]: ...


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON constant {value!r} is forbidden")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _strict_json_loads(raw: str) -> Any:
    return json.loads(
        raw,
        object_pairs_hook=_reject_duplicate_keys,
        parse_constant=_reject_constant,
    )


class StdlibJsonPostTransport:
    """Small, non-streaming JSON transport for ``POST /v1/responses``."""

    def post_json(
        self,
        url: str,
        *,
        headers: Mapping[str, str],
        payload: Mapping[str, Any],
        timeout_seconds: float,
    ) -> Mapping[str, Any]:
        try:
            encoded = json.dumps(
                payload,
                ensure_ascii=False,
                allow_nan=False,
                separators=(",", ":"),
            ).encode("utf-8")
        except (TypeError, ValueError) as exc:
            raise OpenAIResponsesError(
                "OPENAI_REQUEST_ENCODING_FAILED",
                f"OpenAI request could not be encoded: {type(exc).__name__}",
            ) from exc

        request = urllib.request.Request(
            url,
            data=encoded,
            headers=dict(headers),
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                status_code = int(getattr(response, "status", 200))
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as exc:
            # Do not include a response body or request headers: either may echo
            # user content or credentials through an intermediary.
            raise OpenAIResponsesError(
                "OPENAI_HTTP_ERROR",
                f"OpenAI Responses API returned HTTP {exc.code}",
                status="BLOCKED",
            ) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise OpenAIResponsesError(
                "OPENAI_TRANSPORT_FAILED",
                f"OpenAI Responses API transport failed: {type(exc).__name__}",
                status="BLOCKED",
            ) from exc

        if status_code < 200 or status_code >= 300:
            raise OpenAIResponsesError(
                "OPENAI_HTTP_ERROR",
                f"OpenAI Responses API returned HTTP {status_code}",
                status="BLOCKED",
            )
        if len(raw) > MAX_RESPONSE_BYTES:
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_TOO_LARGE",
                "OpenAI Responses API response exceeded the configured safety limit",
            )
        try:
            decoded = raw.decode("utf-8")
            result = _strict_json_loads(decoded)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_NOT_JSON",
                f"OpenAI Responses API returned malformed JSON: {type(exc).__name__}",
            ) from exc
        if not isinstance(result, Mapping):
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_NOT_OBJECT",
                "OpenAI Responses API response must be a JSON object",
            )
        return result


class OpenAIResponsesVisionProvider:
    """Real, optional vision provider backed by the OpenAI Responses API.

    ``model`` is mandatory so a caller cannot silently inherit a moving or
    capability-incompatible default.  ``environ`` and ``transport`` exist for
    deterministic tests; even with an injected mapping, the only credential
    key consulted is ``OPENAI_API_KEY``.
    """

    name = OPENAI_PROVIDER_NAME

    def __init__(
        self,
        *,
        model: str,
        timeout_seconds: float = 120.0,
        image_detail: str = "high",
        transport: JsonPostTransport | None = None,
        environ: Mapping[str, str] | None = None,
    ) -> None:
        if not isinstance(model, str) or not model.strip():
            raise ValueError("OpenAI vision model must be explicitly configured")
        if isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, (int, float)):
            raise ValueError("OpenAI timeout_seconds must be numeric")
        if timeout_seconds <= 0 or timeout_seconds > 600:
            raise ValueError("OpenAI timeout_seconds must be greater than 0 and at most 600")
        if image_detail not in _IMAGE_DETAILS:
            raise ValueError(f"OpenAI image_detail must be one of {sorted(_IMAGE_DETAILS)}")

        environment = os.environ if environ is None else environ
        api_key = environment.get("OPENAI_API_KEY")
        self.model = model.strip()
        self.timeout_seconds = float(timeout_seconds)
        self.image_detail = image_detail
        self._api_key = api_key.strip() if isinstance(api_key, str) else ""
        self._transport = transport or StdlibJsonPostTransport()

    @property
    def configured(self) -> bool:
        return bool(self._api_key)

    def review(self, request: ReviewRequest) -> Mapping[str, Any]:
        if not self._api_key:
            raise OpenAIResponsesError(
                "OPENAI_API_KEY_MISSING",
                "OpenAI visual review is blocked because OPENAI_API_KEY is not configured",
                status="BLOCKED",
            )

        payload = self._build_payload(request)
        headers = {
            "Authorization": f"Bearer {self._api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "rqe-openai-vision/1",
        }
        try:
            raw = self._transport.post_json(
                OPENAI_RESPONSES_URL,
                headers=headers,
                payload=payload,
                timeout_seconds=self.timeout_seconds,
            )
        except OpenAIResponsesError:
            raise
        except Exception as exc:
            # The injected boundary is untrusted too.  Report its type, not its
            # message, because arbitrary transports may include Authorization.
            raise OpenAIResponsesError(
                "OPENAI_TRANSPORT_FAILED",
                f"OpenAI Responses API transport failed: {type(exc).__name__}",
                status="BLOCKED",
            ) from exc
        return self._parse_response(raw, request)

    def _build_payload(self, request: ReviewRequest) -> dict[str, Any]:
        if not isinstance(request, ReviewRequest):
            raise OpenAIResponsesError(
                "OPENAI_REQUEST_INVALID",
                "OpenAI visual review requires an RQE ReviewRequest",
            )
        if not request.images:
            raise OpenAIResponsesError(
                "OPENAI_REQUEST_HAS_NO_IMAGES",
                "OpenAI visual review requires at least one integrity-checked image",
            )
        image_ids: set[str] = set()
        for image in request.images:
            if not isinstance(image.id, str) or not image.id or image.id in image_ids:
                raise OpenAIResponsesError(
                    "OPENAI_REQUEST_IMAGE_ID_INVALID",
                    "OpenAI visual review image ids must be non-empty and unique",
                )
            image_ids.add(image.id)
            if not isinstance(image.data, bytes) or not image.data:
                raise OpenAIResponsesError(
                    "OPENAI_REQUEST_IMAGE_INVALID",
                    f"OpenAI visual review image {image.id!r} has no bytes",
                )
            if not isinstance(image.mime_type, str) or not image.mime_type.startswith("image/"):
                raise OpenAIResponsesError(
                    "OPENAI_REQUEST_IMAGE_INVALID",
                    f"OpenAI visual review image {image.id!r} has an invalid MIME type",
                )
            actual_hash = hashlib.sha256(image.data).hexdigest()
            if image.sha256 != actual_hash:
                raise OpenAIResponsesError(
                    "OPENAI_REQUEST_IMAGE_HASH_MISMATCH",
                    f"OpenAI visual review image hash differs for shot {image.id!r}",
                )
        if set(request.rubric_by_viewpoint) != image_ids:
            raise OpenAIResponsesError(
                "OPENAI_REQUEST_RUBRIC_COVERAGE_INVALID",
                "OpenAI visual review rubric viewpoints must exactly match image ids",
            )

        evidence_index = {
            "rubricByViewpoint": {
                viewpoint: list(criteria)
                for viewpoint, criteria in request.rubric_by_viewpoint.items()
            },
            "shots": [
                {
                    "shotId": image.id,
                    "sha256": image.sha256,
                    "mimeType": image.mime_type,
                    "bytes": len(image.data),
                    "metadata": image.metadata,
                }
                for image in request.images
            ],
        }
        content: list[dict[str, Any]] = [
            {
                "type": "input_text",
                "text": (
                    request.prompt
                    + "\n\nRQE evidence index (shot ids and hashes are authoritative):\n"
                    + json.dumps(
                        evidence_index,
                        sort_keys=True,
                        separators=(",", ":"),
                        ensure_ascii=False,
                    )
                ),
            }
        ]
        for image in request.images:
            encoded = base64.b64encode(image.data).decode("ascii")
            content.extend(
                (
                    {
                        "type": "input_text",
                        "text": f"Image for shotId={image.id}; sha256={image.sha256}",
                    },
                    {
                        "type": "input_image",
                        "image_url": f"data:{image.mime_type};base64,{encoded}",
                        "detail": self.image_detail,
                    },
                )
            )

        return {
            "model": self.model,
            "store": False,
            "input": [{"role": "user", "content": content}],
            "text": {
                "format": {
                    "type": "json_schema",
                    "name": "rqe_visual_review",
                    "schema": copy.deepcopy(request.response_schema),
                    "strict": True,
                }
            },
        }

    def _parse_response(
        self,
        raw: Mapping[str, Any],
        request: ReviewRequest,
    ) -> Mapping[str, Any]:
        if not isinstance(raw, Mapping):
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_NOT_OBJECT",
                "OpenAI Responses API response must be a JSON object",
            )
        if raw.get("error") is not None:
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_ERROR",
                "OpenAI Responses API returned an error object",
                status="BLOCKED",
            )
        if isinstance(raw.get("refusal"), str) and raw.get("refusal"):
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_REFUSAL",
                "OpenAI Responses API refused the visual review request",
            )
        status = raw.get("status")
        if status != "completed":
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_INCOMPLETE",
                "OpenAI Responses API response was not completed",
            )
        if raw.get("incomplete_details") is not None:
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_INCOMPLETE",
                "OpenAI Responses API returned incomplete_details on a completed response",
            )

        output = raw.get("output")
        if not isinstance(output, list):
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_OUTPUT_INVALID",
                "OpenAI Responses API response output must be an array",
            )

        text_parts: list[str] = []
        for output_index, item in enumerate(output):
            if not isinstance(item, Mapping):
                raise OpenAIResponsesError(
                    "OPENAI_RESPONSE_OUTPUT_INVALID",
                    f"OpenAI response output[{output_index}] must be an object",
                )
            if item.get("type") == "reasoning":
                continue
            if item.get("type") != "message":
                raise OpenAIResponsesError(
                    "OPENAI_RESPONSE_OUTPUT_INVALID",
                    "OpenAI response contained an unexpected output type",
                )
            item_status = item.get("status")
            if item_status is not None and item_status != "completed":
                raise OpenAIResponsesError(
                    "OPENAI_RESPONSE_INCOMPLETE",
                    f"OpenAI response message[{output_index}] was not completed",
                )
            content = item.get("content")
            if not isinstance(content, list):
                raise OpenAIResponsesError(
                    "OPENAI_RESPONSE_OUTPUT_INVALID",
                    f"OpenAI response message[{output_index}].content must be an array",
                )
            for content_index, part in enumerate(content):
                if not isinstance(part, Mapping):
                    raise OpenAIResponsesError(
                        "OPENAI_RESPONSE_OUTPUT_INVALID",
                        f"OpenAI response content[{output_index}][{content_index}] must be an object",
                    )
                part_type = part.get("type")
                if part_type == "refusal" or (
                    isinstance(part.get("refusal"), str) and part.get("refusal")
                ):
                    raise OpenAIResponsesError(
                        "OPENAI_RESPONSE_REFUSAL",
                        "OpenAI Responses API refused the visual review request",
                    )
                if part_type != "output_text":
                    raise OpenAIResponsesError(
                        "OPENAI_RESPONSE_OUTPUT_INVALID",
                        "OpenAI response contained unsupported message content",
                    )
                text = part.get("text")
                if not isinstance(text, str) or not text:
                    raise OpenAIResponsesError(
                        "OPENAI_RESPONSE_OUTPUT_INVALID",
                        "OpenAI response output_text must contain non-empty text",
                    )
                text_parts.append(text)

        joined = "".join(text_parts)
        shortcut = raw.get("output_text")
        if not joined and isinstance(shortcut, str):
            joined = shortcut
        elif isinstance(shortcut, str) and shortcut != joined:
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_OUTPUT_MISMATCH",
                "OpenAI response output_text disagrees with message content",
            )
        if not joined:
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_HAS_NO_TEXT",
                "OpenAI Responses API returned no output_text",
            )

        try:
            parsed = _strict_json_loads(joined)
        except (json.JSONDecodeError, ValueError) as exc:
            raise OpenAIResponsesError(
                "OPENAI_OUTPUT_TEXT_NOT_JSON",
                f"OpenAI output_text was not strict JSON: {type(exc).__name__}",
            ) from exc
        if not isinstance(parsed, Mapping):
            raise OpenAIResponsesError(
                "OPENAI_OUTPUT_TEXT_NOT_OBJECT",
                "OpenAI output_text must decode to a JSON object",
            )
        try:
            issues = validate_schema_instance(dict(parsed), request.response_schema)
        except SchemaDefinitionError as exc:
            raise OpenAIResponsesError(
                "OPENAI_RESPONSE_SCHEMA_UNSUPPORTED",
                f"RQE provider response schema is unsupported: {type(exc).__name__}",
            ) from exc
        if issues:
            raise OpenAIResponsesError(
                "OPENAI_OUTPUT_SCHEMA_MISMATCH",
                "OpenAI output_text did not satisfy the requested JSON schema",
            )
        return dict(parsed)


__all__ = [
    "JsonPostTransport",
    "OPENAI_PROVIDER_NAME",
    "OPENAI_RESPONSES_URL",
    "OpenAIResponsesError",
    "OpenAIResponsesVisionProvider",
    "StdlibJsonPostTransport",
]
