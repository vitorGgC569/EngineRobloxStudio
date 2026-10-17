"""A negative decay step must not add threat.

`value - decayPerSecond * dt` with a negative dt raises the table. Decay
only fades threat, so a backward step has to leave the entry where it was.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAggroDecayNegative(unittest.TestCase):
    def test_negative_dt_does_not_raise_threat(self) -> None:
        out = _run([FORGE / "Combat"], """
            local AggroTable = Require("AggroTable")
            local table_ = AggroTable.new({
                decayPerSecond = 2,
                now = function()
                    return 0
                end,
            })
            table_:add("tank", 10)
            table_:decay(-5)
            local entries = table_:entries()
            assert(entries[1].threat == 10, "threat must stay 10, got " .. tostring(entries[1] and entries[1].threat))
            print('{"threat":true}')
        """)
        assert "threat" in out


if __name__ == "__main__":
    unittest.main()
