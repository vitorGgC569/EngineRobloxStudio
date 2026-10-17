"""An infinite collection bonus must not become infinite luck.

`math.huge` is truthy, so `maxBonus or 1` keeps it and a full collection
returns infinity. A missing or non-finite bonus is 1, and an explicit
bonus of 1 still returns 2 when the collection is complete.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLuckInfiniteCompletion(unittest.TestCase):
    def test_huge_bonus_is_capped_and_an_explicit_one_still_completes(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Luck = Require("Luck")
            local huge = Luck.fromCompletion(1, 1, math.huge)
            assert(huge == 2, "huge bonus must return 2, got " .. tostring(huge))
            local full = Luck.fromCompletion(1, 1, 1)
            assert(full == 2, "bonus 1 must return 2, got " .. tostring(full))
            local empty = Luck.fromCompletion(0, 1, 1)
            assert(empty == 1, "empty collection must return 1, got " .. tostring(empty))
            print('{"completion":true}')
        """)
        assert "completion" in out


if __name__ == "__main__":
    unittest.main()
