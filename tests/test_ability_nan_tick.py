"""AbilitySystem.tick must ignore a clock that is not a time.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A NaN clock must not finish the cast; a later clock of 5 still does.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAbilityNanTick(unittest.TestCase):
    def test_nan_clock_does_not_finish_the_cast(self) -> None:
        """A NaN tick returns nil, and a later clock of 5 returns the guid."""
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
            system:register("bolt", { name = "Bolt", cooldown = 0, castTime = 5 })
            local guid = system:cast("bolt")
            assert(guid == "g1", "cast guid was " .. tostring(guid))
            clock = 0 / 0
            local early = system:tick()
            assert(early == nil, "nan tick returned " .. tostring(early))
            clock = 5
            local finished = system:tick()
            assert(finished == "g1", "finished guid was " .. tostring(finished))
            print('{"tick":true}')
        """)
        assert "tick" in out


if __name__ == "__main__":
    unittest.main()
