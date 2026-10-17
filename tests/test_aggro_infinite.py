"""AggroTable.damage must ignore a threat that is not a finite amount.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge must not store a row; a later threat of 10 still does.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAggroInfinite(unittest.TestCase):
    def test_infinite_threat_does_not_store_a_row(self) -> None:
        """math.huge leaves no row, and a later 10 is stored as 10."""
        out = _run([FORGE / "Combat"], """
            local AggroTable = Require("AggroTable")
            local aggro = AggroTable.new({
                now = function()
                    return 0
                end,
            })
            aggro:damage({ { key = "tank", weight = 1 } }, math.huge)
            local rows = aggro:entries()
            assert(#rows == 0, "huge damage stored threat " .. tostring(rows[1] and rows[1].threat))
            aggro:damage({ { key = "tank", weight = 1 } }, 10)
            local threat = aggro:entries()[1].threat
            assert(threat == 10, "threat was " .. tostring(threat))
            print('{"threat":true}')
        """)
        assert "threat" in out


if __name__ == "__main__":
    unittest.main()
