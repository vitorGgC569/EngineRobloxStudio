from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from rqe.safe_io import SafeIoError, atomic_write_text, read_bytes_limited, read_text_limited


class SafeIoTests(unittest.TestCase):
    def test_bounded_reads_refuse_declared_content_over_the_limit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "large.bin"
            path.write_bytes(b"12345")
            with self.assertRaises(SafeIoError):
                read_bytes_limited(path, 4, label="fixture")

    def test_bounded_text_requires_valid_utf8(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_bytes(b"\xff")
            with self.assertRaises(SafeIoError):
                read_text_limited(path, 10, label="fixture")

    def test_atomic_write_is_idempotent_but_will_not_replace_different_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            self.assertEqual(atomic_write_text(path, "one\n"), "created")
            self.assertEqual(atomic_write_text(path, "one\n"), "unchanged")
            with self.assertRaises(SafeIoError):
                atomic_write_text(path, "two\n")
            self.assertEqual(path.read_text(encoding="utf-8"), "one\n")

    def test_logically_identical_windows_newlines_are_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            path.write_bytes(b"one\r\ntwo\r\n")
            self.assertEqual(atomic_write_text(path, "one\ntwo\n"), "unchanged")


if __name__ == "__main__":
    unittest.main()
