"""A placement plan must keep its own copy of the plot it was given.

GridPlacement.new used to store the caller's bounds and item tables. Growing
a footprint or shrinking the plot afterwards made fits reject a cell that
was inside at construction.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestGridPlacementIsolation(unittest.TestCase):
    def test_later_edits_do_not_change_fits(self) -> None:
        out = _run([FORGE / "Tycoon"], """
            local GridPlacement = Require("GridPlacement")
            local bounds = { minX = 0, minZ = 0, maxX = 30, maxZ = 30 }
            local item = { id = "box", footprintX = 1, footprintZ = 1 }
            local grid = GridPlacement.new({
                cellSize = 3,
                bounds = bounds,
                items = { item },
            })
            item.footprintX = 100
            bounds.maxX = 1
            local ok = grid:fits("box", 0, { x = 15, z = 15 })
            assert(ok == true, "fits must still accept a cell that was inside")
            local read = grid:item("box")
            read.footprintX = 100
            local still = grid:fits("box", 0, { x = 15, z = 15 })
            assert(still == true, "editing item() rewrote the stored footprint")
            print('{"grid":true}')
        """)
        assert "grid" in out


if __name__ == "__main__":
    unittest.main()
