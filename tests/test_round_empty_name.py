"""RoundMachine.new must refuse a phase with no name.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A missing name must fail; a named phase of 5 seconds is ACTIVE.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRoundEmptyName(unittest.TestCase):
    def test_missing_phase_name_is_refused(self) -> None:
        """new rejects a nameless phase, and ACTIVE still starts."""
        out = _run([FORGE / "Match"], """
            local RoundMachine = Require("RoundMachine")
            local okEmpty = pcall(function()
                RoundMachine.new({
                    phases = { { duration = 5 } },
                })
            end)
            assert(okEmpty == false, "empty name was " .. tostring(okEmpty))
            local machine = RoundMachine.new({
                phases = { { name = "ACTIVE", duration = 5 } },
            })
            local name = machine:current()
            assert(name == "ACTIVE", "current was " .. tostring(name))
            print('{"name":true}')
        """)
        assert "name" in out


if __name__ == "__main__":
    unittest.main()
