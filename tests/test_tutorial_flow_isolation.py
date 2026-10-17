"""TutorialFlow must not share the step tables it stores."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTutorialFlowIsolation(unittest.TestCase):
    def test_new_does_not_share_step_tables(self) -> None:
        out = _run([FORGE / "Progression"], """
            local TutorialFlow = Require("TutorialFlow")
            local step = { id = "mine", missionId = "m" }
            local flow = TutorialFlow.new({ step })
            flow:begin("p")
            step.id = "hacked"
            local current = flow:currentStep("p")
            assert(current == "mine", "currentStep followed the mutated step, id " .. tostring(current))
            print('{"tutorial":true}')
        """)
        assert "tutorial" in out


if __name__ == "__main__":
    unittest.main()
