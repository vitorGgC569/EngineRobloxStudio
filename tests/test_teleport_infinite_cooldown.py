"""A teleport pad cannot be defined with an infinite cooldown.

define asserts cooldown >= 0. math.huge passes. After the first jump,
now - lastUsedAt < math.huge stays true for every finite clock, so the
pad never opens again.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTeleportInfiniteCooldown(unittest.TestCase):
    def test_infinite_cooldown_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local TeleportPads = Require("TeleportPads")
            local pads = TeleportPads.new(function() return 0 end)
            local infiniteOk = pcall(function()
                pads:define("a", "b", math.huge)
            end)
            assert(infiniteOk == false, "an infinite cooldown must be refused")
            pads:define("a", "b", 2)
            pads:define("b", "a", 2)
            local dest = pads:use("a")
            assert(dest == "b", "a finite cooldown must still jump")
            print('{"cooldown":2}')
        """)
        assert "cooldown" in out


if __name__ == "__main__":
    unittest.main()
