"""SnapshotInterp must not keep the caller's pose table."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestSnapshotInterpIsolation(unittest.TestCase):
    def test_reused_pose_does_not_move_the_previous_sample(self) -> None:
        out = _run([FORGE / "AI"], """
            local SnapshotInterp = Require("SnapshotInterp")
            local interp = SnapshotInterp.new({ targetSpan = 0.1, minSpan = 0.01, maxSpan = 0.25 })
            local pose = { x = 0, y = 0, z = 0, yaw = 0 }
            interp:feed("mob", pose, 0)
            pose.x = 10
            interp:feed("mob", pose, 0.1)
            local shown = interp:present("mob", 0.05)
            assert(shown.x < 9, "present blended from the reused pose, x " .. tostring(shown.x))
            print('{"pose":true}')
        """)
        assert "pose" in out

    def test_present_does_not_return_the_stored_pose(self) -> None:
        out = _run([FORGE / "AI"], """
            local SnapshotInterp = Require("SnapshotInterp")
            local interp = SnapshotInterp.new({ targetSpan = 0.1, minSpan = 0.01, maxSpan = 0.25 })
            local pose = { x = 0, y = 0, z = 0, yaw = 0 }
            interp:feed("mob", pose, 0)
            pose.x = 10
            interp:feed("mob", pose, 0.1)
            local shown = interp:present("mob", 10)
            assert(math.abs(shown.x - 10) < 0.01, "finished blend was not at the last pose, x " .. tostring(shown.x))
            shown.x = 1000
            local again = interp:present("mob", 11)
            assert(math.abs(again.x - 10) < 0.01, "present returned the stored pose, x " .. tostring(again.x))
            print('{"shown":true}')
        """)
        assert "shown" in out


if __name__ == "__main__":
    unittest.main()
