"""Gameplay recipes.

The document's claim is about scale: CardTycoon, MiningTycoon and
RestaurantTycoon are not three projects, they are one recipe and three
configurations. `test_four_tycoons_come_from_one_recipe` makes that checkable --
same loop, same system set, three distinct models, differing in exactly what a
designer typed.

Applying every recipe found two real errors, and neither was in the recipes'
prose. `collection` promised `upgrade` in its loop while listing `economy` as
optional, so it could not build its own loop. And the IR demanded an economy for
*any* progression with tiers -- a rule about tycoons applied to a roguelite,
whose checkpoints are reached rather than bought.
"""

from __future__ import annotations

import unittest

from rqe.ir import GENRES, PURCHASED_PROGRESSIONS, load_model
from rqe.recipes import (
    RECIPES,
    RecipeError,
    apply,
    catalogue,
    check,
    conforms,
    recipe_for,
    variants,
)


def _zones_for(recipe):
    if recipe.topology in ("hub_and_zones", "open_world"):
        return [{"id": "a", "theme": "t", "difficulty": 1},
                {"id": "b", "theme": "t", "difficulty": 2}]
    return []


class TestCatalogue(unittest.TestCase):
    def test_every_genre_the_ir_accepts_has_a_recipe(self):
        """A genre with no recipe validates as a model and has nothing to build
        it from."""

        for genre in GENRES:
            self.assertIn(genre, RECIPES, genre)

    def test_an_unknown_genre_lists_the_real_ones(self):
        with self.assertRaises(RecipeError) as caught:
            recipe_for("metroidvania")
        self.assertIn("tycoon", str(caught.exception))

    def test_every_recipe_states_what_it_requires(self):
        for recipe in RECIPES.values():
            self.assertTrue(recipe.core_verbs, recipe.genre)
            self.assertTrue(recipe.required_systems, recipe.genre)
            self.assertTrue(recipe.summary.strip(), recipe.genre)

    def test_the_catalogue_is_readable_before_choosing(self):
        report = catalogue()
        self.assertEqual(report["count"], len(RECIPES))
        self.assertEqual(len(report["recipes"]), len(RECIPES))


class TestApply(unittest.TestCase):
    def test_every_recipe_produces_a_coherent_model(self):
        """A recipe that emitted an incoherent model would have moved the work
        rather than removed it. This is the test that found `collection`
        promising an upgrade it could not pay for."""

        for genre, recipe in RECIPES.items():
            model = apply(recipe, id=f"probe-{genre.replace('_', '-')}",
                          theme=f"{genre} theme", pitch=f"A {genre}.",
                          zones=_zones_for(recipe))
            self.assertTrue(model.coherent, f"{genre}: {model.problems()}")

    def test_every_recipe_produces_a_model_that_conforms_to_it(self):
        for genre, recipe in RECIPES.items():
            model = apply(recipe, id=f"probe-{genre.replace('_', '-')}",
                          theme="t", pitch="p", zones=_zones_for(recipe))
            self.assertTrue(conforms(model), f"{genre}: {check(model)}")

    def test_a_configuration_supplies_only_what_distinguishes_the_game(self):
        """Theme and pitch are the whole of what makes CardTycoon not
        MiningTycoon. Everything else the genre implied."""

        model = apply("tycoon", id="card-tycoon", theme="anime card farm",
                      pitch="Pull cards, slot them, grow income.")
        self.assertEqual(model.theme, "anime card farm")
        self.assertEqual(list(model.core_loop), list(RECIPES["tycoon"].core_verbs))

    def test_extra_verbs_and_systems_extend_rather_than_replace(self):
        model = apply("tycoon", id="probe", theme="t", pitch="p",
                      extra_verbs=["buy"], extra_systems=["shop"])
        self.assertIn("buy", model.core_loop)
        self.assertIn("shop", model.systems)
        for verb in RECIPES["tycoon"].core_verbs:
            self.assertIn(verb, model.core_loop)

    def test_overriding_the_pacing_is_carried_through(self):
        model = apply("tycoon", id="probe", theme="t", pitch="p",
                      tiers=12, first_tier_seconds=20, session_minutes=30)
        self.assertEqual(model.progression.tiers, 12)
        self.assertEqual(model.progression.first_tier_seconds, 20)

    def test_an_incoherent_configuration_names_the_recipe(self):
        """Raised here so the failure says which recipe, rather than surfacing
        three layers down as a validation error."""

        with self.assertRaises(RecipeError) as caught:
            apply("collection", id="probe", theme="t", pitch="p", zones=[])
        self.assertIn("collection", str(caught.exception))

    def test_a_currency_is_supplied_when_the_genre_needs_one(self):
        """A genre needing an economy and handed no currency would produce an
        incoherent model."""

        model = apply("tycoon", id="probe", theme="t", pitch="p")
        self.assertTrue(model.currencies)
        self.assertTrue(model.currencies[0].earned_by)
        self.assertTrue(model.currencies[0].spent_on)


