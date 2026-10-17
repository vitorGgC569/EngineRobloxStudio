"""Queue.join must refuse an empty key.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. An empty key must not occupy a match slot; a real key still joins.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestQueueEmptyKey(unittest.TestCase):
    def test_empty_key_does_not_take_a_slot(self) -> None:
        """join('') is refused and ada is the only member."""
        out = _run([FORGE / "Match"], """
            local Queue = Require("Queue")
            local queue = Queue.new()
            local joined = queue:join("")
            assert(joined == false, "empty join was " .. tostring(joined))
            assert(queue:size() == 0, "size after empty was " .. tostring(queue:size()))
            local ada = queue:join("ada")
            assert(ada == true, "ada join was " .. tostring(ada))
            assert(queue:size() == 1, "size after ada was " .. tostring(queue:size()))
            print('{"queue":true}')
        """)
        assert "queue" in out


if __name__ == "__main__":
    unittest.main()
