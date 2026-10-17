"""Caller tables passed to Permissions.new must not stay live.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A manager allowed to build has to stay allowed after the caller
rewrites the tables it handed to new.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPermissionsIsolation(unittest.TestCase):
    def test_caller_mutations_do_not_change_check(self) -> None:
        """actions.build and levels.Manager are the caller's tables until cloned."""
        out = _run([FORGE / "Social"], """
            local Permissions = Require("Permissions")
            local actions = { build = 2 }
            local levels = { Owner = 3, Manager = 2, Trusted = 1 }
            local acl = Permissions.new({ actions = actions, levels = levels })
            actions.build = 99
            levels.Manager = 0
            local state = { lists = { Manager = { 7 } } }
            local ok, reason = acl:check(state, 7, "build")
            assert(ok == true, "manager build was refused: " .. tostring(reason))
            print('{"permissions":true}')
        """)
        assert "permissions" in out

    def test_default_and_banned_are_rejected_as_level_names(self) -> None:
        """The reserved-name loop bound the boolean, so Default was stored."""
        out = _run([FORGE / "Social"], """
            local Permissions = Require("Permissions")
            local acceptedDefault = pcall(function()
                Permissions.new({ levels = { Owner = 3, Manager = 2, Trusted = 1, Default = 4 } })
            end)
            assert(acceptedDefault == false, "Default was accepted as a level")
            local acceptedBanned = pcall(function()
                Permissions.new({ levels = { Owner = 3, Manager = 2, Trusted = 1, Banned = -1 } })
            end)
            assert(acceptedBanned == false, "Banned was accepted as a level")
            print('{"reserved":true}')
        """)
        assert "reserved" in out


if __name__ == "__main__":
    unittest.main()
