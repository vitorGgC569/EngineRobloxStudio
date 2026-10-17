"""FairnessBudget must refuse a window that drops a grant at once."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestFairnessWindowNegative(unittest.TestCase):
    def test_negative_window_is_refused_and_a_positive_window_holds_the_cap(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local FairnessBudget = Require("FairnessBudget")
            local ok = pcall(function()
                FairnessBudget.new({
                    maxAssists = 1,
                    windowSeconds = -10,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(ok == false, "negative window was accepted")
            local budget = FairnessBudget.new({
                maxAssists = 1,
                windowSeconds = 600,
                clock = function()
                    return 0
                end,
            })
            local first = budget:requestAssist(false)
            assert(first == true, "first assist was refused")
            local second = budget:requestAssist(false)
            assert(second == false, "second assist was granted")
            print('{"window":true}')
        """)
        assert "window" in out


if __name__ == "__main__":
    unittest.main()
