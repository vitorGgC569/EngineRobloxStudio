"""A numeric config must be refused as a config.

Executed as real Luau through the pinned runtime. PlaytimeLadder.define
does config or {}. A config of 1 is truthy, so it is kept, and reading
settings.rungs throws without saying the config was wrong.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeBadConfig(unittest.TestCase):
    def test_a_numeric_config_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local accepted, err = pcall(function()
                PlaytimeLadder.define("shift", 1)
            end)
            assert(accepted == false, "a numeric config was accepted")
            assert(string.find(tostring(err), "config") ~= nil, "the error did not name the config, got " .. tostring(err))
            local ladder = PlaytimeLadder.define("ok", {
                rungs = { { at = 0, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            local reward = PlaytimeLadder.claim(ladder, state, "rung1")
            assert(reward.coins == 1, "the named ladder paid " .. tostring(reward and reward.coins))
            print('{"config":true}')
        """)
        self.assertIn("config", out)


if __name__ == "__main__":
    unittest.main()
