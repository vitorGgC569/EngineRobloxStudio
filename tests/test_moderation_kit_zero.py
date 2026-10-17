"""An explicit decay of zero must not fade scores.

Executed as real Luau through the pinned runtime. `decayPerHour or 1`
treats 0 as missing, so a severity-5 report fades by 1 per hour even
when the config asked for no fade.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestModerationKitZero(unittest.TestCase):
    def test_zero_decay_keeps_a_report_at_full_severity(self) -> None:
        out = _run([FORGE / "Social"], """
            local ModerationKit = Require("ModerationKit")
            local now = 0
            local kit = ModerationKit.new({
                decayPerHour = 0,
                clock = function()
                    return now
                end,
            })
            kit:report(1, 5)
            now = 7200
            local score = kit:score(1)
            assert(score == 5, "a decay of 0 faded the report, got " .. tostring(score))
            print('{"decay":true}')
        """)
        self.assertIn("decay", out)


if __name__ == "__main__":
    unittest.main()
