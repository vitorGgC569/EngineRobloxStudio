"""A wallet must keep its own copy of each currency definition.

Balance.new stored the caller's currency table. Setting gold.big after new
made the next credit use BigNumber math on a plain number balance.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestBalanceIsolation(unittest.TestCase):
    def test_later_big_flag_does_not_change_credit(self) -> None:
        out = _run([FORGE / "Economy"], """
            local Balance = Require("Balance")
            local gold = { start = 10 }
            local wallet = Balance.new({ currencies = { gold = gold } })
            gold.big = true
            wallet:credit({ gold = 1 })
            local amount = wallet:get("gold")
            assert(amount == 11, "a wallet that started at 10 and is credited 1 must stay a plain 11")
            print('{"wallet":11}')
        """)
        assert "wallet" in out


if __name__ == "__main__":
    unittest.main()
