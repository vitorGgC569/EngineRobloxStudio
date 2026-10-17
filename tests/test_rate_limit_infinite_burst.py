"""RateLimit.new must refuse a burst that never spends down.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge is not a capacity; a burst of 1 still allows one try.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRateLimitInfiniteBurst(unittest.TestCase):
    def test_infinite_burst_is_refused(self) -> None:
        """math.huge is not a burst, and a burst of 1 still holds at one stamp."""
        out = _run([FORGE / "Net"], """
            local RateLimit = Require("RateLimit")
            local ok = pcall(function()
                RateLimit.new({ rate = 1, burst = math.huge })
            end)
            assert(ok == false, "infinite burst was accepted")
            local limit = RateLimit.new({ rate = 1, burst = 1 })
            local first = limit:try("k", 0)
            assert(first == true, "first try was refused")
            local second = limit:try("k", 0)
            assert(second == false, "second try was allowed")
            print('{"burst":true}')
        """)
        assert "burst" in out


if __name__ == "__main__":
    unittest.main()
