"""An empty rung id must not be stored.

Executed as real Luau through the pinned runtime. Rung ids use
`rung.id or ("rung" .. index)`. "" is truthy, so an empty id is kept
and claim("") takes that rung.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeEmptyRungId(unittest.TestCase):
    def test_an_empty_rung_id_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local accepted = pcall(function()
                PlaytimeLadder.define("blank", {
                    rungs = { { at = 0, id = "", reward = { coins = 1 } } },
                })
            end)
            assert(accepted == false, "an empty rung id was accepted")
            local ladder = PlaytimeLadder.define("named", {
                rungs = { { at = 0, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            local reward = PlaytimeLadder.claim(ladder, state, "rung1")
            assert(reward.coins == 1, "the generated id paid " .. tostring(reward and reward.coins))
            print('{"rungid":true}')
        """)
        self.assertIn("rungid", out)


if __name__ == "__main__":
    unittest.main()
