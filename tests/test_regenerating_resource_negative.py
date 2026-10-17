"""RegeneratingResource must ignore a rewind. A negative dt is not a spend."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRegeneratingResourceNegative(unittest.TestCase):
    def test_negative_dt_does_not_drain_the_bar(self) -> None:
        out = _run([FORGE / "Progression"], """
            local RegeneratingResource = Require("RegeneratingResource")
            local bar = RegeneratingResource.new({
                cap = 10,
                startValue = 5,
                regenPerSecond = 1,
                snapshotInterval = 0,
                clock = function()
                    return 0
                end,
            })
            bar:tick(-100)
            local shown = bar:replicationValue()
            assert(shown == 5, "negative dt drained the bar, shown " .. tostring(shown))
            print('{"regen":true}')
        """)
        assert "regen" in out


if __name__ == "__main__":
    unittest.main()
