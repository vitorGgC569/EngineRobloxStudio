"""EntityCatalog must not share the tables it stores or returns."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestEntityCatalogIsolation(unittest.TestCase):
    def test_define_does_not_share_special_or_the_returned_definition(self) -> None:
        out = _run([FORGE / "Combat"], """
            local EntityCatalog = Require("EntityCatalog")
            local catalog = EntityCatalog.new()
            local special = { kind = "splash", radius = 8 }
            catalog:define({
                id = "mage",
                hp = 10,
                damage = 1,
                attackSpeed = 1,
                range = 1,
                speed = 1,
                cost = 1,
                size = 1,
                special = special,
            })
            special.kind = "spawn"
            special.unitId = "imp"
            special.count = 3
            local deployed = catalog:expandDeploy("mage")
            assert(#deployed == 1 and deployed[1] == "mage",
                "expandDeploy followed the mutated special")
            catalog:get("mage").hp = 0
            assert(catalog:get("mage").hp == 10, "get returned the stored definition")
            print('{"entity":true}')
        """)
        assert "entity" in out


if __name__ == "__main__":
    unittest.main()
