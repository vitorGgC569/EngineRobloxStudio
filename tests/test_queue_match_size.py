"""Queue.new must refuse a match size below 1.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. Zero and negative sizes must fail; a size of 2 still accepts a
player.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestQueueMatchSize(unittest.TestCase):
    def test_zero_and_negative_match_size_are_refused(self) -> None:
        """new rejects 0 and -1, and a size of 2 still queues ada."""
        out = _run([FORGE / "Match"], """
            local Queue = Require("Queue")
            local okZero = pcall(function()
                Queue.new({ playersPerMatch = 0 })
            end)
            assert(okZero == false, "new(0) was " .. tostring(okZero))
            local okNegative = pcall(function()
                Queue.new({ playersPerMatch = -1 })
            end)
            assert(okNegative == false, "new(-1) was " .. tostring(okNegative))
            local queue = Queue.new({ playersPerMatch = 2 })
            local ada = queue:join("ada")
            assert(ada == true, "ada join was " .. tostring(ada))
            assert(queue:size() == 1, "size was " .. tostring(queue:size()))
            print('{"queue":true}')
        """)
        assert "queue" in out


if __name__ == "__main__":
    unittest.main()
