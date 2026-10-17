"""A derived formula must keep its own operation tables.

extended() and Formula.start() clone the ops array and leave each operation
table shared. Writing f.ops[1].value after g = f:add(1) then changes g:apply.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestFormulaIsolation(unittest.TestCase):
    def test_later_op_edit_does_not_change_derived_apply(self) -> None:
        out = _run([FORGE / "Economy"], """
            local Formula = Require("Formula")
            local f = Formula.start():add(5)
            local g = f:add(1)
            f.ops[1].value = 100
            local result = g:apply(0)
            assert(result == 6, "g:apply(0) must stay 0+5+1")
            print('{"formula":6}')
        """)
        assert "formula" in out


if __name__ == "__main__":
    unittest.main()
