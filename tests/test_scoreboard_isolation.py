"""Tables returned by Scoreboard must not stay live.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. Editing a snapshot matchup, or the kills on a get() result,
must not rewrite the ledger.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestScoreboardIsolation(unittest.TestCase):
    def test_snapshot_and_get_do_not_rewrite_the_ledger(self) -> None:
        """A kill of 1 stays 1 after the caller edits the tables it was handed."""
        out = _run([FORGE / "Movement"], """
            local Scoreboard = Require("Scoreboard")
            local board = Scoreboard.new()
            board:recordKill(1, 2, false)
            local shot = board:snapshot()
            shot[1].matchups[2] = 9
            local again = board:snapshot()
            assert(again[1].matchups[2] == 1, "matchup was rewritten to " .. tostring(again[1].matchups[2]))
            local view = board:get(1)
            view.kills = 0
            local reread = board:get(1)
            assert(reread.kills == 1, "kills were rewritten to " .. tostring(reread.kills))
            print('{"score":true}')
        """)
        assert "score" in out


if __name__ == "__main__":
    unittest.main()
