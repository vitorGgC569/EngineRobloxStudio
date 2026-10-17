"""AggroTable.damage must ignore a weight that is not a finite share.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A NaN weight must not store threat; a later weight of 1 still does.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAggroNanWeight(unittest.TestCase):
    def test_nan_weight_does_not_store_threat(self) -> None:
        """0/0 is not a share, and a later weight of 1 still grants 10."""
        out = _run([FORGE / "Combat"], """
            local AggroTable = Require("AggroTable")
            local aggro = AggroTable.new({
                now = function()
                    return 0
                end,
            })
            aggro:damage({ { key = "tank", weight = 0 / 0 } }, 10)
            local rows = aggro:entries()
            assert(#rows == 0, "nan weight stored threat " .. tostring(rows[1] and rows[1].threat))
            aggro:damage({ { key = "tank", weight = 1 } }, 10)
            local threat = aggro:entries()[1].threat
            assert(threat == 10, "threat was " .. tostring(threat))
            print('{"weight":true}')
        """)
        assert "weight" in out


if __name__ == "__main__":
    unittest.main()
