"""RoundMachine.new must refuse an infinite phase duration.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge must fail; a duration of 5 still starts in ACTIVE.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRoundInfiniteDuration(unittest.TestCase):
    def test_infinite_duration_is_refused(self) -> None:
        """new rejects math.huge, and a duration of 5 is ACTIVE."""
        out = _run([FORGE / "Match"], """
            local RoundMachine = Require("RoundMachine")
            local okHuge = pcall(function()
                RoundMachine.new({
                    phases = { { name = "ACTIVE", duration = math.huge } },
                })
            end)
            assert(okHuge == false, "huge duration was " .. tostring(okHuge))
            local machine = RoundMachine.new({
                phases = { { name = "ACTIVE", duration = 5 } },
            })
            local name = machine:current()
            assert(name == "ACTIVE", "current was " .. tostring(name))
            print('{"phase":true}')
        """)
        assert "phase" in out


if __name__ == "__main__":
    unittest.main()
