"""Reading a NaN user id must not crash the scoreboard.

get indexes stats with the user id. Luau throws "table index is NaN"
when that id is 0/0.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestScoreboardNanGet(unittest.TestCase):
    def test_nan_user_id_reads_as_empty(self) -> None:
        out = _run([FORGE / "Movement"], """
            local Scoreboard = Require("Scoreboard")
            local board = Scoreboard.new()
            local ok, stats = pcall(function()
                return board:get(0/0)
            end)
            assert(ok == true, "a NaN user id must not throw")
            assert(stats.kills == 0, "a missing player must read as zero kills")
            board:recordKill(1, 2, false)
            assert(board:get(1).kills == 1, "killer 1 must still have one kill")
            print('{"read":0}')
        """)
        assert "read" in out


if __name__ == "__main__":
    unittest.main()
