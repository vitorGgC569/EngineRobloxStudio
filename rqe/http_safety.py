"""Bounded response decoding shared by every outbound HTTP adapter."""

from __future__ import annotations

import json
from typing import Any


class HttpBoundaryError(ValueError):
    pass


def read_limited(response: Any, maximum: int, *, label: str = "HTTP response") -> bytes:
    if maximum < 1:
        raise ValueError("maximum must be positive")
    headers = getattr(response, "headers", None)
    declared = headers.get("Content-Length") if headers is not None else None
    if declared is not None:
        try:
            length = int(declared)
        except (TypeError, ValueError) as exc:
            raise HttpBoundaryError(f"{label} has an invalid Content-Length") from exc
        if length < 0:
            raise HttpBoundaryError(f"{label} has a negative Content-Length")
        if length > maximum:
            raise HttpBoundaryError(f"{label} exceeds the {maximum}-byte limit")
    payload = response.read(maximum + 1)
    if len(payload) > maximum:
        raise HttpBoundaryError(f"{label} exceeds the {maximum}-byte limit")
    return payload


def json_limited(response: Any, maximum: int, *, label: str = "HTTP response") -> Any:
    payload = read_limited(response, maximum, label=label)
    try:
        return json.loads(payload.decode("utf-8"))
    except UnicodeDecodeError as exc:
        raise HttpBoundaryError(f"{label} is not valid UTF-8") from exc
    except json.JSONDecodeError as exc:
        raise HttpBoundaryError(f"{label} is not valid JSON") from exc


def json_object_limited(response: Any, maximum: int, *, label: str = "HTTP response") -> dict[str, Any]:
    value = json_limited(response, maximum, label=label)
    if not isinstance(value, dict):
        raise HttpBoundaryError(f"{label} must be a JSON object")
    return value


def text_limited(
    response: Any,
    maximum: int,
    *,
    label: str = "HTTP response",
    errors: str = "strict",
) -> str:
    payload = read_limited(response, maximum, label=label)
    try:
        return payload.decode("utf-8", errors=errors)
    except UnicodeDecodeError as exc:
        raise HttpBoundaryError(f"{label} is not valid UTF-8") from exc


def error_body_limited(error: Any, maximum: int = 4096) -> bytes:
    """Read a small diagnostic from HTTPError without trusting its length."""

    try:
        return error.read(maximum + 1)[:maximum]
    except Exception:
        return b""
