from __future__ import annotations

import hashlib
import io
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

from rqe.assets.itch import _validate_download_url, fetch_upload


class FakeResponse(io.BytesIO):
    def __init__(self, payload: bytes, content_length: int | None = None) -> None:
        super().__init__(payload)
        self.headers = {}
        if content_length is not None:
            self.headers["Content-Length"] = str(content_length)


def redirect_to(url: str) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        "https://itch.io/api/1/key/upload/1/download",
        302,
        "Found",
        {"Location": url},
        io.BytesIO(),
    )


class ItchDownloadSafetyTests(unittest.TestCase):
    def test_redirect_must_be_public_credential_free_https(self) -> None:
        self.assertEqual(
            _validate_download_url("https://cdn.example.test/file.zip?signature=x"),
            "https://cdn.example.test/file.zip?signature=x",
        )
        for value in (
            "http://cdn.example.test/file.zip",
            "https://token@cdn.example.test/file.zip",
            "https://127.0.0.1/file.zip",
            "https://10.0.0.1/file.zip",
            "https://cdn.example.test:8443/file.zip",
        ):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                _validate_download_url(value)

    def test_download_is_verified_then_atomically_installed(self) -> None:
        payload = b"verified archive"
        expected_md5 = hashlib.md5(payload).hexdigest()
        opener = Mock()
        opener.open.side_effect = redirect_to("https://cdn.example.test/file.zip")
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "pack.zip"
            destination.write_bytes(b"old")
            with patch("rqe.assets.itch.urllib.request.build_opener", return_value=opener), patch(
                "rqe.assets.itch.urllib.request.urlopen",
                return_value=FakeResponse(payload, len(payload)),
            ):
                written = fetch_upload(
                    1,
                    destination,
                    "secret",
                    expected_size=len(payload),
                    expected_md5=expected_md5,
                )
            self.assertEqual(written, len(payload))
            self.assertEqual(destination.read_bytes(), payload)
            self.assertEqual(list(destination.parent.glob("*.part")), [])

    def test_failed_stream_preserves_existing_destination_and_removes_partial(self) -> None:
        opener = Mock()
        opener.open.side_effect = redirect_to("https://cdn.example.test/file.zip")
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "pack.zip"
            destination.write_bytes(b"old")
            with patch("rqe.assets.itch.urllib.request.build_opener", return_value=opener), patch(
                "rqe.assets.itch.urllib.request.urlopen",
                return_value=FakeResponse(b"four"),
            ):
                with self.assertRaises(RuntimeError):
                    fetch_upload(1, destination, "secret", expected_size=3)
            self.assertEqual(destination.read_bytes(), b"old")
            self.assertEqual(list(destination.parent.glob("*.part")), [])


if __name__ == "__main__":
    unittest.main()
