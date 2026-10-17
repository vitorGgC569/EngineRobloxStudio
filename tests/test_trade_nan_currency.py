"""An offer cannot carry a NaN currency.

validOffer rejects currency only when currency < 0. In Luau, NaN < 0 is
false, so currency 0/0 is accepted and stored.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTradeNanCurrency(unittest.TestCase):
    def test_nan_currency_is_refused(self) -> None:
        out = _run([FORGE / "Social"], """
            local TradeSession = Require("TradeSession")
            local session = TradeSession.new({
                a = "a",
                b = "b",
                cooldownSeconds = 0,
                clock = function() return 0 end,
            })
            local nanOk = session:offer("a", {
                items = { { id = "sword", count = 1 } },
                currency = 0/0,
            })
            assert(nanOk == false, "NaN currency must be refused")
            local ok = session:offer("a", {
                items = { { id = "sword", count = 1 } },
                currency = 5,
            })
            assert(ok == true, "a finite currency must be accepted")
            print('{"trade":true}')
        """)
        assert "trade" in out


if __name__ == "__main__":
    unittest.main()
