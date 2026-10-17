"""RoundMachine must not share the phase tables it stores."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRoundMachineIsolation(unittest.TestCase):
    def test_new_does_not_share_phase_tables(self) -> None:
        out = _run([FORGE / "Match"], """
            local RoundMachine = Require("RoundMachine")
            local phase = { name = "ACTIVE", duration = 10 }
            local machine = RoundMachine.new({ phases = { phase } })
            phase.duration = 1
            local left = machine:remaining()
            assert(left == 10, "remaining followed the mutated phase, left " .. tostring(left))
            print('{"round":true}')
        """)
        assert "round" in out


if __name__ == "__main__":
    unittest.main()
