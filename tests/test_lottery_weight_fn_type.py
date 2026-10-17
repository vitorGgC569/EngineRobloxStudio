"""A weight function that does not return a number must not stop the roll.

`math.max` throws when the function returns a string, so the named entry
already in the pool is never reached. A bad result counts as zero.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryWeightFnType(unittest.TestCase):
    def test_a_string_weight_does_not_hide_the_named_entry(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local lottery = Lottery.new()
            lottery:add("bad", {
                weightFn = function()
                    return "x"
                end,
            })
            lottery:add("common", { weight = 1 })
            local rolled = lottery:roll(function()
                return 0
            end, {})
            assert(rolled == "common", "roll must return common, got " .. tostring(rolled))
            print('{"weightfn":true}')
        """)
        assert "weightfn" in out


if __name__ == "__main__":
    unittest.main()
