"""A hitscan cooldown cannot be negative.

new stores cooldown or 0.1. In Luau, -1 is truthy, so it is kept. After
the first shot, now - last is 0, and 0 < -1 is false, so the second shot
is never blocked.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestHitscanNegativeCooldown(unittest.TestCase):
    def test_negative_cooldown_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local HitscanValidator = Require("HitscanValidator")
            local negativeOk = pcall(function()
                HitscanValidator.new({ cooldown = -1, clock = function() return 0 end })
            end)
            assert(negativeOk == false, "a negative cooldown must be refused")
            local gun = HitscanValidator.new({ cooldown = 0.1, clock = function() return 0 end })
            local first = gun:tryFire("a")
            assert(first == true, "the first shot must fire")
            local second = gun:tryFire("a")
            assert(second == false, "the second shot must be blocked")
            print('{"shot":false}')
        """)
        assert "shot" in out


if __name__ == "__main__":
    unittest.main()
