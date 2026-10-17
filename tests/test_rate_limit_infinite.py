"""RateLimit.new must refuse a rate that refills on any positive elapsed.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge is not a rate; a rate of 1 still allows one try.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRateLimitInfinite(unittest.TestCase):
    def test_infinite_rate_is_refused(self) -> None:
        """math.huge is not a rate, and a rate of 1 still holds at one stamp."""
        out = _run([FORGE / "Net"], """
            local RateLimit = Require("RateLimit")
            local ok = pcall(function()
                RateLimit.new({ rate = math.huge, burst = 1 })
            end)
            assert(ok == false, "infinite rate was accepted")
            local limit = RateLimit.new({ rate = 1, burst = 1 })
            local first = limit:try("k", 0)
            assert(first == true, "first try was refused")
            local second = limit:try("k", 0)
            assert(second == false, "second try was allowed")
            print('{"refill":true}')
        """)
        assert "refill" in out


if __name__ == "__main__":
    unittest.main()
