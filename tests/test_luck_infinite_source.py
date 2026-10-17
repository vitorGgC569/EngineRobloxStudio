"""An infinite luck source must not win the best multiplier.

`math.huge` is greater than every finite multiplier, so it replaces the
potion and the returned multiplier is infinite. A multiplier of 3 still
wins over the default of 1.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLuckInfiniteSource(unittest.TestCase):
    def test_huge_source_loses_and_a_finite_source_still_wins(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Luck = Require("Luck")
            local hugeMult, hugeSource = Luck.best({
                { active = true, multiplier = math.huge, source = "bug" },
                { active = true, multiplier = 2, source = "potion" },
            })
            assert(hugeMult == 2 and hugeSource == "potion", "huge source must lose, got " .. tostring(hugeMult) .. " " .. tostring(hugeSource))
            local passMult, passSource = Luck.best({
                { active = true, multiplier = 3, source = "pass" },
            })
            assert(passMult == 3 and passSource == "pass", "pass must win, got " .. tostring(passMult) .. " " .. tostring(passSource))
            print('{"luck":true}')
        """)
        assert "luck" in out


if __name__ == "__main__":
    unittest.main()
