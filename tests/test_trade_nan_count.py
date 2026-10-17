"""An offer cannot carry a NaN stack count.

validOffer rejects a stack only when count <= 0. In Luau, NaN <= 0 is
false, so a count of 0/0 is accepted and stored.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTradeNanCount(unittest.TestCase):
    def test_nan_count_is_refused(self) -> None:
        out = _run([FORGE / "Social"], """
            local TradeSession = Require("TradeSession")
            local session = TradeSession.new({
                a = "a",
                b = "b",
                cooldownSeconds = 0,
                clock = function() return 0 end,
            })
            local nanOk = session:offer("a", {
                items = { { id = "sword", count = 0/0 } },
                currency = 0,
            })
            assert(nanOk == false, "NaN count must be refused")
            local ok = session:offer("a", {
                items = { { id = "sword", count = 1 } },
                currency = 0,
            })
            assert(ok == true, "a count of 1 must be accepted")
            print('{"count":1}')
        """)
        assert "count" in out


if __name__ == "__main__":
    unittest.main()
