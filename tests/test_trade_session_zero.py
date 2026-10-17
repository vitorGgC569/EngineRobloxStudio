"""A trade cooldown of 0 means the next offer is immediate.

TradeSession.new used `cooldownSeconds or 3`. Zero is falsy in that
expression, so an explicit 0 waited the default three seconds and the
second offer from the same side came back offer_cooldown.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTradeSessionZero(unittest.TestCase):
    def test_zero_cooldown_allows_a_second_offer_at_the_same_clock(self) -> None:
        out = _run([FORGE / "Social"], """
            local TradeSession = Require("TradeSession")
            local session = TradeSession.new({
                a = "a",
                b = "b",
                cooldownSeconds = 0,
                clock = function() return 0 end,
            })
            local firstOk, firstReason = session:offer("a", {
                items = { { id = "sword", count = 1 } },
                currency = 0,
            })
            assert(firstOk == true, firstReason or "first offer failed")
            local secondOk, secondReason = session:offer("a", {
                items = { { id = "gem", count = 1 } },
                currency = 0,
            })
            assert(secondOk == true, secondReason or "second offer failed")
            assert(secondReason ~= "offer_cooldown", "a cooldown of 0 must not wait")
            print('{"cooldown":0}')
        """)
        assert "cooldown" in out


if __name__ == "__main__":
    unittest.main()
