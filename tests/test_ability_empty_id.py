"""AbilitySystem.register must refuse an ability id with no name.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. An empty id is not an ability; "bolt" still casts.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAbilityEmptyId(unittest.TestCase):
    def test_empty_ability_id_is_refused(self) -> None:
        """An empty id is refused, and bolt still returns the cast guid."""
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
                system:register("", { name = "Bolt", cooldown = 0 })
            end)
            assert(ok == false, "empty ability id was accepted")
            system:register("bolt", { name = "Bolt", cooldown = 0 })
            local guid = system:cast("bolt")
            assert(guid == "g1", "cast guid was " .. tostring(guid))
            print('{"ability":true}')
        """)
        assert "ability" in out


if __name__ == "__main__":
    unittest.main()
