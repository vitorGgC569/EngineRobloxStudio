"""AggroTable.add must ignore NaN.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A NaN amount must not leave a row; a later number still stores.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAggroNan(unittest.TestCase):
    def test_nan_amount_does_not_store_a_row(self) -> None:
        """add of NaN leaves no row, and a later 10 is stored as 10."""
        out = _run([FORGE / "Combat"], """
            local AggroTable = Require("AggroTable")
            local aggro = AggroTable.new({
                now = function()
                    return 0
                end,
            })
            aggro:add("tank", 0 / 0)
            local rows = aggro:entries()
            assert(#rows == 0, "rows after nan was " .. tostring(#rows))
            aggro:add("tank", 10)
            local threat = aggro:entries()[1].threat
            assert(threat == 10, "threat was " .. tostring(threat))
            print('{"threat":true}')
        """)
        assert "threat" in out


if __name__ == "__main__":
    unittest.main()
