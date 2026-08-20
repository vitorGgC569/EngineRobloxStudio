from __future__ import annotations

import base64
import hashlib
import io
import json
import unittest
import urllib.error
from collections.abc import Mapping
from typing import Any
from unittest.mock import patch

from rqe.openai_vision import (
    OPENAI_RESPONSES_URL,
    OpenAIResponsesError,
    OpenAIResponsesVisionProvider,
    StdlibJsonPostTransport,
)
from rqe.visual_review import PROVIDER_RESPONSE_SCHEMA, ReviewImage, ReviewRequest


SHOT_ID = "world-overview"
CRITERIA = ("composition", "finish")
PNG_BYTES = b"\x89PNG\r\n\x1a\nnot-a-real-png-but-exact-provider-bytes"
PNG_HASH = hashlib.sha256(PNG_BYTES).hexdigest()
SECRET = "sk-test-never-persist-this-value"


def _request(*, image_hash: str = PNG_HASH) -> ReviewRequest:
    return ReviewRequest(
        run_id="run-openai-provider",
        build_hash="a" * 64,
        place_hash="b" * 64,
        spec_hash="c" * 64,
        capture_manifest_sha256="d" * 64,
        prompt="Judge only visible evidence and cite the supplied shot id.",
        prompt_hash="e" * 64,
        rubric_by_viewpoint={SHOT_ID: CRITERIA},
        images=(
            ReviewImage(
                id=SHOT_ID,
                mime_type="image/png",
                data=PNG_BYTES,
                sha256=image_hash,
                metadata={"width": 32, "height": 24},
            ),
        ),
    )


def _provider_result() -> dict[str, Any]:
    return {
        "assessments": [
            {
                "viewpoint": SHOT_ID,
                "rubric": [
                    {
                        "criterion": criterion,
                        "grade": 4,
                        "rationale": f"Visible {criterion} is coherent but not exceptional.",
                        "evidence": {"shotIds": [SHOT_ID]},
                    }
                    for criterion in CRITERIA
                ],
            }
        ],
        "findings": [],
    }


def _api_response(result: Mapping[str, Any] | None = None) -> dict[str, Any]:
    text = json.dumps(dict(result or _provider_result()), separators=(",", ":"))
    return {
        "id": "resp_test",
        "status": "completed",
        "error": None,
        "incomplete_details": None,
        "output": [
            {
                "type": "message",
                "status": "completed",
                "content": [{"type": "output_text", "text": text}],
            }
        ],
    }


class FakeTransport:
    def __init__(self, response: Mapping[str, Any] | None = None, error: Exception | None = None) -> None:
        self.response = response if response is not None else _api_response()
        self.error = error
        self.calls: list[dict[str, Any]] = []

    def post_json(self, url, *, headers, payload, timeout_seconds):
        self.calls.append(
            {
                "url": url,
                "headers": dict(headers),
                "payload": payload,
                "timeoutSeconds": timeout_seconds,
            }
        )
        if self.error is not None:
            raise self.error
        return self.response


