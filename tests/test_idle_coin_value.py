"""IdleGenerator must refuse a coin that would pay out a debit."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestIdleCoinValue(unittest.TestCase):
    def test_negative_coin_is_refused_and_a_positive_coin_pays_out(self) -> None:
        out = _run([FORGE / "Progression"], """
            local IdleGenerator = Require("IdleGenerator")
            local generator = IdleGenerator.new({
                clock = function()
                    return 0
                end,
            })
            local ok = pcall(function()
                generator:addCoin("c", -10)
            end)
            assert(ok == false, "negative addCoin succeeded")
            generator:addCoin("ok", 3)
            local payout = generator:collect("ok")
            assert(payout == 3, "collect paid " .. tostring(payout))
            print('{"coin":true}')
        """)
        assert "coin" in out


if __name__ == "__main__":
    unittest.main()
