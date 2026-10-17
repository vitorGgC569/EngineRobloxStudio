"""Objective markers must not stay shared with the caller.

Changing `text` after `setMarkers`, or on the table `activeMarker` handed
back, must not rewrite the plan the next read still uses.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestObjectiveTrackerIsolation(unittest.TestCase):
    def test_text_edits_after_set_and_after_read_do_not_rewrite_the_plan(self) -> None:
        out = _run([FORGE / "UI"], """
            local ObjectiveTracker = Require("ObjectiveTracker")
            local tracker = ObjectiveTracker.new()
            local marker = { targetName = "ore", offsetY = 2, alwaysOnTop = true, text = "mine" }
            tracker:setMarkers({ marker })
            marker.text = "gone"
            local first = tracker:activeMarker()
            assert(first.text == "mine", "caller mutation must not rewrite the plan, got " .. tostring(first.text))
            first.text = "gone"
            local second = tracker:activeMarker()
            assert(second.text == "mine", "returned marker must not be the stored plan, got " .. tostring(second.text))
            print('{"marker":true}')
        """)
        assert "marker" in out


if __name__ == "__main__":
    unittest.main()
