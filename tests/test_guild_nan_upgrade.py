"""A NaN balance must not buy a guild upgrade.

`funds < cost` is false for NaN, so `applyUpgrade` accepts `0/0` and the
returned funds stay NaN. A real balance still pays for the next level.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestGuildNanUpgrade(unittest.TestCase):
    def test_nan_funds_do_not_upgrade_and_a_real_balance_does(self) -> None:
        out = _run([FORGE / "Social"], """
            local GuildModel = Require("GuildModel")
            local guild = GuildModel.new()
            local state = GuildModel.create("North")
            state.funds = 0/0
            state.level = 1
            local nanResult = guild:applyUpgrade(state)
            assert(nanResult == nil, "nan upgrade must return nil")
            assert(state.level == 1, "level must stay 1, got " .. tostring(state.level))
            state.funds = 100000
            local ok = guild:applyUpgrade(state)
            assert(ok ~= nil and ok.level == 2, "funded upgrade must return level 2, got " .. tostring(ok and ok.level))
            print('{"upgrade":true}')
        """)
        assert "upgrade" in out


if __name__ == "__main__":
    unittest.main()
