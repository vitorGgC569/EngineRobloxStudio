from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from rqe.assets import local_credentials


class LocalCredentialBoundaryTests(unittest.TestCase):
    def test_documentation_key_is_never_an_authority_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            key = root / "docs" / "goal" / "key.txt"
            key.parent.mkdir(parents=True)
            key.write_text("not-authority", encoding="utf-8")
            with patch.dict("os.environ", {"LOCALAPPDATA": str(Path(directory) / "local")}, clear=True):
                result = local_credentials.describe(root=root)
            self.assertFalse(result["found"])
            self.assertNotIn("docs", " ".join(result["searched"]))

    def test_canonical_secret_file_loads_only_into_the_canonical_variable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            key = root / local_credentials.RELATIVE_KEY_PATH
            key.parent.mkdir(parents=True)
            key.write_text("canonical-secret", encoding="utf-8")
            environment = {"LOCALAPPDATA": str(Path(directory) / "local")}
            with patch.dict("os.environ", environment, clear=True):
                self.assertTrue(local_credentials.load(root=root))
                self.assertEqual(os.environ[local_credentials.ENV_VAR], "canonical-secret")
                self.assertNotIn("RQE_ROBLOX_OPEN_CLOUD_API_KEY", os.environ)

    def test_arbitrary_credential_paths_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            outside = Path(directory) / "outside.key"
            outside.write_text("secret", encoding="utf-8")
            with patch.dict("os.environ", {"LOCALAPPDATA": str(Path(directory) / "local")}, clear=True):
                with self.assertRaises(ValueError):
                    local_credentials.describe(outside, root=root)

    def test_legacy_environment_name_is_migrated_in_process(self) -> None:
        with patch.dict("os.environ", {
            "RQE_ROBLOX_OPEN_CLOUD_API_KEY": "legacy-secret",
            "LOCALAPPDATA": "C:/not-used",
        }, clear=True):
            self.assertTrue(local_credentials.load())
            self.assertEqual(os.environ["ROBLOX_OPEN_CLOUD_KEY"], "legacy-secret")


if __name__ == "__main__":
    unittest.main()
