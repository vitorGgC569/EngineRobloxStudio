"""The art director.

The Blender worker solved how to produce geometry; `choose_backend` solved which
tool to produce one asset with. Neither decides what a world needs, and that is
where a budget is won or lost.

The failure this prevents does not announce itself: a world authored
asset-by-asset accumulates forty unique meshes, every one approved individually
by a validator that was only ever shown one at a time. Nothing rejects it, the
phone build stutters, and the cause is spread across forty defensible decisions.

Two of these tests exist because the first version got the decision wrong. It
planned zone landmarks twice -- once as a shared kit and once per zone -- and it
charged triangles to an experience icon, which is an image.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.assets.director import (
    INSTANCE_FLOOR,
    MIN_TRIANGLES,
    UNIQUE_ROLES,
    VISUAL_WEIGHT,
    AssetPlan,
    Budget,
    DirectorError,
    plan,
    plan_for_model,
)
from rqe.geometry.brief import TRIANGLE_LIMIT
from rqe.ir import load_model
from rqe.world.grammar import build_world

REPO = Path(__file__).resolve().parents[1]
TOKENS = json.loads((REPO / "tokens" / "brickfarm.json").read_text(encoding="utf-8"))

MODEL = {
    "id": "director-probe", "genre": "tycoon", "theme": "underwater lab", "pitch": "x",
    "coreLoop": ["explore", "collect", "process", "upgrade", "unlock"],
    "world": {"topology": "hub_and_zones", "zones": [
        {"id": "reef", "theme": "coral reef", "difficulty": 1},
        {"id": "volcanic", "theme": "volcanic", "difficulty": 4},
    ]},
    "progression": {"kind": "tiered", "tiers": 8, "firstTierSeconds": 45,
                    "sessionMinutes": 15},
    "economy": {"currencies": [
        {"id": "credits", "earnedBy": ["process"], "spentOn": ["upgrade"]}]},
    "systems": ["economy", "progression", "save", "inventory", "analytics"],
}


def _world():
    model = load_model(MODEL)
    return model, build_world("probe-world", tokens=TOKENS, zones=[
        {"id": z.id, "theme": z.theme, "difficulty": z.difficulty} for z in model.zones
    ])


class TestBudget(unittest.TestCase):
    def test_a_budget_too_small_for_two_assets_is_refused(self):
        with self.assertRaises(DirectorError):
            Budget(triangles=100)

    def test_a_hero_share_above_one_is_refused(self):
        with self.assertRaises(DirectorError):
            Budget(hero_share_ceiling=1.5)


class TestReuse(unittest.TestCase):
    def test_shared_roles_become_one_kit_per_kind(self):
        """Twenty corridors want one corridor used twenty times. A brief per
        region would produce twenty corridors nobody can tell apart at twenty
        times the cost."""

        _, world = _world()
        result = plan("w", world_spec=world, budget=Budget(triangles=200_000))
        corridors = [e for e in result.entries if e.id == "kit-corridor"]
        self.assertEqual(len(corridors), 1)
        self.assertGreater(corridors[0].instances, 1)

    def test_landmarks_are_unique_per_region(self):
        """Two zones sharing a landmark are one zone as far as a player
        navigating can tell."""

        _, world = _world()
        result = plan("w", world_spec=world, budget=Budget(triangles=200_000))
        heroes = [e for e in result.entries if e.role == "hero"]
        self.assertGreaterEqual(len(heroes), 3)
        for hero in heroes:
            self.assertEqual(hero.instances, 1)

    def test_a_landmark_is_not_planned_twice(self):
        """The first version added a per-zone landmark on top of the world's own
        landmark regions, and planned five assets for three landmarks."""

        model, world = _world()
        result = plan_for_model(model, world_spec=world, budget=Budget(triangles=200_000))
        ids = [entry.id for entry in result.entries]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertNotIn("landmark-reef", ids)

    def test_the_reuse_ratio_is_reported(self):
        _, world = _world()
        result = plan("w", world_spec=world, budget=Budget(triangles=200_000))
        self.assertGreater(result.reuse_ratio, 1.0)

    def test_media_needs_do_not_consume_the_geometry_distinct_budget(self):
        result = plan("w", budget=Budget(triangles=1_000, max_distinct=1), extra=[
            ("crate", "prop", 5),
            ("feedback-ui-confirm", "feedback", 1),
            ("feedback-ui-denied", "feedback", 1),
        ])

        self.assertEqual(result.distinct, 3)
        self.assertEqual(result.geometry_distinct, 1)
        self.assertEqual(result.media_distinct, 2)
        self.assertFalse(any("collection" in issue for issue in result.problems()))


class TestAllocation(unittest.TestCase):
    def test_budget_follows_the_eye_not_the_count(self):
        """Allocating evenly is how a hero ends up with the same triangle count
        as a crate."""

        # A budget where allocation binds. With budget to spare both assets
        # clamp to Roblox's per-mesh ceiling and the weighting is invisible,
        # which is correct behaviour and a bad test.
        result = plan("w", budget=Budget(triangles=30_000), extra=[
            ("landmark", "hero", 1),
            ("crate", "prop", 40),
        ])
        by_id = {entry.id: entry for entry in result.entries}
        self.assertGreater(by_id["landmark"].triangles, by_id["crate"].triangles)

    def test_no_asset_exceeds_the_roblox_ceiling(self):
        result = plan("w", budget=Budget(triangles=5_000_000), extra=[
            ("landmark", "hero", 1), ("crate", "prop", 2),
        ])
        for entry in result.entries:
            self.assertLessEqual(entry.triangles, TRIANGLE_LIMIT, entry.id)

    def test_no_geometry_asset_is_allocated_less_than_a_silhouette(self):
        result = plan("w", budget=Budget(triangles=400), extra=[
            ("landmark", "hero", 1), ("crate", "prop", 50), ("post", "prop", 50),
        ])
        for entry in result.entries:
            if entry.role != "interface":
                self.assertGreaterEqual(entry.triangles, MIN_TRIANGLES, entry.id)

    def test_interface_assets_draw_no_triangles(self):
        """An icon is an image. Giving it a share of a mesh budget takes it from
        the geometry that needs it."""

        model = load_model(MODEL)
        result = plan_for_model(model, budget=Budget(triangles=100_000))
        for entry in result.entries:
            if entry.role == "interface":
                self.assertEqual(entry.triangles, 0, entry.id)

    def test_interface_assets_route_to_the_image_pipeline(self):
        """Falling through to Blender would route an icon to a modeller."""

        model = load_model(MODEL)
        result = plan_for_model(model, budget=Budget(triangles=100_000))
        for entry in result.entries:
            if entry.role == "interface":
                self.assertEqual(entry.backend, "image", entry.id)

    def test_every_role_routes_to_a_backend(self):
        for role in VISUAL_WEIGHT:
            result = plan("w", budget=Budget(triangles=50_000),
                          extra=[("probe", role, 3)])
            self.assertTrue(result.entries[0].backend, role)


class TestProblems(unittest.TestCase):
    def test_a_plan_over_budget_is_reported(self):
        """Every asset would pass its own validator and the scene would still
        not run."""

        result = plan("w", budget=Budget(triangles=1_000), extra=[
            (f"a{i}", "hero", 1) for i in range(20)
        ])
        self.assertFalse(result.ok)
        self.assertTrue(any("budget" in p for p in result.problems()))

    def test_too_many_distinct_assets_is_reported(self):
        """Past a couple of dozen a scene stops being a kit and becomes a
        collection."""

        result = plan("w", budget=Budget(triangles=2_000_000, max_distinct=5),
                      extra=[(f"a{i}", "prop", 5) for i in range(12)])
        self.assertTrue(any("collection" in p for p in result.problems()))

    def test_modelling_for_one_placement_is_reported(self):
        result = plan("w", budget=Budget(triangles=200_000), extra=[
            (f"a{i}", "prop", 1) for i in range(6)
        ])
        self.assertTrue(result.ok)
        self.assertEqual(result.blocking_problems(), [])
        self.assertTrue(any("single" in p or "fewer than" in p
                            for p in result.problems()))
        self.assertTrue(any("fewer than" in p for p in result.warnings()))

    def test_heroes_eating_the_budget_is_reported(self):
        result = plan("w", budget=Budget(triangles=100_000, hero_share_ceiling=0.2),
                      extra=[("landmark", "hero", 1), ("crate", "prop", 20)])
        self.assertTrue(any("eat the world" in p for p in result.problems()))

    def test_an_interface_asset_is_not_accused_of_poor_reuse(self):
        """An experience has exactly one icon; reporting that as 'modelled for a
        single placement' is a complaint about the platform."""

        model = load_model(MODEL)
        _, world = _world()
        result = plan_for_model(model, world_spec=world,
                                budget=Budget(triangles=250_000))
        self.assertTrue(result.ok, result.problems())

    def test_all_problems_are_reported_at_once(self):
        result = plan("w", budget=Budget(triangles=1_000, max_distinct=2),
                      extra=[(f"a{i}", "hero", 1) for i in range(8)])
        self.assertGreater(len(result.problems()), 1)


