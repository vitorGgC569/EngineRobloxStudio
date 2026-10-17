"""Combo steps returned by advance must not be the stored tables.

Writing damage on the step advance handed back must not change the next
advance of the same link.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestComboSequencerIsolation(unittest.TestCase):
    def test_damage_written_on_the_returned_step_does_not_stick(self) -> None:
        out = _run([FORGE / "Combat"], """
            local ComboSequencer = Require("ComboSequencer")
            local a = { name = "a", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local b = { name = "b", damage = 5, windup = 0, recovery = 0, nextWindow = 1 }
            local combo = ComboSequencer.new({
                steps = { a, b },
                resetTimeout = 10,
                bufferWindow = 1,
            })
            combo:press(0)
            local first = combo:advance("a", 0)
            assert(first.name == "b", "advance from a must return b, got " .. tostring(first and first.name))
            first.damage = 99
            combo:press(0.1)
            local second = combo:advance("a", 0.1)
            assert(second.damage == 5, "next advance damage must stay 5, got " .. tostring(second and second.damage))
            print('{"combo":true}')
        """)
        assert "combo" in out


if __name__ == "__main__":
    unittest.main()
