"""Entitlement definitions must not stay shared with the caller.

Changing assetId after `new` must not make `refresh` look up a different
asset than the one registered.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestEntitlementTagsIsolation(unittest.TestCase):
    def test_changing_asset_id_after_new_does_not_move_the_check(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local EntitlementTags = Require("EntitlementTags")
            local def = { assetId = 1 }
            local checker = {
                ownsAsset = function(assetId)
                    return assetId == 1
                end,
                hasBadge = function()
                    return false
                end,
                inGroup = function()
                    return false
                end,
            }
            local tags = EntitlementTags.new({ vip = def }, checker)
            def.assetId = 2
            tags:refresh()
            assert(tags:has("vip") == true, "has vip must stay true")
            print('{"tag":true}')
        """)
        assert "tag" in out


if __name__ == "__main__":
    unittest.main()
