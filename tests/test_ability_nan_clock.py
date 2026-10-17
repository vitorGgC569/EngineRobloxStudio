"""AbilitySystem.remainingCooldown must ignore a clock that is not a time.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A NaN clock must report the stored cooldown; a later real clock
still reports zero.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAbilityNanClock(unittest.TestCase):
    def test_nan_clock_reports_the_stored_cooldown(self) -> None:
        """A NaN clock reports 5, and a later clock of 10 reports 0."""
        out = _run([FORGE / "Combat"], """
            local AbilitySystem = Require("AbilitySystem")
            local clock = 0
            local system = AbilitySystem.new({
                now = function()
                    return clock
                end,
                guidFactory = function()
                    return "g1"
                end,
            })
            system:register("bolt", { name = "Bolt", cooldown = 5 })
            local guid = system:cast("bolt")
            assert(guid == "g1", "cast guid was " .. tostring(guid))
            clock = 0 / 0
            local during = system:remainingCooldown("bolt")
            assert(during == 5, "nan clock remaining was " .. tostring(during))
            clock = 10
            local later = system:remainingCooldown("bolt")
            assert(later == 0, "later remaining was " .. tostring(later))
            print('{"clock":true}')
        """)
        assert "clock" in out


if __name__ == "__main__":
    unittest.main()
