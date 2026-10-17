"""Negative amounts must not spend or mint through the wrong door.

Executed as real Luau through the pinned runtime. credit adds a negative
gain, which spends gold without the debit check. debit subtracts a
negative cost, which mints gold because the leftover looks larger.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestBalanceNegative(unittest.TestCase):
    def test_a_negative_credit_does_not_spend_and_a_negative_debit_does_not_mint(self) -> None:
        out = _run([FORGE / "Economy"], """
            local Balance = Require("Balance")
            local wallet = Balance.new({ currencies = { gold = { start = 10 } } })
            wallet:credit({ gold = -50 })
            local afterCredit = wallet:get("gold")
            assert(afterCredit == 10, "a negative credit spent gold, got " .. tostring(afterCredit))

            local ok = wallet:debit({ gold = -10 })
            local afterDebit = wallet:get("gold")
            assert(ok == false, "a negative debit was accepted")
            assert(afterDebit == 10, "a negative debit changed gold, got " .. tostring(afterDebit))
            print('{"wallet":true}')
        """)
        self.assertIn("wallet", out)


if __name__ == "__main__":
    unittest.main()
