"""Registered class definitions must stay sealed.

Executed as real Luau through the pinned runtime. register and get hand
back the stored definition, so setting health or a move cooldown on the
returned table rewrites the registry.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestClassRegistryIsolation(unittest.TestCase):
    def test_editing_a_returned_definition_does_not_rewrite_the_registry(self) -> None:
        out = _run([FORGE / "Combat"], """
            local ClassRegistry = Require("ClassRegistry")
            local registry = ClassRegistry.new()
            local registered = registry:register("knight", {
                walkSpeed = 16,
                health = 100,
                stamina = 50,
                moves = { slash = { cooldown = 2, stacks = 1 } },
            })
            registered.health = 1
            assert(registry:get("knight").health == 100, "editing the registered health rewrote the registry, got " .. tostring(registry:get("knight").health))

            registry:get("knight").moves.slash.cooldown = 0
            local cooldown = registry:cooldownOf("knight", "slash")
            assert(cooldown == 2, "editing the returned cooldown rewrote the registry, got " .. tostring(cooldown))
            print('{"class":true}')
        """)
        self.assertIn("class", out)


if __name__ == "__main__":
    unittest.main()
