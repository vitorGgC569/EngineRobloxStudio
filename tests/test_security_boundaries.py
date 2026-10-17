from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from rqe.hub.auth import BridgeAuthError
from rqe.hub.client import StudioBridge
from rqe.security import (
    SecurityBoundaryError,
    resolve_import_source,
    resolve_inside,
    validate_hub_url,
    validate_filename,
    validate_path_component,
)


class FilesystemBoundaryTests(unittest.TestCase):
    def test_relative_file_resolves_inside_the_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected = root / "src" / "module.lua"
            self.assertEqual(
                resolve_inside(root, "src/module.lua", suffixes=(".lua",)),
                expected,
            )

    def test_parent_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(SecurityBoundaryError):
                resolve_inside(Path(directory), "../outside.lua")

    def test_absolute_paths_are_rejected_for_workspace_operations(self):
        with tempfile.TemporaryDirectory() as directory:
            absolute = Path(directory).resolve() / "module.lua"
            with self.assertRaises(SecurityBoundaryError):
                resolve_inside(directory, absolute)

    def test_external_imports_require_an_operator_allowlist(self):
        with tempfile.TemporaryDirectory() as workspace, tempfile.TemporaryDirectory() as external:
            with mock.patch.dict(os.environ, {"RQE_IMPORT_ROOTS": ""}, clear=False):
                with self.assertRaises(SecurityBoundaryError):
                    resolve_import_source(workspace, external)
            with mock.patch.dict(os.environ, {"RQE_IMPORT_ROOTS": external}, clear=False):
                self.assertEqual(resolve_import_source(workspace, external), Path(external).resolve())

    def test_symlink_components_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real = root / "real"
            real.mkdir()
            link = root / "link"
            try:
                link.symlink_to(real, target_is_directory=True)
            except OSError:
                self.skipTest("this Windows account cannot create symbolic links")
            with self.assertRaises(SecurityBoundaryError):
                resolve_inside(root, "link/module.lua")

    def test_filename_components_cannot_smuggle_a_path(self):
        for value in ("../capture", "folder/file", "folder\\file", ".", "..", "C:drive"):
            with self.subTest(value=value), self.assertRaises(SecurityBoundaryError):
                validate_path_component(value, label="viewpoint")
        self.assertEqual(validate_path_component("boss-arena.v2"), "boss-arena.v2")

    def test_human_readable_filenames_are_portable_leaf_names(self):
        self.assertEqual(validate_filename("Árvore final (2).zip"), "Árvore final (2).zip")
        for value in ("../pack.zip", "folder\\pack.zip", "CON.txt", "bad?.zip", "trailing. "):
            with self.subTest(value=value), self.assertRaises(SecurityBoundaryError):
                validate_filename(value)


class NetworkBoundaryTests(unittest.TestCase):
    def test_loopback_origins_are_allowed_and_normalised(self):
        self.assertEqual(validate_hub_url("http://127.0.0.1:8790/"), "http://127.0.0.1:8790")
        self.assertEqual(validate_hub_url("http://localhost:8790"), "http://localhost:8790")
        self.assertEqual(validate_hub_url("http://[::1]:8790"), "http://[::1]:8790")

    def test_remote_origin_is_rejected_before_a_token_can_be_attached(self):
        with mock.patch.dict(os.environ, {"RQE_TRUSTED_HUB_URLS": ""}, clear=False):
            with self.assertRaises(SecurityBoundaryError):
                validate_hub_url("https://attacker.example:443")
            with self.assertRaises(BridgeAuthError):
                StudioBridge("https://attacker.example", token="x" * 48)

    def test_operator_can_allowlist_an_exact_remote_origin(self):
        with mock.patch.dict(
            os.environ,
            {"RQE_TRUSTED_HUB_URLS": "https://bridge.example:8443"},
            clear=False,
        ):
            self.assertEqual(
                validate_hub_url("https://bridge.example:8443/"),
                "https://bridge.example:8443",
            )
            with self.assertRaises(SecurityBoundaryError):
                validate_hub_url("https://bridge.example:9443")

    def test_origin_cannot_embed_credentials_or_paths(self):
        for url in (
            "http://token@127.0.0.1:8790",
            "http://127.0.0.1:8790/rpc",
            "file:///tmp/hub",
        ):
            with self.subTest(url=url), self.assertRaises(SecurityBoundaryError):
                validate_hub_url(url)


if __name__ == "__main__":
    unittest.main()