class TestVariants(unittest.TestCase):
    def test_four_tycoons_come_from_one_recipe(self):
        """The document's claim, made checkable."""

        report = variants("tycoon", [
            {"id": "card-tycoon", "theme": "anime card farm", "pitch": "Cards."},
            {"id": "mining-tycoon", "theme": "deep mine", "pitch": "Ore."},
            {"id": "restaurant-tycoon", "theme": "diner", "pitch": "Plates."},
            {"id": "space-tycoon", "theme": "orbital station", "pitch": "Modules."},
        ])
        self.assertEqual(report["count"], 4)
        self.assertTrue(report["sharedLoop"])
        self.assertTrue(report["sharedSystems"])
        self.assertTrue(report["distinct"])

    def test_variants_of_different_genres_do_not_share_a_loop(self):
        """If they did, the recipes would not be distinguishing anything."""

        tycoon = apply("tycoon", id="a", theme="t", pitch="p")
        racing = apply("racing", id="b", theme="t", pitch="p")
        self.assertNotEqual(set(tycoon.core_loop), set(racing.core_loop))


class TestCheck(unittest.TestCase):
    def test_a_tycoon_without_an_economy_is_caught(self):
        """Genre is the word every downstream decision keys off, so a game
        mislabelled at the top is measured against the wrong bar all the way
        down."""

        model = load_model({
            "id": "not-really", "genre": "tycoon", "theme": "t", "pitch": "p",
            "coreLoop": ["explore"],
            "world": {"topology": "grid_plots", "zones": []},
            "progression": {"kind": "endless", "tiers": 0},
            "systems": [],
        })
        problems = [item for item in check(model) if not item.startswith("note:")]
        self.assertTrue(problems)
        self.assertFalse(conforms(model))

    def test_an_unusual_topology_is_a_note_rather_than_a_defect(self):
        """A tycoon in a hub is unusual, not wrong. Refusing it would make the
        recipe a cage."""

        model = apply("tycoon", id="probe", theme="t", pitch="p")
        object.__setattr__(model, "topology", "hub_and_zones")
        notes = [item for item in check(model) if item.startswith("note:")]
        self.assertTrue(notes)
        self.assertTrue(conforms(model))


class TestPurchasedProgression(unittest.TestCase):
    """The IR rule that applying every recipe corrected."""

    def test_only_purchased_progressions_demand_an_economy(self):
        self.assertIn("tiered", PURCHASED_PROGRESSIONS)
        self.assertNotIn("wave", PURCHASED_PROGRESSIONS)
        self.assertNotIn("checkpoint", PURCHASED_PROGRESSIONS)

    def test_a_wave_ladder_needs_no_currency(self):
        """A wave is survived, not bought."""

        model = load_model({
            "id": "waves", "genre": "tower_defense", "theme": "t", "pitch": "p",
            "coreLoop": ["defend"],
            "world": {"topology": "single_arena", "zones": []},
            "progression": {"kind": "wave", "tiers": 12},
            "systems": ["tower", "save", "analytics"],
        })
        joined = " ".join(model.problems())
        self.assertNotIn("no economy system to fund them", joined)

    def test_a_tiered_ladder_still_demands_one(self):
        """The check that was worth keeping: a tycoon ladder nothing funds."""

        model = load_model({
            "id": "unfunded", "genre": "tycoon", "theme": "t", "pitch": "p",
            "coreLoop": ["unlock"],
            "world": {"topology": "grid_plots", "zones": []},
            "progression": {"kind": "tiered", "tiers": 8},
            "systems": ["progression", "save"],
        })
        self.assertTrue(any("nothing would climb it" in p for p in model.problems()))


if __name__ == "__main__":
    unittest.main()
