from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from rqe.hub.auth import (
    BridgeAuthError,
    derive_installation_id,
    derive_role_token,
    load_bridge_token,
    load_or_create_bridge_token,
    token_fingerprint,
)
from rqe.hub.install import PLUGIN_FILENAME, install_plugin


ROOT = Path(__file__).resolve().parents[1]


class HubAuthenticationTests(unittest.TestCase):
    def test_machine_token_is_created_once_and_never_rotated_by_a_second_installer(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.dict("os.environ", {}, clear=False):
            path = Path(directory) / "bridge-token"
            with patch.dict("os.environ", {"RQE_BRIDGE_TOKEN": ""}):
                first, first_path, created = load_or_create_bridge_token(path)
                second, second_path, created_again = load_or_create_bridge_token(path)
            self.assertTrue(created)
            self.assertFalse(created_again)
            self.assertEqual(first, second)
            self.assertEqual(first_path, second_path)
            self.assertEqual(load_bridge_token(path, allow_environment=False), first)
            self.assertEqual(len(token_fingerprint(first)), 16)

    def test_short_or_control_character_tokens_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bridge-token"
            path.write_text("short\n", encoding="utf-8")
            with self.assertRaises(BridgeAuthError):
                load_bridge_token(path, allow_environment=False)

    @unittest.skipUnless(shutil.which("rojo"), "rojo is required for plugin packaging")
    def test_installed_plugin_and_hub_share_a_secret_that_is_absent_from_receipts(self) -> None:
        token = "installation-token-with-at-least-thirty-two-bytes-123456"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugins = root / "plugins"
            result = install_plugin(ROOT, plugins, bearer_token=token)
            installed = plugins / PLUGIN_FILENAME
            self.assertTrue(installed.is_file())
            installed_source = installed.read_text(encoding="utf-8")
            self.assertIn(derive_role_token(token, "plugin"), installed_source)
            self.assertIn(derive_installation_id(token), installed_source)
            self.assertNotIn(token, installed_source)
            serialized = json.dumps(result, sort_keys=True)
            self.assertNotIn(token, serialized)
            self.assertEqual(result["authentication"]["tokenFingerprint"], token_fingerprint(token))
            self.assertEqual(result["authentication"]["credentialModel"], "derived-capability-v2")
            self.assertEqual(result["authentication"]["installationId"], derive_installation_id(token))
            self.assertFalse(result["authentication"]["secretIncluded"])
            self.assertEqual(
                (ROOT / "apps/studio-plugin/src/Auth.lua").read_text(encoding="utf-8").count(token),
                0,
            )

    def test_role_credentials_are_stable_and_not_interchangeable(self) -> None:
        root = "role-root-token-with-at-least-thirty-two-bytes-123456"
        roles = ("reader", "mutator", "executor", "publisher", "plugin", "admin")
        credentials = {role: derive_role_token(root, role) for role in roles}
        self.assertEqual(credentials["plugin"], derive_role_token(root, "plugin"))
        self.assertEqual(len(set(credentials.values())), len(roles))
        self.assertNotIn(root, set(credentials.values()))
        with self.assertRaises(BridgeAuthError):
            derive_role_token(root, "agent")

    def test_installation_identity_is_stable_but_not_the_root_secret(self) -> None:
        root = "installation-root-token-with-at-least-thirty-two-bytes-123456"
        identity = derive_installation_id(root)
        self.assertEqual(identity, derive_installation_id(root))
        self.assertTrue(identity.startswith("inst-"))
        self.assertNotIn(root, identity)


if __name__ == "__main__":
    unittest.main()
