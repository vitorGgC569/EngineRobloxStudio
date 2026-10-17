"""A negative tick must not stretch the phase that is already running.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A 10 second phase ticked by -5 must still have 10 seconds left.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRoundMachineNegative(unittest.TestCase):
    def test_negative_dt_does_not_grow_remaining(self) -> None:
        """A 10 second phase ticked by -5 still has 10 seconds left."""
        out = _run([FORGE / "Match"], """
            local RoundMachine = Require("RoundMachine")
            local machine = RoundMachine.new({
                phases = { { name = "ACTIVE", duration = 10 } },
            })
            machine:tick(-5)
            local left = machine:remaining()
            assert(left == 10, "remaining was " .. tostring(left))
            print('{"round":true}')
        """)
        assert "round" in out


if __name__ == "__main__":
    unittest.main()
