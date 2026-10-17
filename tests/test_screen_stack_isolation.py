"""The layer ScreenStack.top returns must not stay live.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. Clearing modal on that table must not let a layer underneath
receive input.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestScreenStackIsolation(unittest.TestCase):
    def test_returned_top_does_not_clear_the_modal(self) -> None:
        """The back layer stays blocked after the returned top is edited."""
        out = _run([FORGE / "UI"], """
            local ScreenStack = Require("VisualStack")
            local stack = ScreenStack.new()
            local back = stack:push(false)
            stack:push(true)
            assert(stack:canHandleInput(back) == false, "back accepted input before the edit")
            stack:top().modal = false
            assert(stack:canHandleInput(back) == false, "back accepted input after top.modal was cleared")
            print('{"stack":true}')
        """)
        assert "stack" in out


if __name__ == "__main__":
    unittest.main()
