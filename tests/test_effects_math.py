"""Lock the pure math `effects.luau` and `audio.luau` add, and the id policy.

Three things are asserted here, and each guards a different failure:

* **The mirrored math.** Bounds, monotonicity and clamp behaviour of every
  scaled-effect curve -- rarity scale is monotone so a mythic never shakes
  less than a common, proximity is monotone so the sea never gets louder as
  you climb away from it.
* **The expressions themselves.** The formulas live in Luau; this file
  extracts the exact `return` expression from each function and pins it. A
  balance tweak on one side without the other fails here instead of silently
  changing the feel of the game.
* **The asset-id policy.** `forge doctor` refuses any asset reference that
  has never been loaded in Studio. The ids these two files use are either
  `rbxasset://` engine files already in the verification registry, or
  resolved from `Audio.Bank` at runtime -- no `rbxassetid://` literal is
  allowed to appear at all, because an id copied from memory is silence.

    python -m unittest tests.test_effects_math -v
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / "games" / "tidebound" / "src" / "client"
EFFECTS = GAME / "effects.luau"
AUDIO = GAME / "audio.luau"
REGISTRY = ROOT / "forge" / "catalog" / "assets-verified.json"

#: Only refs that name a real file: `rbxasset://sounds/...` in prose is not one.
ID_PATTERN = re.compile(r"rbxassetid://(\d+)|rbxasset://([A-Za-z0-9_\-./]*\.[A-Za-z0-9]+)")
NUMERIC_ID_PATTERN = re.compile(r"rbxassetid://\d")


def expression(source: str, signature: str) -> str:
    """The exact `return` expression of a one-line Luau function."""

    pattern = re.compile(
        r"function\s+" + re.escape(signature) + r"\([^\n]*\n\treturn\s+([^\n]+)\nend"
    )
    match = pattern.search(source)
    if not match:
        raise AssertionError(f"no one-line return found for {signature}")
    return match.group(1).strip()


# ----------------------------------------------------------------- the mirror
# Every function below is a hand-mirror of the Luau it is pinned against.


def rarity_scale(order: float) -> float:
    return 0.8 + 0.28 * min(max(order, 1), 6)


def catch_shake(order: float) -> float:
    return 0.13 * rarity_scale(order)


def catch_punch(order: float) -> float:
    return 1.0 + 0.5 * min(max(order, 1), 6)


def catch_hitstop(order: float) -> float:
    return 0.04 + 0.012 * min(max(order, 1), 6)


def splash_drops(order: float) -> int:
    import math

    return math.floor(12 + 6 * min(max(order, 1), 6))


def level_pulse(level: float) -> float:
    return min(max(1.0 + 0.02 * level, 1.0), 1.6)


def sell_burst_scale(coins: float) -> float:
    return min(max(0.6 + coins / 4000, 0.6), 2.2)


def proximity_scale(height_above_water: float) -> float:
    return min(max(1 - height_above_water / 60, 0.25), 1)


def monotone(values: list[float], increasing: bool = True) -> bool:
    pairs = zip(values, values[1:])
    return all(b >= a for a, b in pairs) if increasing else all(b <= a for a, b in pairs)


class EffectsMathTest(unittest.TestCase):
    """The curves the catch/bite/level-up effects are scaled by."""

    def test_rarity_scale_is_monotone_and_bounded(self) -> None:
        orders = [1, 2, 3, 4, 5, 6]
        values = [rarity_scale(order) for order in orders]
        self.assertTrue(monotone(values))
        self.assertAlmostEqual(values[0], 1.08)
        self.assertAlmostEqual(values[-1], 2.48)
        # outside the catalogue the curve clamps rather than extrapolates
        self.assertAlmostEqual(rarity_scale(0), rarity_scale(1))
        self.assertAlmostEqual(rarity_scale(99), rarity_scale(6))

    def test_catch_shake_is_small_and_rarer_is_bigger(self) -> None:
        values = [catch_shake(order) for order in range(1, 7)]
        self.assertTrue(monotone(values))
        self.assertGreater(values[0], 0)
        # small on purpose: trauma is squared downstream, so 0.35 is already
        # a violent shake and a catch must not be one
        self.assertLessEqual(values[-1], 0.35)

    def test_catch_punch_bounds(self) -> None:
        self.assertAlmostEqual(catch_punch(1), 1.5)
        self.assertAlmostEqual(catch_punch(6), 4.0)
        self.assertAlmostEqual(catch_punch(-3), catch_punch(1))

    def test_catch_hitstop_bounds(self) -> None:
        values = [catch_hitstop(order) for order in range(1, 7)]
        self.assertTrue(monotone(values))
        self.assertGreaterEqual(values[0], 0.04)
        # never long enough to read as lag
        self.assertLessEqual(values[-1], 0.12)

    def test_splash_drops_are_integers_within_bounds(self) -> None:
        values = [splash_drops(order) for order in range(1, 7)]
        self.assertTrue(monotone(values))
        for value in values:
            self.assertEqual(value, int(value))
        self.assertEqual(values[0], 18)
        self.assertEqual(values[-1], 48)

    def test_level_pulse_is_bounded_by_design(self) -> None:
        self.assertGreaterEqual(level_pulse(1), 1.0)
        self.assertAlmostEqual(level_pulse(30), 1.6)
        self.assertAlmostEqual(level_pulse(1000), 1.6)
        self.assertTrue(monotone([level_pulse(level) for level in range(1, 31)]))

    def test_sell_burst_scale_is_bounded(self) -> None:
        self.assertAlmostEqual(sell_burst_scale(0), 0.6)
        self.assertAlmostEqual(sell_burst_scale(6400), 2.2)
        self.assertAlmostEqual(sell_burst_scale(10**9), 2.2)
        self.assertTrue(
            monotone([sell_burst_scale(coins) for coins in range(0, 6401, 400)])
        )


class AmbienceMathTest(unittest.TestCase):
    """The sea-loudness curve the ambience mix is scaled by."""

    def test_proximity_scale_bounds(self) -> None:
        self.assertAlmostEqual(proximity_scale(0), 1.0)
        self.assertAlmostEqual(proximity_scale(30), 0.5)
        self.assertAlmostEqual(proximity_scale(60), 0.25)
        self.assertAlmostEqual(proximity_scale(500), 0.25)
        # under the waterline (swimming) the sea is at full, not above full
        self.assertAlmostEqual(proximity_scale(-10), 1.0)

    def test_proximity_scale_is_monotone_decreasing(self) -> None:
        values = [proximity_scale(height) for height in range(0, 121, 5)]
        self.assertTrue(monotone(values, increasing=False))


class SourcePinningTest(unittest.TestCase):
    """The Luau source still says exactly what the mirror asserts."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.effects = EFFECTS.read_text(encoding="utf-8")
        cls.audio = AUDIO.read_text(encoding="utf-8")

    def test_effects_expressions_are_pinned(self) -> None:
        expected = {
            "Effects.math.rarityScale": "0.8 + 0.28 * math.clamp(order, 1, 6)",
            "Effects.math.catchShake": "0.13 * Effects.math.rarityScale(order)",
            "Effects.math.catchPunch": "1.0 + 0.5 * math.clamp(order, 1, 6)",
            "Effects.math.catchHitstop": "0.04 + 0.012 * math.clamp(order, 1, 6)",
            "Effects.math.splashDrops": "math.floor(12 + 6 * math.clamp(order, 1, 6))",
            "Effects.math.levelPulse": "math.clamp(1.0 + 0.02 * level, 1.0, 1.6)",
            "Effects.math.sellBurstScale": "math.clamp(0.6 + coins / 4000, 0.6, 2.2)",
        }
        for signature, want in expected.items():
            self.assertEqual(expression(self.effects, signature), want, signature)

    def test_audio_expression_is_pinned(self) -> None:
        self.assertEqual(
            expression(self.audio, "audio.proximityScale"),
            "math.clamp(1 - heightAboveWater / 60, 0.25, 1)",
        )


