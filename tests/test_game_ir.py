"""The Game IR.

The layer's whole claim is that a game can be stated once and everything else
derived. Two properties carry it, and both are tested here rather than asserted
in a document.

**Incoherence is caught from the model alone.** A game can parse, compile, build
and not work -- a loop verb with no system behind it, a currency nothing earns,
a zone gated above the last tier. Every one of those is decidable in
milliseconds and every one otherwise surfaces as a play session that goes wrong
in a way nobody can attribute.

**The blueprint is derived, not authored.** Before this layer, `product-intent`
and the blueprint project were written side by side and nothing checked they
agreed. Here there is one description, so there is nothing to disagree with.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.ir import (
    GENRES,
    LOOP_VERB_SYSTEMS,
    SYSTEM_REQUIREMENTS,
    GameModel,
    GameModelError,
    load_model,
    required_systems,
)
from rqe.ir.compiler import compile_model, to_blueprint_project, to_product_intent

REPO = Path(__file__).resolve().parents[1]


FARM = {
    "id": "anime-card-farm", "genre": "tycoon", "theme": "anime collector farm",
    "pitch": "Pull cards from a belt, slot them into a plot, grow income.",
    "coreLoop": ["collect", "process", "upgrade", "sell", "unlock"],
    "world": {"topology": "grid_plots", "zones": []},
    "progression": {"kind": "tiered", "tiers": 8, "firstTierSeconds": 45, "sessionMinutes": 15},
    "economy": {"currencies": [
        {"id": "cash", "displayName": "Cash", "earnedBy": ["sell"], "spentOn": ["upgrade"]},
    ]},
    "systems": ["economy", "progression", "save", "inventory", "shop", "analytics"],
    "tokenSet": "tokens/brickfarm.json", "privateSpace": True, "concurrentPlayers": 8,
}

SIEGE = {
    "id": "lantern-siege", "genre": "tower_defense", "theme": "lantern-lit siege",
    "pitch": "Hold the gate through waves of lantern-wraiths.",
    "coreLoop": ["build", "defend", "upgrade", "unlock"],
    "world": {"topology": "single_arena", "zones": []},
    "progression": {"kind": "wave", "tiers": 12, "sessionMinutes": 12},
    "economy": {"currencies": [
        {"id": "embers", "displayName": "Embers", "earnedBy": ["defend"],
         "spentOn": ["build", "upgrade"]},
    ]},
    "systems": ["economy", "progression", "save", "tower", "analytics"],
    "tokenSet": "tokens/brickfarm.json", "concurrentPlayers": 4,
}


def _without(document: dict, **overrides) -> dict:
    merged = {**document, **overrides}
    return merged


class TestStructure(unittest.TestCase):
    """Malformed stops everything, immediately, with the real list."""

    def test_an_unknown_genre_is_refused_with_the_real_list(self):
        with self.assertRaises(GameModelError) as caught:
            load_model(_without(FARM, genre="metroidvania"))
        self.assertIn("tycoon", str(caught.exception))

    def test_an_unknown_loop_verb_is_refused(self):
        """A verb the engine cannot build is a promise it cannot keep."""

        with self.assertRaises(GameModelError) as caught:
            load_model(_without(FARM, coreLoop=["collect", "vibe"]))
        self.assertIn("vibe", str(caught.exception))

    def test_an_unknown_system_is_refused(self):
        with self.assertRaises(GameModelError):
            load_model(_without(FARM, systems=["economy", "telepathy"]))

    def test_a_game_with_no_core_loop_is_refused(self):
        with self.assertRaises(GameModelError):
            load_model(_without(FARM, coreLoop=[]))

    def test_a_game_needs_a_pitch(self):
        with self.assertRaises(GameModelError):
            load_model(_without(FARM, pitch="  "))

    def test_a_duplicate_currency_is_refused(self):
        with self.assertRaises(GameModelError):
            load_model(_without(FARM, economy={"currencies": [
                {"id": "cash", "earnedBy": ["sell"], "spentOn": ["upgrade"]},
                {"id": "cash", "earnedBy": ["sell"], "spentOn": ["upgrade"]},
            ]}))


class TestCoherence(unittest.TestCase):
    """Parses, compiles, builds -- and does not work."""

    def test_the_shipped_games_are_coherent(self):
        for document in (FARM, SIEGE):
            model = load_model(document)
            self.assertTrue(model.coherent, model.problems())

    def test_a_loop_verb_with_no_system_behind_it_is_reported(self):
        model = load_model(_without(FARM, systems=["economy", "progression", "save"]))
        joined = " ".join(model.problems())
        self.assertIn("collect", joined)
        self.assertIn("inventory", joined)

    def test_a_currency_that_is_never_earned_is_reported(self):
        """A price nobody can pay is a locked door with no key."""

        model = load_model(_without(FARM, economy={"currencies": [
            {"id": "cash", "spentOn": ["upgrade"]},
        ]}))
        self.assertTrue(any("never earned" in p for p in model.problems()))

    def test_a_currency_that_is_never_spent_is_reported(self):
        model = load_model(_without(FARM, economy={"currencies": [
            {"id": "cash", "earnedBy": ["sell"]},
        ]}))
        self.assertTrue(any("never spent" in p for p in model.problems()))

    def test_a_zone_gated_above_the_last_tier_is_reported(self):
        """It would never open, and nothing in a first session would show it."""

        model = load_model(_without(
            FARM,
            world={"topology": "hub_and_zones", "zones": [
                {"id": "abyss", "theme": "abyss", "unlockedAtTier": 99},
            ]},
        ))
        self.assertTrue(any("never open" in p for p in model.problems()))

    def test_progression_without_save_is_reported(self):
        """Every player restarts from zero, and a first session cannot see it."""

        model = load_model(_without(
            FARM, systems=["economy", "progression", "inventory", "shop", "analytics"]))
        self.assertTrue(any("restart from zero" in p for p in model.problems()))

    def test_zones_under_a_topology_with_nowhere_to_put_them(self):
        model = load_model(_without(
            FARM, world={"topology": "grid_plots", "zones": [{"id": "reef", "theme": "reef"}]}))
        self.assertTrue(any("no place to put them" in p for p in model.problems()))

    def test_hub_and_zones_with_no_zones_is_reported(self):
        model = load_model(_without(FARM, world={"topology": "hub_and_zones", "zones": []}))
        self.assertTrue(any("needs zones" in p for p in model.problems()))

    def test_currency_packs_without_a_premium_currency_is_reported(self):
        model = load_model(_without(FARM, monetization=["currency_packs"]))
        self.assertTrue(any("premium" in p for p in model.problems()))

    def test_all_problems_are_reported_at_once(self):
        """One exception at a time is how a model takes six passes to become
        playable."""

        model = load_model(_without(
            FARM,
            systems=["economy"],
            economy={"currencies": [{"id": "cash"}]},
        ))
        self.assertGreater(len(model.problems()), 3)


class TestRequiredSystems(unittest.TestCase):
    def test_the_loop_implies_systems_the_model_did_not_list(self):
        model = load_model(_without(FARM, systems=["economy", "progression", "save", "analytics"]))
        self.assertIn("inventory", required_systems(model))

    def test_dependencies_are_followed_transitively(self):
        """crafting needs inventory; asking for crafting must surface it."""

        model = load_model(_without(
            FARM,
            coreLoop=["craft", "sell"],
            systems=["economy", "progression", "save", "crafting"],
        ))
        self.assertIn("inventory", required_systems(model))

    def test_every_loop_verb_maps_to_declared_systems(self):
        """A verb pointing at a system that does not exist would make the
        coherence check demand something unbuildable."""

        for verb, systems in LOOP_VERB_SYSTEMS.items():
            for system in systems:
                self.assertIn(system, SYSTEM_REQUIREMENTS, f"{verb} -> {system}")


class TestCompilation(unittest.TestCase):
    def test_an_incoherent_model_is_not_compiled(self):
        """A task graph built from a model that already says it will not work
        spends every hour of execution on a known defect."""

        model = load_model(_without(FARM, systems=["economy"]))
        with self.assertRaises(GameModelError) as caught:
            to_blueprint_project(model, root=REPO)
        self.assertIn("not coherent", str(caught.exception))

    def test_the_product_intent_is_derived_from_the_model(self):
        intent = to_product_intent(load_model(FARM))
        self.assertEqual(intent["productId"], "anime-card-farm")
        self.assertEqual(intent["coreLoop"], FARM["coreLoop"])

    def test_a_model_compiles_through_the_real_production_compiler(self):
        """Not a parallel planner. A second answer to "what would build this
        game" is a second answer that drifts."""

        out = compile_model(load_model(FARM), root=REPO)
        projects = out["plan"]["projects"]
        self.assertEqual(len(projects), 1)
        self.assertTrue(projects[0]["tasks"])

    def test_two_radically_different_games_travel_the_same_stages(self):
        """The generality claim, made from models rather than hand-written
        blueprints: a tycoon and a tower defense state entirely different
        systems and must still go through one pipeline."""

        stage_sets = []
        for document in (FARM, SIEGE):
            out = compile_model(load_model(document), root=REPO)
            tasks = out["plan"]["projects"][0]["tasks"]
            stage_sets.append(tuple(sorted({task["stage"] for task in tasks})))
        self.assertEqual(stage_sets[0], stage_sets[1])
        self.assertGreater(len(stage_sets[0]), 5)

    def test_the_two_games_do_not_compile_to_the_same_plan(self):
        """Identical stages, different content. If the plans matched, the
        pipeline would be ignoring the model."""

        farm = compile_model(load_model(FARM), root=REPO)
        siege = compile_model(load_model(SIEGE), root=REPO)
        self.assertNotEqual(farm["plan"]["planId"], siege["plan"]["planId"])
        self.assertNotEqual(farm["systems"], siege["systems"])

    def test_the_model_hash_changes_with_the_game(self):
        first = load_model(FARM)
        second = load_model(_without(FARM, pitch="A different game entirely."))
        self.assertNotEqual(first.sha256, second.sha256)
        self.assertEqual(first.sha256, load_model(FARM).sha256)

    def test_every_genre_has_a_template_id(self):
        """A genre with no template compiles to a plan nothing can execute.

        Scaffolded into a temporary root first: a blueprint references its
        definition files by content hash, so compiling one for a project that
        does not exist is a plan that cannot detect those files changing."""

        import shutil
        from tempfile import TemporaryDirectory

        from rqe.ir.scaffold import scaffold_project

        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "schemas").mkdir()
            for schema in (REPO / "schemas").glob("*.json"):
                shutil.copyfile(schema, root / "schemas" / schema.name)
            (root / "quality").mkdir()
            shutil.copyfile(
                REPO / "quality" / "probe-registry.v1.json",
                root / "quality" / "probe-registry.v1.json",
            )

            for genre in GENRES:
                model = load_model(_without(
                    FARM, genre=genre, id=f"probe-{genre.replace('_', '-')}"))
                scaffold_project(model, root=root)
                project = to_blueprint_project(model, root=root)
                self.assertTrue(project["templateId"].startswith("template-"), genre)

    def test_interface_always_exists_as_a_subsystem(self):
        """Every shipped experience has an icon and a thumbnail, and an asset
        need whose consumer does not exist fails semantic validation."""

        project = to_blueprint_project(load_model(SIEGE), root=REPO)
        ids = {subsystem["id"] for subsystem in project["subsystems"]}
        self.assertIn("interface", ids)
        self.assertIn("world", ids)

    def test_every_asset_need_names_a_declared_consumer(self):
        for document in (FARM, SIEGE):
            project = to_blueprint_project(load_model(document), root=REPO)
            declared = {subsystem["id"] for subsystem in project["subsystems"]}
            for need in project["assetNeeds"]:
                for consumer in need["consumers"]:
                    self.assertIn(consumer, declared, need["id"])

    def test_the_core_loop_produces_scenarios(self):
        """A scenario nobody derived is a behaviour nobody measures, and the
        loop is the list of behaviours the game promised."""

        project = to_blueprint_project(load_model(FARM), root=REPO)
        ids = {scenario["id"] for scenario in project["scenarioClasses"]}
        self.assertIn("first-session", ids)
        self.assertIn("progression", ids)


if __name__ == "__main__":
    unittest.main()
