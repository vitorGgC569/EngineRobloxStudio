"""RateLimit.try must ignore a timestamp that is not finite.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A NaN stamp must not stick, so a later stamp can refill.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRateLimitNan(unittest.TestCase):
    def test_nan_timestamp_does_not_stick(self) -> None:
        """A NaN stamp is refused, and a later stamp of 5 is allowed."""
        out = _run([FORGE / "Net"], """
            local RateLimit = Require("RateLimit")
            local limit = RateLimit.new({
                rate = 1,
                burst = 1,
                now = function()
                    return 0
                end,
            })
            local first = limit:try("k", 0)
            assert(first == true, "first try was refused")
            local poisoned = limit:try("k", 0 / 0)
            assert(poisoned == false, "nan try was allowed")
            local later = limit:try("k", 5)
            assert(later == true, "third try was refused")
            print('{"rate":true}')
        """)
        assert "rate" in out


if __name__ == "__main__":
    unittest.main()
