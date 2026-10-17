"""AbilitySystem.register must refuse a cooldown that never ends.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge is not a cooldown; 0 still casts.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAbilityInfiniteCooldown(unittest.TestCase):
    def test_infinite_cooldown_is_refused(self) -> None:
        """math.huge is not a cooldown, and 0 still returns the cast guid."""
        out = _run([FORGE / "Combat"], """
            local AbilitySystem = Require("AbilitySystem")
            local system = AbilitySystem.new({
                now = function()
                    return 0
                end,
                guidFactory = function()
                    return "g1"
                end,
            })
            local ok = pcall(function()
                system:register("bolt", { name = "Bolt", cooldown = math.huge })
            end)
            assert(ok == false, "infinite cooldown was accepted")
            system:register("bolt", { name = "Bolt", cooldown = 0 })
            local guid = system:cast("bolt")
            assert(guid == "g1", "cast guid was " .. tostring(guid))
            print('{"cooldown":true}')
        """)
        assert "cooldown" in out


if __name__ == "__main__":
    unittest.main()
