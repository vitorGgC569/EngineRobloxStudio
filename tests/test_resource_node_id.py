"""A resource node cannot be defined with an empty id.

ResourceNodes.define stores any id, including "". harvest("") then
succeeds on a node that has no name.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestResourceNodeId(unittest.TestCase):
    def test_empty_node_id_is_refused(self) -> None:
        out = _run([FORGE / "Tycoon"], """
            local ResourceNodes = Require("ResourceNodes")
            local nodes = ResourceNodes.new({ clock = function() return 0 end })
            local emptyOk = pcall(function()
                nodes:define("", 3, 5)
            end)
            assert(emptyOk == false, "an empty id must be refused")
            nodes:define("ore", 3, 5)
            local harvested = nodes:harvest("ore")
            assert(harvested == true, "ore must harvest")
            assert(nodes:isAvailable("ore") == true, "ore must stay available")
            print('{"node":"ore"}')
        """)
        assert "node" in out


if __name__ == "__main__":
    unittest.main()
