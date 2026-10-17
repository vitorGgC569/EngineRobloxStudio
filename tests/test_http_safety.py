from __future__ import annotations

import io
import unittest

from rqe.http_safety import (
    HttpBoundaryError,
    error_body_limited,
    json_limited,
    json_object_limited,
    read_limited,
    text_limited,
)


class FakeResponse(io.BytesIO):
    def __init__(self, payload: bytes, content_length: str | None = None) -> None:
        super().__init__(payload)
        self.headers = {}
        if content_length is not None:
            self.headers["Content-Length"] = content_length


class HttpSafetyTests(unittest.TestCase):
    def test_declared_response_larger_than_limit_is_rejected_before_read(self) -> None:
        response = FakeResponse(b"small", "101")
        with self.assertRaises(HttpBoundaryError):
            read_limited(response, 100)
        self.assertEqual(response.tell(), 0)

    def test_streamed_response_larger_than_limit_is_rejected(self) -> None:
        with self.assertRaises(HttpBoundaryError):
            read_limited(FakeResponse(b"x" * 101), 100)

    def test_invalid_content_length_is_rejected(self) -> None:
        with self.assertRaises(HttpBoundaryError):
            read_limited(FakeResponse(b"{}", "not-an-integer"), 100)

    def test_json_must_be_utf8_object_or_value(self) -> None:
        self.assertEqual(json_limited(FakeResponse(b'{"ok":true}'), 100), {"ok": True})
        with self.assertRaises(HttpBoundaryError):
            json_limited(FakeResponse(b"\xff"), 100)
        with self.assertRaises(HttpBoundaryError):
            json_limited(FakeResponse(b"not-json"), 100)

    def test_object_decoder_rejects_valid_non_object_json(self) -> None:
        with self.assertRaises(HttpBoundaryError):
            json_object_limited(FakeResponse(b"[]"), 100)

    def test_text_decoder_is_bounded_and_utf8_strict_by_default(self) -> None:
        self.assertEqual(text_limited(FakeResponse("olá".encode()), 10), "olá")
        with self.assertRaises(HttpBoundaryError):
            text_limited(FakeResponse(b"\xff"), 10)

    def test_error_diagnostic_is_truncated(self) -> None:
        self.assertEqual(error_body_limited(FakeResponse(b"abcdef"), 4), b"abcd")


if __name__ == "__main__":
    unittest.main()
