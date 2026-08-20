"""The material family.

The reason this is a family rather than a parameter is the failure it prevents.
Material separation is 28% of an asset's visual score and it fails totally: the
surface reads as one value, the eye lands nowhere, and every hour of modelling
underneath it is wasted. Two of these tests exist because that failure already
happened once here in a way nothing reported.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.geometry.materials import (
    FLAT_PALETTE_SPREAD,
    MaterialError,
    MaterialSlot,
    apply,
    create,
    palette_roles,
    validate,
)

TOKENS = json.loads(Path("tokens/brickfarm.json").read_text(encoding="utf-8"))

#: The exact slots the critic's calibration ladder was built with, so the
#: prediction here can be checked against a measurement that actually happened.
GREY = MaterialSlot("grey", (140, 143, 148), 0.6)
DARK = MaterialSlot("dark", (30, 32, 38), 0.9)
LIGHT = MaterialSlot("light", (205, 200, 190), 0.4, metallic=0.3)
GLOW = MaterialSlot("glow", (70, 150, 240), 0.2, emissive=(90, 180, 255), emissive_strength=4.0)


class TestCreate(unittest.TestCase):
    def test_colours_come_from_the_token_set(self):
        """A program naming its own RGB is a second palette that drifts from the
        game's, and then the asset looks right alone and wrong in the world."""

        slot = create("ground", tokens=TOKENS)
        self.assertEqual(list(slot.base_color), TOKENS["palette"]["roles"]["ground"]["srgb"])
        self.assertEqual(slot.source, "token:ground")

    def test_an_unknown_role_lists_the_real_ones(self):
        with self.assertRaises(MaterialError) as caught:
            create("chartreuse", tokens=TOKENS)
        self.assertIn("ground", str(caught.exception))

    def test_darkening_keeps_the_hue_and_moves_the_value(self):
        """A recess is the same colour in shadow. Deriving it keeps the asset
        inside the palette instead of beside it."""

        base = create("pavement", tokens=TOKENS)
        shadow = create("pavement", tokens=TOKENS, darken=0.7)
        self.assertLess(shadow.luminance, base.luminance)
        for lit, dark in zip(base.base_color, shadow.base_color):
            self.assertAlmostEqual(dark, lit * 0.3, delta=1.5)

    def test_emission_is_what_makes_a_slot_focal(self):
        """A merely light material competes with lighting rather than beating
        it, and the critic measures whether anything pulls the eye."""

        self.assertFalse(create("pavement", tokens=TOKENS).is_focal)
        self.assertTrue(create("pathPrimary", tokens=TOKENS, emissive=True).is_focal)

    def test_every_declared_role_can_be_built(self):
        for entry in palette_roles(TOKENS):
            create(entry["role"], tokens=TOKENS)


class TestApplyPlacesMaterialsWhereTheySurvive(unittest.TestCase):
    """The defect this module was written around.

    Appending material slots to a joined object does not put anything in them:
    every polygon keeps `material_index` 0. An asset declaring three materials
    rendered entirely in the first one while its manifest reported three.
    """

    def _program(self):
        return {
            "schemaVersion": 1, "id": "t", "units": "studs", "result": "asset",
            "steps": [
                {"op": "box", "name": "body", "size": [4, 3, 1.4]},
                {"op": "box", "name": "mid", "size": [2, 2, 2]},
                {"op": "join", "name": "asset", "targets": ["body", "mid"]},
                {"op": "uv_unwrap", "target": "asset"},
            ],
        }

    def test_every_material_lands_before_the_join(self):
        updated = apply(self._program(), {
            "body": create("pavement", tokens=TOKENS, darken=0.7),
            "mid": create("pavement", tokens=TOKENS),
        })
        ops = [step["op"] for step in updated["steps"]]
        join_at = ops.index("join")
        material_positions = [i for i, op in enumerate(ops) if op == "material"]
        self.assertTrue(material_positions)
        for position in material_positions:
            self.assertLess(position, join_at)

    def test_each_material_follows_the_part_it_paints(self):
        updated = apply(self._program(), {"body": create("pavement", tokens=TOKENS)})
        steps = updated["steps"]
        body_at = next(i for i, s in enumerate(steps) if s.get("name") == "body")
        self.assertEqual(steps[body_at + 1]["op"], "material")
        self.assertEqual(steps[body_at + 1]["target"], "body")

    def test_a_material_step_on_the_joined_result_is_dropped(self):
        """Left in, it would clear the per-part slots and put everything back in
        one material -- silently, and after the parts were painted correctly."""

        program = self._program()
        program["steps"].insert(3, {
            "op": "material", "target": "asset",
            "slots": [{"name": "wrong", "baseColor": [1, 2, 3]}],
        })
        updated = apply(program, {"body": create("pavement", tokens=TOKENS)})
        targets = [s.get("target") for s in updated["steps"] if s["op"] == "material"]
        self.assertNotIn("asset", targets)

    def test_every_emitted_step_names_the_slot_it_assigns(self):
        updated = apply(self._program(), {"body": create("ground", tokens=TOKENS)})
        for step in updated["steps"]:
            if step["op"] == "material":
                self.assertIn("assign", step)
                self.assertLess(step["assign"], len(step["slots"]))

    def test_painting_a_part_the_program_never_builds_is_refused(self):
        with self.assertRaises(MaterialError) as caught:
            apply(self._program(), {"turret": create("ground", tokens=TOKENS)})
        self.assertIn("body", str(caught.exception))

    def test_the_result_still_compiles_as_a_program(self):
        """The whole point is producing something buildable. A program that
        passes here and fails the compiler has moved the error later, not
        removed it."""

        from rqe.geometry.program import compile_program

        updated = apply(self._program(), {
            "body": create("pavement", tokens=TOKENS, darken=0.7),
            "mid": create("pathPrimary", tokens=TOKENS, emissive=True),
        })
        compile_program(updated)


