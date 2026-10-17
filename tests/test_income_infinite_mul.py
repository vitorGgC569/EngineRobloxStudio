"""IncomeEngine.addContributor must refuse an infinite multiplier.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge must fail; a multiplier of 3 still makes the total 30.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestIncomeInfiniteMul(unittest.TestCase):
    def test_infinite_multiplier_is_refused(self) -> None:
        """addContributor rejects math.huge, and a mul of 3 totals 30."""
        out = _run([FORGE / "Economy"], """
            local IncomeEngine = Require("IncomeEngine")
            local engine = IncomeEngine.new({ base = 10 })
            local okHuge = pcall(function()
                engine:addContributor("glitch", { kind = "mul", value = math.huge })
            end)
            assert(okHuge == false, "huge mul was " .. tostring(okHuge))
            engine:addContributor("prestige", { kind = "mul", value = 3 })
            local total = engine:total()
            assert(total == 30, "total was " .. tostring(total))
            print('{"income":true}')
        """)
        assert "income" in out


if __name__ == "__main__":
    unittest.main()
