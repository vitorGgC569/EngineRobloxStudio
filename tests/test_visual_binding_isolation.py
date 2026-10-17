"""Nested values passed to VisualBinding.set must not stay live.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. Editing the table given to set, or the table get returns, must
not change the next read.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestVisualBindingIsolation(unittest.TestCase):
    def test_caller_and_returned_score_do_not_rewrite_the_binding(self) -> None:
        """The stored score stays 1 after either table is edited."""
        out = _run([FORGE / "UI"], """
            local Binding = Require("VisualBinding")
            local binding = Binding.new()
            local score = { n = 1 }
            binding:set("score", score)
            score.n = 9
            local first = binding:get("score")
            assert(first.n == 1, "score n was " .. tostring(first.n))
            first.n = 0
            local second = binding:get("score")
            assert(second.n == 1, "next score n was " .. tostring(second.n))
            print('{"bind":true}')
        """)
        assert "bind" in out


if __name__ == "__main__":
    unittest.main()
