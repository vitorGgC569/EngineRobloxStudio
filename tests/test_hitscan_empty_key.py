"""A hitscan shot cannot be recorded under an empty shooter key.

tryFire stores lastFireAt[""]. An empty string is a real table key, so a
nameless shot takes a cooldown slot.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestHitscanEmptyKey(unittest.TestCase):
    def test_empty_shooter_key_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local HitscanValidator = Require("HitscanValidator")
            local gun = HitscanValidator.new({ cooldown = 0, clock = function() return 0 end })
            local emptyOk = pcall(function()
                gun:tryFire("")
            end)
            assert(emptyOk == false, "an empty shooter key must be refused")
            local fired = gun:tryFire("a")
            assert(fired == true, "a named shooter must still fire")
            print('{"shooter":"a"}')
        """)
        assert "shooter" in out


if __name__ == "__main__":
    unittest.main()