class OpenAIResponsesVisionProviderTests(unittest.TestCase):
    def provider(self, transport: FakeTransport, *, environ: Mapping[str, str] | None = None):
        return OpenAIResponsesVisionProvider(
            model="explicit-vision-model",
            transport=transport,
            environ={"OPENAI_API_KEY": SECRET} if environ is None else environ,
        )

    def test_payload_uses_responses_structured_output_and_exact_data_url(self) -> None:
        transport = FakeTransport()
        provider = self.provider(transport)

        result = provider.review(_request())

        self.assertEqual(result, _provider_result())
        self.assertEqual(len(transport.calls), 1)
        call = transport.calls[0]
        self.assertEqual(call["url"], OPENAI_RESPONSES_URL)
        self.assertEqual(call["headers"]["Authorization"], f"Bearer {SECRET}")
        payload = call["payload"]
        self.assertEqual(payload["model"], "explicit-vision-model")
        self.assertIs(payload["store"], False)
        response_format = payload["text"]["format"]
        self.assertEqual(response_format["type"], "json_schema")
        self.assertEqual(response_format["name"], "rqe_visual_review")
        self.assertIs(response_format["strict"], True)
        self.assertEqual(response_format["schema"], PROVIDER_RESPONSE_SCHEMA)

        content = payload["input"][0]["content"]
        image_part = next(item for item in content if item["type"] == "input_image")
        prefix, encoded = image_part["image_url"].split(",", 1)
        self.assertEqual(prefix, "data:image/png;base64")
        self.assertEqual(base64.b64decode(encoded), PNG_BYTES)
        text_parts = "\n".join(
            item["text"] for item in content if item["type"] == "input_text"
        )
        self.assertIn(SHOT_ID, text_parts)
        self.assertIn(PNG_HASH, text_parts)
        self.assertNotIn(SECRET, json.dumps(payload))

    def test_missing_only_supported_environment_key_is_explicitly_blocked(self) -> None:
        transport = FakeTransport()
        provider = self.provider(
            transport,
            environ={
                "OPENAI_TOKEN": SECRET,
                "RQE_OPENAI_API_KEY": SECRET,
            },
        )

        with self.assertRaises(OpenAIResponsesError) as caught:
            provider.review(_request())

        self.assertEqual(caught.exception.code, "OPENAI_API_KEY_MISSING")
        self.assertEqual(caught.exception.status, "BLOCKED")
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertEqual(transport.calls, [])

    def test_incomplete_response_is_never_accepted_as_visual_evidence(self) -> None:
        transport = FakeTransport(
            {
                "status": "incomplete",
                "error": None,
                "incomplete_details": {"reason": "max_output_tokens"},
                "output": [],
            }
        )
        with self.assertRaises(OpenAIResponsesError) as caught:
            self.provider(transport).review(_request())
        self.assertEqual(caught.exception.code, "OPENAI_RESPONSE_INCOMPLETE")

    def test_refusal_is_never_parsed_as_structured_visual_evidence(self) -> None:
        transport = FakeTransport(
            {
                "status": "completed",
                "error": None,
                "output": [
                    {
                        "type": "message",
                        "content": [{"type": "refusal", "refusal": "Cannot review."}],
                    }
                ],
            }
        )
        with self.assertRaises(OpenAIResponsesError) as caught:
            self.provider(transport).review(_request())
        self.assertEqual(caught.exception.code, "OPENAI_RESPONSE_REFUSAL")

    def test_malformed_or_duplicate_json_output_is_rejected(self) -> None:
        for output_text in ("{not-json", '{"assessments":[],"assessments":[],"findings":[]}'):
            with self.subTest(output_text=output_text):
                response = _api_response()
                response["output"][0]["content"][0]["text"] = output_text
                with self.assertRaises(OpenAIResponsesError) as caught:
                    self.provider(FakeTransport(response)).review(_request())
                self.assertEqual(caught.exception.code, "OPENAI_OUTPUT_TEXT_NOT_JSON")

    def test_structurally_invalid_json_is_rejected_before_engine_scoring(self) -> None:
        response = _api_response({"assessments": "not-an-array", "findings": []})
        with self.assertRaises(OpenAIResponsesError) as caught:
            self.provider(FakeTransport(response)).review(_request())
        self.assertEqual(caught.exception.code, "OPENAI_OUTPUT_SCHEMA_MISMATCH")

    def test_image_hash_mismatch_never_reaches_transport(self) -> None:
        transport = FakeTransport()
        with self.assertRaises(OpenAIResponsesError) as caught:
            self.provider(transport).review(_request(image_hash="f" * 64))
        self.assertEqual(caught.exception.code, "OPENAI_REQUEST_IMAGE_HASH_MISMATCH")
        self.assertEqual(transport.calls, [])

    def test_untrusted_transport_exception_cannot_echo_the_api_key(self) -> None:
        transport = FakeTransport(error=RuntimeError(f"bad header Bearer {SECRET}"))
        with self.assertRaises(OpenAIResponsesError) as caught:
            self.provider(transport).review(_request())
        self.assertEqual(caught.exception.code, "OPENAI_TRANSPORT_FAILED")
        self.assertNotIn(SECRET, str(caught.exception))

    def test_model_has_no_implicit_default(self) -> None:
        with self.assertRaisesRegex(ValueError, "explicitly configured"):
            OpenAIResponsesVisionProvider(model="", environ={})


class StdlibResponsesTransportTests(unittest.TestCase):
    def test_stdlib_transport_posts_json_without_an_sdk_dependency(self) -> None:
        class Response:
            status = 200

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _limit):
                return json.dumps(_api_response()).encode("utf-8")

        captured = []

        def urlopen(request, timeout):
            captured.append((request, timeout))
            return Response()

        with patch("rqe.openai_vision.urllib.request.urlopen", side_effect=urlopen):
            result = StdlibJsonPostTransport().post_json(
                OPENAI_RESPONSES_URL,
                headers={"Authorization": f"Bearer {SECRET}", "Content-Type": "application/json"},
                payload={"model": "explicit-model", "input": []},
                timeout_seconds=17,
            )

        self.assertEqual(result["status"], "completed")
        request, timeout = captured[0]
        self.assertEqual(request.full_url, OPENAI_RESPONSES_URL)
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(timeout, 17)
        self.assertEqual(
            json.loads(request.data.decode("utf-8")),
            {"model": "explicit-model", "input": []},
        )

    def test_http_error_body_cannot_echo_credentials_into_error_or_receipt(self) -> None:
        error = urllib.error.HTTPError(
            OPENAI_RESPONSES_URL,
            401,
            "unauthorized",
            {},
            io.BytesIO(f"echoed {SECRET}".encode("utf-8")),
        )
        with patch("rqe.openai_vision.urllib.request.urlopen", side_effect=error):
            with self.assertRaises(OpenAIResponsesError) as caught:
                StdlibJsonPostTransport().post_json(
                    OPENAI_RESPONSES_URL,
                    headers={"Authorization": f"Bearer {SECRET}"},
                    payload={"model": "explicit-model"},
                    timeout_seconds=17,
                )
        self.assertEqual(caught.exception.code, "OPENAI_HTTP_ERROR")
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertNotIn(SECRET, json.dumps(caught.exception.to_dict()))


if __name__ == "__main__":
    unittest.main()
