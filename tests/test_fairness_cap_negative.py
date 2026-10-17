"""FairnessBudget.new must refuse a negative assist cap.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A cap of -1 must fail; a cap of 1 grants once and then refuses.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestFairnessCapNegative(unittest.TestCase):
    def test_negative_max_assists_is_refused(self) -> None:
        """new rejects -1, and a cap of 1 grants one assist then refuses."""
        out = _run([FORGE / "LiveOps"], """
            local FairnessBudget = Require("FairnessBudget")
            local okNegative = pcall(function()
                FairnessBudget.new({
                    maxAssists = -1,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(okNegative == false, "new(-1) was " .. tostring(okNegative))
            local budget = FairnessBudget.new({
                maxAssists = 1,
                clock = function()
                    return 0
                end,
            })
            local first = budget:requestAssist(false)
            assert(first == true, "first was " .. tostring(first))
            local second = budget:requestAssist(false)
            assert(second == false, "second was " .. tostring(second))
            print('{"cap":true}')
        """)
        assert "cap" in out


if __name__ == "__main__":
    unittest.main()
