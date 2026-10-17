"""A teleport pad cannot be defined with a negative cooldown.

define stores cooldownSeconds or 2. In Luau, -1 is truthy, so it is kept.
After the first jump, now - lastUsedAt is 0, and 0 < -1 is false, so the
pad never cools down.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTeleportNegativeCooldown(unittest.TestCase):
    def test_negative_cooldown_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local TeleportPads = Require("TeleportPads")
            local pads = TeleportPads.new(function() return 0 end)
            local negativeOk = pcall(function()
                pads:define("a", "b", -1)
            end)
            assert(negativeOk == false, "a negative cooldown must be refused")
            pads:define("a", "b", 2)
            pads:define("b", "a", 2)
            local first = pads:use("a")
            assert(first == "b", "the first use must arrive at b")
            local second, reason = pads:use("a")
            assert(second == nil and reason == "pad_cooldown", "the pad must still be cooling down")
            print('{"pad":"cooldown"}')
        """)
        assert "pad" in out


if __name__ == "__main__":
    unittest.main()
