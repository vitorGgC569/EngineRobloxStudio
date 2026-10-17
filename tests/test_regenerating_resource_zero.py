"""RegeneratingResource must treat an explicit regen of 0 as frozen."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRegeneratingResourceZero(unittest.TestCase):
    def test_explicit_zero_regen_does_not_climb(self) -> None:
        out = _run([FORGE / "Progression"], """
            local RegeneratingResource = Require("RegeneratingResource")
            local now = 0
            local bar = RegeneratingResource.new({
                cap = 10,
                startValue = 5,
                regenPerSecond = 0,
                snapshotInterval = 0,
                clock = function()
                    return now
                end,
            })
            bar:tick(10)
            now = 1
            local shown = bar:replicationValue()
            assert(shown == 5, "zero regen climbed, shown " .. tostring(shown))
            print('{"regen":true}')
        """)
        assert "regen" in out


if __name__ == "__main__":
    unittest.main()
