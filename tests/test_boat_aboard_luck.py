"""Aboard luck is rolled, not just displayed.

The HUD derived "aboard your own boat" from the seat's `Owner` attribute and
showed the boat's luck bonus in the total. FishingService.beginBite passed a
hardcoded `false` into the same stack, so the bonus existed only on screen.
These tests pin the roll side: Roll.luckTotal moves by exactly the boat's
luck and only while aboard, the draw responds to that luck, and the service
reads the seat instead of the constant it used to.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "games/tidebound/src/shared"
FISHING = ROOT / "games/tidebound/src/server/Services/FishingService.luau"


def _run(body: str) -> str:
    return run_or_raise(ROOT, libraries=[SHARED], body=body).stdout


class TestAboardLuck(unittest.TestCase):
    def test_boat_luck_applies_only_aboard(self) -> None:
        out = _run("""
            local Roll = Require("Roll")

            local ashoreCutter = Roll.luckTotal(1, "bamboo", nil, "cutter", false)
            local ashoreRowboat = Roll.luckTotal(1, "bamboo", nil, "rowboat", false)
            assert(ashoreCutter == ashoreRowboat,
                "a boat you are not sitting in must change nothing")

            local aboardCutter = Roll.luckTotal(1, "bamboo", nil, "cutter", true)
            assert(aboardCutter - ashoreRowboat == 2, "the Tide Cutter is +2 aboard")
            local aboardTrawler = Roll.luckTotal(1, "bamboo", nil, "trawler", true)
            assert(aboardTrawler - ashoreRowboat == 1, "the Trawler is +1 aboard")
            local aboardRowboat = Roll.luckTotal(1, "bamboo", nil, "rowboat", true)
            assert(aboardRowboat == ashoreRowboat, "the Rowboat's bonus is zero either way")
            print('{"aboard":"ok"}')
        """)
        assert "aboard" in out

    def test_luck_moves_the_draw_at_the_same_seed(self) -> None:
        out = _run("""
            local Roll = Require("Roll")

            --: A tiny deterministic stream, so the whole check is a pure
            --: computation: same seed in, same fish out, forever.
            local function draw(luck, seed)
                local state = seed
                return Roll.fish({
                    zoneId = "shallows",
                    luck = luck,
                    hour = 12,
                    weather = "clear",
                    bait = nil,
                    rng = function()
                        state = (state * 1103515245 + 12345) % 2147483648
                        return state / 2147483648
                    end,
                })
            end

            local a = draw(3, 7)
            local b = draw(3, 7)
            assert(a.speciesId == b.speciesId and a.weightKg == b.weightKg,
                "the same seed and stack must be the same fish")

            --: Cutter aboard vs ashore at the same seed: +2 luck must move at
            --: least one draw's outcome, or luck is decorative.
            local moved = 0
            for seed = 1, 60 do
                local low = draw(3, seed)
                local high = draw(5, seed)
                if low.rarity ~= high.rarity
                    or low.speciesId ~= high.speciesId
                    or low.weightKg ~= high.weightKg
                    or low.mutation ~= high.mutation then
                    moved += 1
                end
            end
            assert(moved > 0, "the boat's +2 luck never moved a single draw across 60 seeds")
            print('{"moved":' .. moved .. '}')
        """)
        assert "moved" in out

    def test_service_reads_the_seat_not_a_constant(self) -> None:
        source = FISHING.read_text(encoding="utf-8")
        index = source.find("Roll.luckTotal(")
        self.assertGreaterEqual(index, 0, "FishingService must still roll luck through Roll.luckTotal")
        call = source[index : index + 400]
        self.assertIn("aboardSeat(player) ~= nil", call)
        self.assertNotIn("false", call.split("WeatherService.luckBonus()")[0])
        self.assertIn(
            'seat:GetAttribute("Owner") == player.UserId',
            source,
            "the aboard predicate must be the seat's Owner attribute, the same one the HUD reads",
        )


if __name__ == "__main__":
    unittest.main()
