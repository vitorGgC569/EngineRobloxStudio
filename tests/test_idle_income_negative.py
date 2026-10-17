"""IdleGenerator must not take coins away on a rewind."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestIdleIncomeNegative(unittest.TestCase):
    def test_negative_dt_earns_nothing(self) -> None:
        out = _run([FORGE / "Progression"], """
            local IdleGenerator = Require("IdleGenerator")
            local generator = IdleGenerator.new({
                passivePerSecond = 2,
                clock = function()
                    return 0
                end,
            })
            local earned = generator:passiveIncome(-5)
            assert(earned == 0, "negative dt took coins, earned " .. tostring(earned))
            print('{"idle":true}')
        """)
        assert "idle" in out


if __name__ == "__main__":
    unittest.main()