class AssetIdPolicyTest(unittest.TestCase):
    """No id a Studio has not loaded can ship, and none is copied by hand."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.effects = EFFECTS.read_text(encoding="utf-8")
        cls.audio = AUDIO.read_text(encoding="utf-8")

    def test_no_numeric_assetid_literals(self) -> None:
        # Bank ids are resolved at runtime via `Audio.Bank.forRole` (the
        # `rbxassetid://` scheme string alone is fine); a numeric id here
        # would be an id typed from memory.
        for name, text in (("effects.luau", self.effects), ("audio.luau", self.audio)):
            match = NUMERIC_ID_PATTERN.search(text)
            self.assertIsNone(match, f"{name} hardcodes {match and match.group(0)}")

    def test_every_engine_ref_is_verified(self) -> None:
        registry = {}
        if REGISTRY.exists():
            registry = json.loads(REGISTRY.read_text(encoding="utf-8")).get("assets") or {}
        if not registry:
            self.skipTest("asset verification registry is empty; run 'forge assets verify'")

        refs: set[str] = set()
        for text in (self.effects, self.audio):
            for match in ID_PATTERN.finditer(text):
                refs.add(
                    f"rbxassetid://{match.group(1)}"
                    if match.group(1)
                    else f"rbxasset://{match.group(2)}"
                )
        for ref in sorted(refs):
            record = registry.get(ref)
            self.assertIsNotNone(record, f"{ref} has never been verified")
            self.assertTrue(record.get("ok"), f"{ref} failed verification: {record.get('error')}")


if __name__ == "__main__":
    unittest.main()
