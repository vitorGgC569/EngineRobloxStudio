"""AbilitySystem.register must refuse a cast time that never finishes.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge is not a cast time; an omitted time still casts.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAbilityInfiniteCast(unittest.TestCase):
    def test_infinite_cast_time_is_refused(self) -> None:
        """math.huge is not a cast time, and an omitted time still returns the guid."""
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
                system:register("bolt", { name = "Bolt", cooldown = 0, castTime = math.huge })
            end)
            assert(ok == false, "infinite cast time was accepted")
            system:register("bolt", { name = "Bolt", cooldown = 0 })
            local guid = system:cast("bolt")
            assert(guid == "g1", "cast guid was " .. tostring(guid))
            print('{"cast":true}')
        """)
        assert "cast" in out


if __name__ == "__main__":
    unittest.main()
