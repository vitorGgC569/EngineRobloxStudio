"""A NaN player id must not crash a kill record.

recordKill uses the killer id as a table key. Luau throws "table index is
NaN" when that id is 0/0, so the call crashes instead of leaving the
board unchanged.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestScoreboardNanId(unittest.TestCase):
    def test_nan_killer_id_leaves_the_board_unchanged(self) -> None:
        out = _run([FORGE / "Movement"], """
            local Scoreboard = Require("Scoreboard")
            local board = Scoreboard.new()
            local ok = pcall(function()
                board:recordKill(0/0, 2, false)
            end)
            assert(ok == true, "a NaN killer id must not throw")
            assert(board:get(2).deaths == 0, "the board must stay unchanged")
            board:recordKill(1, 2, false)
            assert(board:get(1).kills == 1, "killer 1 must have one kill")
            assert(board:get(2).deaths == 1, "victim 2 must have one death")
            print('{"kill":1}')
        """)
        assert "kill" in out


if __name__ == "__main__":
    unittest.main()
