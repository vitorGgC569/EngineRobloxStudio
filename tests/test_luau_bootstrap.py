from __future__ import annotations

import hashlib
import io
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from rqe import luau_check


class FakeResponse(io.BytesIO):
    def __init__(self, payload: bytes) -> None:
        super().__init__(payload)
        self.headers = {"Content-Length": str(len(payload))}


def toolchain_archive(*, duplicate: bool = False) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("bin/luau-compile.exe", b"compiler")
        archive.writestr("bin/luau-analyze.exe", b"analyzer")
        if duplicate:
            archive.writestr("other/luau-compile.exe", b"second")
    return output.getvalue()


class LuauBootstrapTests(unittest.TestCase):
    @staticmethod
    def release_for(payload: bytes) -> dict[str, dict[str, dict[str, object]]]:
        return {
            "test": {
                "windows": {
                    "size": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            }
        }

    def test_verified_archive_installs_only_the_required_tools(self) -> None:
        payload = toolchain_archive()
        with tempfile.TemporaryDirectory() as directory, patch.object(
            luau_check.platform,
            "system",
            return_value="Windows",
        ), patch.object(
            luau_check,
            "LUAU_RELEASES",
            self.release_for(payload),
        ), patch.object(
            luau_check.urllib.request,
            "urlopen",
            return_value=FakeResponse(payload),
        ):
            compiler = luau_check.bootstrap(Path(directory), version="test")
            self.assertEqual(compiler.read_bytes(), b"compiler")
            self.assertEqual(luau_check.analyzer_path(Path(directory)).read_bytes(), b"analyzer")

    def test_hash_mismatch_preserves_an_existing_compiler(self) -> None:
        payload = toolchain_archive()
        releases = self.release_for(payload)
        releases["test"]["windows"]["sha256"] = "0" * 64
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = luau_check.compiler_path(root)
            compiler.parent.mkdir(parents=True)
            compiler.write_bytes(b"existing")
            with patch.object(luau_check.platform, "system", return_value="Windows"), patch.object(
                luau_check,
                "LUAU_RELEASES",
                releases,
            ), patch.object(
                luau_check.urllib.request,
                "urlopen",
                return_value=FakeResponse(payload),
            ):
                with self.assertRaises(luau_check.ToolchainUnavailable):
                    luau_check.bootstrap(root, version="test")
            self.assertEqual(compiler.read_bytes(), b"existing")

    def test_duplicate_tool_names_are_rejected(self) -> None:
        payload = toolchain_archive(duplicate=True)
        with tempfile.TemporaryDirectory() as directory, patch.object(
            luau_check.platform,
            "system",
            return_value="Windows",
        ), patch.object(
            luau_check,
            "LUAU_RELEASES",
            self.release_for(payload),
        ), patch.object(
            luau_check.urllib.request,
            "urlopen",
            return_value=FakeResponse(payload),
        ):
            with self.assertRaises(luau_check.ToolchainUnavailable):
                luau_check.bootstrap(Path(directory), version="test")


if __name__ == "__main__":
    unittest.main()
