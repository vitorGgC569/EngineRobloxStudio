"""Assistance without evidence must not be granted.

`requestAssist(nil)` is not proof that no legal move existed. Only an
explicit false is that evidence; anything else must refuse the grant.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestFairnessBudgetEvidence(unittest.TestCase):
    def test_nil_does_not_grant_and_false_still_does(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local FairnessBudget = Require("FairnessBudget")
            local budget = FairnessBudget.new({
                clock = function()
                    return 0
                end,
            })
            local missing = budget:requestAssist(nil)
            assert(missing == false, "nil must not grant, got " .. tostring(missing))
            local stuck = budget:requestAssist(false)
            assert(stuck == true, "false must still grant, got " .. tostring(stuck))
            print('{"fair":true}')
        """)
        assert "fair" in out


if __name__ == "__main__":
    unittest.main()
