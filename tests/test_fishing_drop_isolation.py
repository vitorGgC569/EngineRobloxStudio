"""Drop tables must stay sealed after new and addDrop.

Executed as real Luau through the pinned runtime. A shallow clone of the
drop list keeps each drop shared with the caller, so zeroing a weight
after new or addDrop makes the next roll return nothing.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestFishingDropIsolation(unittest.TestCase):
    def test_a_later_weight_edit_does_not_empty_the_pool(self) -> None:
        out = _run([FORGE / "Progression", FORGE / "Core"], """
            local FishingMinigame = Require("FishingMinigame")
            local starter = { id = "carp", weight = 1, minProfessionLevel = 100, minRodTier = 1 }
            local game = FishingMinigame.new({
                drops = { starter },
                seed = 1,
                now = function()
                    return 0
                end,
            })
            starter.weight = 0
            local carp = game:rollLoot(100, 1)
            assert(carp == "carp", "zeroing the starter weight emptied the pool, got " .. tostring(carp))

            local eel = { id = "eel", weight = 1, minProfessionLevel = 0, minRodTier = 1 }
            game:addDrop(eel)
            eel.weight = 0
            local rolled = game:rollLoot(0, 1)
            assert(rolled == "eel", "zeroing the added weight emptied the pool, got " .. tostring(rolled))
            print('{"fishing":true}')
        """)
        self.assertIn("fishing", out)


if __name__ == "__main__":
    unittest.main()
