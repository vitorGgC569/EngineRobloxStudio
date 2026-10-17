"""A NaN donation must not land in guild funds.

`amount <= 0` is false for NaN, so `donate` accepts `0/0` and the returned
funds become NaN. Only a finite amount above zero may be accepted.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestGuildNanDonate(unittest.TestCase):
    def test_nan_donate_is_rejected_and_a_real_amount_still_lands(self) -> None:
        out = _run([FORGE / "Social"], """
            local GuildModel = Require("GuildModel")
            local guild = GuildModel.new()
            local state = GuildModel.create("North")
            state.members[1] = 1
            local nanResult = guild:donate(state, 1, 0/0)
            assert(nanResult == nil, "nan donate must return nil")
            assert(state.funds == 0, "funds must stay 0, got " .. tostring(state.funds))
            local ok = guild:donate(state, 1, 10)
            assert(ok ~= nil and ok.funds == 10, "donate 10 must return funds 10, got " .. tostring(ok and ok.funds))
            print('{"guild":true}')
        """)
        assert "guild" in out


if __name__ == "__main__":
    unittest.main()
