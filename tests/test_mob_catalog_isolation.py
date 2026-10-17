"""MobCatalog must not share the entry tables it stores or returns."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestMobCatalogIsolation(unittest.TestCase):
    def test_new_and_pick_do_not_share_entry_tables(self) -> None:
        out = _run([FORGE / "AI", FORGE / "Core"], """
            local MobCatalog = Require("MobCatalog")
            local Rng = Require("Rng")
            local entry = { id = "slime", size = 2 }
            local catalog = MobCatalog.new({ entry })
            entry.size = 99
            local picked = catalog:pick(Rng.xorshift(1))
            assert(picked.size == 2, "pick followed the mutated entry, size " .. tostring(picked.size))
            picked.size = 0
            local again = catalog:pick(Rng.xorshift(1))
            assert(again.size == 2, "pick returned the stored entry, size " .. tostring(again.size))
            print('{"mob":true}')
        """)
        assert "mob" in out


if __name__ == "__main__":
    unittest.main()