class TestDiscovery(unittest.TestCase):
    def test_an_existing_asset_is_discovered_rather_than_created(self):
        """Reusing costs nothing and keeps the visual language consistent."""

        result = plan("w", budget=Budget(triangles=100_000),
                      extra=[("crate", "prop", 10), ("barrel", "prop", 10)],
                      existing=["crate"])
        by_id = {entry.id: entry for entry in result.entries}
        self.assertEqual(by_id["crate"].strategy, "DISCOVER")
        self.assertEqual(by_id["barrel"].strategy, "CREATE")

    def test_a_game_plans_feedback_audio_as_a_first_class_asset_need(self):
        model = load_model(MODEL)
        result = plan_for_model(model, budget=Budget(triangles=100_000))
        by_id = {entry.id: entry for entry in result.entries}

        for cue in (
            "feedback-ui-confirm",
            "feedback-ui-denied",
            "feedback-purchase-success",
            "feedback-reward",
        ):
            self.assertIn(cue, by_id)
            self.assertEqual(by_id[cue].kind, "audio")
            self.assertEqual(by_id[cue].triangles, 0)
            self.assertEqual(by_id[cue].backend, "audio-authoring")

    def test_a_real_source_offer_routes_feedback_to_cc0_reuse(self):
        model = load_model(MODEL)
        offers = {
            "feedback-ui-confirm": ["kenney-audio"],
            "feedback-ui-denied": ["kenney-audio"],
            "feedback-purchase-success": ["kenney-audio"],
            "feedback-reward": ["kenney-audio"],
        }
        result = plan_for_model(
            model,
            budget=Budget(triangles=100_000),
            source_offers=offers,
        )
        feedback = [entry for entry in result.entries if entry.role == "feedback"]

        self.assertEqual(len(feedback), 4)
        for entry in feedback:
            self.assertEqual(entry.strategy, "DISCOVER")
            self.assertEqual(entry.backend, "sourced:kenney-audio")
            self.assertEqual(entry.source, "kenney-audio")
            self.assertEqual(entry.licence, "CC0")
            self.assertFalse(entry.attribution_required)


class TestRefusals(unittest.TestCase):
    def test_planning_nothing_is_refused(self):
        with self.assertRaises(DirectorError):
            plan("w", budget=Budget())

    def test_an_unknown_role_lists_the_real_ones(self):
        with self.assertRaises(DirectorError) as caught:
            plan("w", extra=[("x", "spaceship", 1)])
        self.assertIn("hero", str(caught.exception))

    def test_the_unique_roles_are_declared_rather_than_inferred(self):
        """The document's 'which need to be unique?' answered once, instead of
        the same judgement spread across forty briefs."""

        for role in UNIQUE_ROLES:
            self.assertIn(role, VISUAL_WEIGHT, role)


if __name__ == "__main__":
    unittest.main()