class TestValidatePredictsTheCritic(unittest.TestCase):
    def test_a_single_material_is_flat_and_says_so(self):
        report = validate([GREY])
        self.assertFalse(report["ok"])
        rules = [f["rule"] for f in report["findings"]]
        self.assertIn("material-flat", rules)
        self.assertIn("material-value-range", rules)

    def test_two_tones_from_the_same_tier_are_still_flat(self):
        """The subtle version of the failure: a palette that looks varied on
        paper and renders as one value."""

        report = validate([create("ground", tokens=TOKENS), create("groundAlt", tokens=TOKENS)])
        self.assertFalse(report["ok"])
        self.assertLess(report["predicted"]["luminanceSpread"], FLAT_PALETTE_SPREAD)

    def test_the_prediction_matches_what_the_critic_measured(self):
        """The claim that makes this worth running before a build.

        These three slots are what the calibration ladder's third and fourth
        rungs were built with, and the critic measured 71.0 on the renders."""

        predicted = validate([DARK, LIGHT, GLOW])["predicted"]["luminanceSpread"]
        self.assertAlmostEqual(predicted, 71.0, delta=6.0)

    def test_a_good_set_passes(self):
        report = validate([DARK, LIGHT, GLOW])
        self.assertTrue(report["ok"], report["findings"])
        self.assertEqual(report["predicted"]["focalSlots"], ["glow"])

    def test_a_set_with_no_focal_point_is_flagged_but_not_blocked(self):
        """Not every asset needs a highlight, so this informs rather than
        refuses -- but the critic will score focal contrast either way."""

        report = validate([DARK, LIGHT])
        severities = {f["rule"]: f["severity"] for f in report["findings"]}
        self.assertEqual(severities.get("material-no-focal"), "minor")

    def test_exceeding_the_slot_budget_is_reported(self):
        many = [MaterialSlot(f"m{i}", (i * 20 % 255, 40, 200 - i * 15)) for i in range(12)]
        rules = [f["rule"] for f in validate(many)["findings"]]
        self.assertIn("material-budget", rules)

    def test_a_duplicate_slot_is_reported(self):
        rules = [f["rule"] for f in validate([DARK, LIGHT, GLOW, DARK])["findings"]]
        self.assertIn("material-duplicate", rules)

    def test_no_materials_at_all_is_blocking(self):
        report = validate([])
        self.assertFalse(report["ok"])
        self.assertEqual(report["findings"][0]["severity"], "blocking")

    def test_the_report_calls_itself_a_prediction(self):
        """Lighting, roughness and geometry all move the value the critic
        measures. A prediction presented as a measurement would be trusted past
        where it holds."""

        report = validate([DARK, LIGHT, GLOW])
        self.assertIn("not a substitute", report["prediction"])


if __name__ == "__main__":
    unittest.main()
