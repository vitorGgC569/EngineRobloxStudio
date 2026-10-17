"""IncomeEngine.tick must not pay negative income.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A step of -5 must pay 0; a step of 0.5 on a base of 10 pays 5.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestIncomeNegativeTick(unittest.TestCase):
    def test_negative_dt_pays_nothing(self) -> None:
        """tick(-5) returns 0, and tick(0.5) returns 5."""
        out = _run([FORGE / "Economy"], """
            local IncomeEngine = Require("IncomeEngine")
            local engine = IncomeEngine.new({ base = 10 })
            local negative = engine:tick(-5)
            assert(negative == 0, "negative tick was " .. tostring(negative))
            local half = engine:tick(0.5)
            assert(half == 5, "half tick was " .. tostring(half))
            print('{"tick":true}')
        """)
        assert "tick" in out


if __name__ == "__main__":
    unittest.main()
