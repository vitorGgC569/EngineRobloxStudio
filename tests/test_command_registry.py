from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from rqe.hub.commands import (
    CommandRegistry,
    CommandRegistryError,
    CommandValidationError,
    DISPATCHER_RELATIVE_PATH,
    dispatcher_methods,
    load_default_registry,
    repository_root,
)


class CommandRegistryTests(unittest.TestCase):
    def test_every_live_dispatcher_command_has_a_versioned_contract(self) -> None:
        registry = load_default_registry()
        live = dispatcher_methods(repository_root() / DISPATCHER_RELATIVE_PATH)
        self.assertEqual(set(registry.methods()), live)
        self.assertGreaterEqual(len(registry), 45)
        self.assertEqual(registry.schema_version, 1)
        for method in registry.methods():
            spec = registry.require(method)
            self.assertGreaterEqual(spec.method_version, 1, method)
            self.assertTrue(spec.contexts, method)
            self.assertIn(spec.selector["session"], {"optional", "required"}, method)
            self.assertIsInstance(spec.params_schema, dict, method)
            self.assertIsInstance(spec.result_schema, dict, method)

    def test_a_dispatcher_command_missing_from_the_manifest_fails_inventory(self) -> None:
        original = load_default_registry()
        payload = json.loads(json.dumps(original.manifest))
        payload["commands"].pop("world.summary")
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "commands.json"
            manifest.write_text(json.dumps(payload), encoding="utf-8")
            registry = CommandRegistry.from_file(manifest)
            with self.assertRaises(CommandRegistryError) as caught:
                registry.assert_dispatcher_inventory(repository_root() / DISPATCHER_RELATIVE_PATH)
        self.assertIn("world.summary", str(caught.exception))

    def test_params_are_rejected_before_they_reach_studio(self) -> None:
        registry = load_default_registry()
        with self.assertRaises(CommandValidationError):
            registry.require("world.raycast").validate_params({"origin": [0, 1, 2]})
        with self.assertRaises(CommandValidationError):
            registry.require("camera.set").validate_params({"position": [0, True, 2]})
        with self.assertRaises(CommandValidationError):
            registry.require("world.path").validate_params({"fromPath": "game.Workspace.Spawn"})
        with self.assertRaises(CommandValidationError):
            registry.require("actor.navigate_to").validate_params({"timeout": 30})
        registry.require("world.raycast").validate_params({
            "origin": [0, 1, 2],
            "direction": [0, -10, 0],
        })
        registry.require("world.path").validate_params({
            "fromPath": "game.Workspace.Spawn",
            "toPath": "game.Workspace.Store",
        })

    def test_results_are_validated_and_known_engine_limit_is_declared(self) -> None:
        registry = load_default_registry()
        with self.assertRaises(CommandValidationError):
            registry.require("world.summary").validate_result("not an object")
        self.assertEqual(registry.require("client.gui_click").availability, "unsupported")


if __name__ == "__main__":
    unittest.main()
