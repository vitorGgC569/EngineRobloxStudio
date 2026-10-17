"""Small injectable HTTP boundary for asset providers.

Production code uses :class:`UrllibTransport`; tests use a scripted transport.
Keeping the boundary byte-oriented lets multipart requests be verified without
ever contacting Roblox or exposing credentials in test output.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Mapping, Protocol

from ..http_safety import HttpBoundaryError, error_body_limited, read_limited


MAX_HTTP_RESPONSE_BYTES = 4 * 1024 * 1024


@dataclass(frozen=True)
class HttpRequest:
    method: str
    url: str
    headers: Mapping[str, str] = field(default_factory=dict)
    body: bytes | None = None
    timeout_seconds: float = 30.0


@dataclass(frozen=True)
class HttpResponse:
    status: int
    headers: Mapping[str, str] = field(default_factory=dict)
    body: bytes = b""

    def json(self) -> object:
        if not self.body:
            return {}
        return json.loads(self.body.decode("utf-8"))


class HttpTransport(Protocol):
    def send(self, request: HttpRequest) -> HttpResponse: ...


class UrllibTransport:
    """Synchronous stdlib transport with HTTP errors returned as responses."""

    def send(self, request: HttpRequest) -> HttpResponse:
        raw = urllib.request.Request(
            request.url,
            data=request.body,
            headers=dict(request.headers),
            method=request.method.upper(),
        )
        try:
            with urllib.request.urlopen(raw, timeout=request.timeout_seconds) as response:
                return HttpResponse(
                    status=int(response.status),
                    headers=dict(response.headers.items()),
                    body=read_limited(response, MAX_HTTP_RESPONSE_BYTES, label="asset provider response"),
                )
        except urllib.error.HTTPError as exc:
            return HttpResponse(
                status=int(exc.code),
                headers=dict(exc.headers.items()) if exc.headers else {},
                body=error_body_limited(exc, MAX_HTTP_RESPONSE_BYTES),
            )
        except HttpBoundaryError:
            raise


def json_body(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def multipart_body(
    *,
    request_payload: Mapping[str, object],
    filename: str,
    content_type: str,
    content: bytes,
    boundary: str,
) -> bytes:
    """Build the two-part form required by Roblox's Create Asset endpoint."""

    safe_filename = filename.replace('"', "_").replace("\r", "_").replace("\n", "_")
    request_json = json_body(request_payload)
    chunks = [
        f"--{boundary}\r\n".encode("ascii"),
        b'Content-Disposition: form-data; name="request"\r\n',
        b"Content-Type: application/json\r\n\r\n",
        request_json,
        b"\r\n",
        f"--{boundary}\r\n".encode("ascii"),
        (
            'Content-Disposition: form-data; name="fileContent"; '
            f'filename="{safe_filename}"\r\n'
        ).encode("utf-8"),
        f"Content-Type: {content_type}\r\n\r\n".encode("ascii"),
        content,
        b"\r\n",
        f"--{boundary}--\r\n".encode("ascii"),
    ]
    return b"".join(chunks)
