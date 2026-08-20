"""Deterministic test doubles for asset providers and HTTP adapters."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

from .http import HttpRequest, HttpResponse


@dataclass
class FakeHttpTransport:
    responses: deque[HttpResponse] = field(default_factory=deque)
    requests: list[HttpRequest] = field(default_factory=list)

    def queue_json(
        self,
        status: int,
        payload: object,
        headers: dict[str, str] | None = None,
    ) -> None:
        import json

        self.responses.append(
            HttpResponse(
                status=status,
                headers=headers or {"content-type": "application/json"},
                body=json.dumps(payload).encode("utf-8"),
            )
        )

    def send(self, request: HttpRequest) -> HttpResponse:
        self.requests.append(request)
        if not self.responses:
            raise AssertionError(f"unexpected HTTP request: {request.method} {request.url}")
        return self.responses.popleft()
