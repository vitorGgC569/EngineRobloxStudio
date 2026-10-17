"""AbilitySystem.cast must refuse a clock that is not a time.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A NaN clock must not start a cast; a later clock of 0 still does.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAbilityNanCast(unittest.TestCase):
    def test_nan_clock_does_not_cast(self) -> None:
        """A NaN clock returns nil, and a later clock of 0 casts with 5 seconds left."""
        out = _run([FORGE / "Combat"], """
            local AbilitySystem = Require("AbilitySystem")
            local clock = 0 / 0
            local system = AbilitySystem.new({
                now = function()
                    return clock
                end,
                guidFactory = function()
                    return "g1"
                end,
            })
            system:register("bolt", { name = "Bolt", cooldown = 5 })
            local refused = system:cast("bolt")
            assert(refused == nil, "nan cast returned " .. tostring(refused))
            clock = 0
            local guid = system:cast("bolt")
            assert(guid == "g1", "cast guid was " .. tostring(guid))
            local left = system:remainingCooldown("bolt")
            assert(left == 5, "remaining was " .. tostring(left))
            print('{"cast":true}')
        """)
        assert "cast" in out


if __name__ == "__main__":
    unittest.main()
