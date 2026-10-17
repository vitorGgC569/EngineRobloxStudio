"""Balance.credit must ignore an infinite gain.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge must leave the starting gold in place; a later 1
still credits.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestBalanceInfinite(unittest.TestCase):
    def test_infinite_gain_does_not_change_the_balance(self) -> None:
        """credit of math.huge leaves 10, and a later 1 makes 11."""
        out = _run([FORGE / "Economy"], """
            local Balance = Require("Balance")
            local wallet = Balance.new({
                currencies = { gold = { start = 10 } },
            })
            wallet:credit({ gold = math.huge })
            local afterHuge = wallet:get("gold")
            assert(afterHuge == 10, "gold after huge was " .. tostring(afterHuge))
            wallet:credit({ gold = 1 })
            local afterOne = wallet:get("gold")
            assert(afterOne == 11, "gold after one was " .. tostring(afterOne))
            print('{"finite":true}')
        """)
        assert "finite" in out


if __name__ == "__main__":
    unittest.main()
