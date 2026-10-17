"""Caller playlist entries passed to Director.new must not stay live.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. Renaming a map after new, or renaming the table next returns,
must not change the stored playlist.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestDirectorIsolation(unittest.TestCase):
    def test_caller_and_returned_entries_do_not_rename_the_stored_map(self) -> None:
        """The stored docks entry stays docks after either table is renamed."""
        out = _run([FORGE / "Match"], """
            local Director = Require("Director")
            local entry = { id = "docks", mode = "hunt" }
            local director = Director.new({ entry })
            entry.id = "void"
            local voted = director:vote("a", "docks")
            assert(voted == true, "vote missed docks after the caller renamed it")
            local chosen = director:next()
            assert(chosen.id == "docks", "next id was " .. tostring(chosen.id))
            chosen.id = "void"
            local again = director:next()
            assert(again.id == "docks", "stored map was renamed to " .. tostring(again.id))
            print('{"director":true}')
        """)
        assert "director" in out


if __name__ == "__main__":
    unittest.main()
