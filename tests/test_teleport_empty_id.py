"""A teleport pad cannot be defined with an empty id.

define stores any id, including "". use("") then succeeds on a pad that
has no name.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTeleportEmptyId(unittest.TestCase):
    def test_empty_pad_id_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local TeleportPads = Require("TeleportPads")
            local pads = TeleportPads.new(function() return 0 end)
            local emptyOk = pcall(function()
                pads:define("", "b", 2)
            end)
            assert(emptyOk == false, "an empty id must be refused")
            pads:define("a", "b", 2)
            pads:define("b", "a", 2)
            local dest = pads:use("a")
            assert(dest == "b", "the named pad must still jump")
            print('{"pad":"b"}')
        """)
        assert "pad" in out


if __name__ == "__main__":
    unittest.main()
