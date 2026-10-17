"""A channel must keep its own copy of the ad list it was given.

CrossServerChannels.new stored config.ads by reference. Replacing ads[1]
after new changed currentAd.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestCrossServerChannelsIsolation(unittest.TestCase):
    def test_later_ad_edit_does_not_change_current_ad(self) -> None:
        out = _run([FORGE / "Tycoon"], """
            local CrossServerChannels = Require("CrossServerChannels")
            local ads = { "hat" }
            local channels = CrossServerChannels.new({
                ads = ads,
                adSlotSeconds = 300,
                clock = function() return 0 end,
            })
            ads[1] = "hacked"
            local ad = channels:currentAd()
            assert(ad == "hat", "currentAd must keep the ad from new")
            print('{"ad":"hat"}')
        """)
        assert "ad" in out


if __name__ == "__main__":
    unittest.main()
