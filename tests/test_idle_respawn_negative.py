"""IdleGenerator must refuse a respawn that would make a coin live again immediately."""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestIdleRespawnNegative(unittest.TestCase):
    def test_negative_respawn_is_refused_and_a_positive_respawn_cools_down(self) -> None:
        out = _run([FORGE / "Progression"], """
            local IdleGenerator = Require("IdleGenerator")
            local generator = IdleGenerator.new({
                clock = function()
                    return 0
                end,
            })
            local ok = pcall(function()
                generator:addCoin("c", 3, -10)
            end)
            assert(ok == false, "negative respawn was accepted")
            generator:addCoin("ok", 3, 5)
            local payout = generator:collect("ok")
            assert(payout == 3, "collect paid " .. tostring(payout))
            local again, reason = generator:collect("ok")
            assert(reason == "on_cooldown", "second collect reason " .. tostring(reason) .. " payout " .. tostring(again))
            print('{"respawn":true}')
        """)
        assert "respawn" in out


if __name__ == "__main__":
    unittest.main()
