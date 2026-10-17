"""A ladder scope must be session or lifetime.

Executed as real Luau through the pinned runtime. PlaytimeLadder.define
stores scope or "session". "nope" is truthy, so it is kept, and begin
then drops saved elapsed time.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeBadScope(unittest.TestCase):
    def test_an_unknown_scope_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local accepted = pcall(function()
                PlaytimeLadder.define("bad", {
                    scope = "nope",
                    rungs = { { at = 10, reward = { coins = 1 } } },
                })
            end)
            assert(accepted == false, "an unknown scope was accepted")
            local ladder = PlaytimeLadder.define("life", {
                scope = "lifetime",
                rungs = { { at = 10, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder, { elapsed = 5, claimed = {} })
            assert(state.elapsed == 5, "saved elapsed became " .. tostring(state.elapsed))
            print('{"scope":true}')
        """)
        self.assertIn("scope", out)


if __name__ == "__main__":
    unittest.main()
