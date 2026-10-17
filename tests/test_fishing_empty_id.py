"""A fishing drop cannot be stored with an empty id.

addDrop checks the weight and not the id. An empty id is accepted, and
rollLoot can later return that blank string.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestFishingEmptyId(unittest.TestCase):
    def test_empty_drop_id_is_refused(self) -> None:
        out = _run([FORGE / "Progression", FORGE / "Core"], """
            local FishingMinigame = Require("FishingMinigame")
            local game = FishingMinigame.new({
                drops = { { id = "carp", weight = 1, minProfessionLevel = 0, minRodTier = 1 } },
                seed = 1,
                now = function() return 0 end,
            })
            local emptyOk = pcall(function()
                game:addDrop({ id = "", weight = 1, minProfessionLevel = 0, minRodTier = 1 })
            end)
            assert(emptyOk == false, "an empty id must be refused")
            local fish = game:rollLoot(0, 1)
            assert(fish == "carp", "the starter drop must still roll, got " .. tostring(fish))
            print('{"fish":"carp"}')
        """)
        assert "fish" in out


if __name__ == "__main__":
    unittest.main()
