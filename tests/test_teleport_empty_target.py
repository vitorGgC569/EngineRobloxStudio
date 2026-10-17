"""A teleport pad cannot point at an empty target.

define refuses an empty id and still stores targetPadId when it is "".
use then looks up a pad that cannot exist and returns broken_link.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTeleportEmptyTarget(unittest.TestCase):
    def test_empty_target_id_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local TeleportPads = Require("TeleportPads")
            local pads = TeleportPads.new(function() return 0 end)
            local emptyOk = pcall(function()
                pads:define("a", "", 2)
            end)
            assert(emptyOk == false, "an empty target must be refused")
            pads:define("a", "b", 2)
            pads:define("b", "a", 2)
            local dest = pads:use("a")
            assert(dest == "b", "the named target must still be reached")
            print('{"target":"b"}')
        """)
        assert "target" in out


if __name__ == "__main__":
    unittest.main()
