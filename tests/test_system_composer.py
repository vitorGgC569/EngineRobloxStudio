"""The system composer, and the inventory it needed.

The composer's claim is that a game's systems are assembled from the SDK rather
than written per game. What makes that checkable is `verify`: every implemented
system is required and called through the headless harness, so "composed" means
"loaded", not "named".

That check found something on its first run, and it was not about the composer.
`Save` acquires `DataStoreService` at module scope, so it cannot load outside a
live game -- not in the harness, not in an Open Cloud task. Verifying all
systems in one script made four working modules look unverified, so verification
is per system and a non-portable module is a finding rather than a failure.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.ir import load_model
from rqe.luau_check import ToolchainUnavailable, ensure_compiler
from rqe.luau_harness import run
from rqe.systems import SYSTEMS, CompositionError, catalogue, compose, verify

REPO = Path(__file__).resolve().parents[1]

FARM = {
    "id": "composer-probe", "genre": "tycoon", "theme": "farm", "pitch": "x",
    "coreLoop": ["collect", "process", "upgrade", "sell", "unlock"],
    "world": {"topology": "grid_plots", "zones": []},
    "progression": {"kind": "tiered", "tiers": 8, "firstTierSeconds": 45,
                    "sessionMinutes": 15},
    "economy": {"currencies": [
        {"id": "cash", "displayName": "Cash", "earnedBy": ["sell"], "spentOn": ["upgrade"]},
    ]},
    "systems": ["economy", "progression", "save", "inventory", "shop", "analytics"],
}


class TestCatalogue(unittest.TestCase):
    def test_a_planned_system_says_why(self):
        """A gap recorded as a shrug is indistinguishable from an oversight, and
        a model asking for `gacha` must find out here rather than at the first
        require."""

        for spec in SYSTEMS.values():
            if not spec.implemented:
                self.assertTrue(spec.planned_reason.strip(), spec.id)

    def test_an_implemented_system_names_its_module(self):
        for spec in SYSTEMS.values():
            if spec.implemented:
                self.assertTrue(spec.module.strip(), spec.id)

    def test_the_catalogue_counts_rather_than_claims(self):
        report = catalogue()
        self.assertEqual(report["total"], len(SYSTEMS))
        self.assertEqual(
            report["implemented"],
            sum(1 for spec in SYSTEMS.values() if spec.implemented),
        )

    def test_every_ir_system_is_known_to_the_composer(self):
        """A system the IR accepts and the composer has never heard of would
        pass validation and fail composition."""

        from rqe.ir import SYSTEM_REQUIREMENTS

        for name in SYSTEM_REQUIREMENTS:
            self.assertIn(name, SYSTEMS, name)


class TestComposition(unittest.TestCase):
    def test_startup_order_respects_dependencies(self):
        composition = compose(load_model(FARM))
        for name in composition.order:
            position = composition.order.index(name)
            for dependency in SYSTEMS[name].after:
                if dependency in composition.order:
                    self.assertLess(composition.order.index(dependency), position,
                                    f"{dependency} must start before {name}")

    def test_runtime_dependencies_are_pulled_in(self):
        """`progression` needs `economy` running even in a game whose loop never
        mentions currency. That is a runtime fact, not a design one, which is
        why the IR does not carry it."""

        model = load_model({**FARM, "systems": ["progression", "save", "analytics",
                                                "economy", "inventory"]})
        self.assertIn("economy", compose(model).order)

    def test_a_partial_composition_is_not_called_complete(self):
        """A game asking for a system nothing implements is not complete, and
        calling it complete would hide the part nobody wrote.

        Written against whichever system is still PLANNED rather than against a
        named one. The first version pinned `shop`, and it failed the day `shop`
        was authored -- a test that breaks when the codebase improves is testing
        the state of the catalogue, not the rule."""

        from rqe.systems.composer import SYSTEMS

        planned = sorted(name for name, spec in SYSTEMS.items() if not spec.implemented)
        self.assertTrue(planned, "nothing is PLANNED, so this rule cannot be exercised")

        composition = compose(load_model({**FARM, "systems": ["economy", planned[0]]}))
        self.assertFalse(composition.complete)
        self.assertIn(planned[0], composition.planned)

    def test_a_fully_implemented_composition_is_complete(self):
        """The other half of the same rule: a game whose systems all exist must
        not be held back by a denominator that never empties."""

        composition = compose(load_model({**FARM, "systems": ["economy", "save", "shop"]}))
        self.assertTrue(composition.complete, composition.planned)

    def test_currencies_reach_the_economy_config(self):
        composition = compose(load_model(FARM))
        ids = [c["id"] for c in composition.config["economy"]["currencies"]]
        self.assertEqual(ids, ["cash"])

    def test_the_composer_refuses_to_price_tiers(self):
        """Inventing costs here would produce a second pacing curve nobody
        verified, beside the one the economy designer solves and checks."""

        composition = compose(load_model(FARM))
        self.assertIn("economy_from_model", composition.config["progression"]["costs"])

    def test_inventory_capacity_follows_the_world(self):
        zoned = load_model({
            **FARM,
            "world": {"topology": "hub_and_zones", "zones": [
                {"id": "a", "theme": "t"}, {"id": "b", "theme": "t"},
                {"id": "c", "theme": "t"},
            ]},
        })
        flat = compose(load_model(FARM)).config["inventory"]["slots"]
        many = compose(zoned).config["inventory"]["slots"]
        self.assertGreater(many, flat)

    def test_a_dependency_cycle_is_refused_rather_than_ordered(self):
        """Any order the composer invented would work until the day it did
        not."""

        from rqe.systems import composer

        original = SYSTEMS["analytics"]
        SYSTEMS["analytics"] = composer.SystemSpec(
            "analytics", "Analytics", after=("economy",))
        try:
            with self.assertRaises(CompositionError) as caught:
                compose(load_model(FARM))
            self.assertIn("cycle", str(caught.exception))
        finally:
            SYSTEMS["analytics"] = original


class TestVerificationAgainstTheHarness(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(REPO)
        except ToolchainUnavailable as exc:
            raise unittest.SkipTest(f"no Luau toolchain: {exc}") from exc

    def test_every_implemented_system_loads_and_runs(self):
        """"Composed" has to mean "ran". A composer that only emitted names
        would report a complete game whose first require fails."""

        composition = verify(REPO, compose(load_model(FARM)))
        self.assertGreaterEqual(composition.verified["loaded"], 4)

    def test_a_non_portable_module_is_a_finding_not_a_failure(self):
        """`Save` only runs inside a live game. The composition is still usable;
        what a caller needs is to know that one system cannot be simulated."""

        composition = verify(REPO, compose(load_model(FARM)))
        findings = {f["system"]: f for f in composition.verified["findings"]}
        self.assertIn("save", findings)
        self.assertEqual(findings["save"]["status"], "NOT_PORTABLE")
        self.assertIn("DataStoreService", findings["save"]["detail"])

    def test_the_verification_names_its_source(self):
        composition = verify(REPO, compose(load_model(FARM)))
        self.assertIn("GameKit", composition.verified["source"])


class TestInventoryModule(unittest.TestCase):
    """The system the composer needed and the SDK did not have."""

    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(REPO)
        except ToolchainUnavailable as exc:
            raise unittest.SkipTest(f"no Luau toolchain: {exc}") from exc

    def values(self, body: str) -> dict:
        result = run(REPO, libraries=["roblox/lib/GameKit"], body=body)
        self.assertTrue(result.ok, result.stderr)
        decoded = result.json_lines()
        self.assertTrue(decoded, result.stdout)
        return decoded[-1]

    def test_a_full_bag_refuses_loudly(self):
        """Adding what fits and returning nothing is how a player picks up ten
        ore, receives four, and concludes the other six never spawned."""

        report = self.values("""
        local Inventory = Require("Inventory")
        local inv = Inventory.define({{id="ore", displayName="Ore", stackSize=20}},
            Inventory.memoryStore(), 3)
        local p = Harness.makePlayer(1, "T")
        local first = inv:add(p, "ore", 50)
        local second = inv:add(p, "ore", 30)
        print(string.format('{"first":%d,"second":%d}', first, second))
        """)
        self.assertEqual(report["first"], 50)
        self.assertEqual(report["second"], 10)

    def test_removing_more_than_held_removes_nothing(self):
        """A partial removal leaves a quest half-charged and the player
        half-robbed, and neither side can tell which happened."""

        report = self.values("""
        local Inventory = Require("Inventory")
        local inv = Inventory.define({{id="ore", displayName="Ore", stackSize=20}},
            Inventory.memoryStore(), 3)
        local p = Harness.makePlayer(1, "T")
        inv:add(p, "ore", 10)
        local ok = inv:remove(p, "ore", 999)
        print(string.format('{"ok":%s,"held":%d}', tostring(ok), inv:count(p, "ore")))
        """)
        self.assertFalse(report["ok"])
        self.assertEqual(report["held"], 10)

    def test_an_empty_bag_and_a_bag_with_no_room_are_distinguishable(self):
        report = self.values("""
        local Inventory = Require("Inventory")
        local inv = Inventory.define({{id="ore", displayName="Ore", stackSize=1}},
            Inventory.memoryStore(), 2)
        local p = Harness.makePlayer(1, "T")
        local emptyFree = inv:freeSlots(p)
        inv:add(p, "ore", 2)
        print(string.format('{"emptyFree":%d,"fullFree":%d,"room":%d}',
            emptyFree, inv:freeSlots(p), inv:room(p, "ore")))
        """)
        self.assertEqual(report["emptyFree"], 2)
        self.assertEqual(report["fullFree"], 0)
        self.assertEqual(report["room"], 0)

    def test_stacks_are_copied_on_read(self):
        """Handing out the stored table lets a caller mutate the inventory
        without going through add or remove, which is the path every guarantee
        depends on."""

        report = self.values("""
        local Inventory = Require("Inventory")
        local inv = Inventory.define({{id="ore", displayName="Ore", stackSize=20}},
            Inventory.memoryStore(), 3)
        local p = Harness.makePlayer(1, "T")
        inv:add(p, "ore", 5)
        local held = inv:stacks(p)
        held[1].count = 9999
        print(string.format('{"count":%d}', inv:count(p, "ore")))
        """)
        self.assertEqual(report["count"], 5)

    def test_a_shape_that_frustrates_is_reported_before_anyone_plays(self):
        report = self.values("""
        local Inventory = Require("Inventory")
        local inv = Inventory.define({{id="ore", displayName="Ore"}},
            Inventory.memoryStore(), 2)
        print(string.format('{"problems":%d}', #Inventory.problems(inv)))
        """)
        self.assertGreater(report["problems"], 0)

    def test_an_unknown_item_lists_the_real_ones(self):
        result = run(REPO, libraries=["roblox/lib/GameKit"], body="""
        local Inventory = Require("Inventory")
        local inv = Inventory.define({{id="ore", displayName="Ore"}},
            Inventory.memoryStore(), 6)
        inv:count(Harness.makePlayer(1, "T"), "gold")
        """)
        self.assertFalse(result.ok)
        self.assertIn("ore", result.stderr)


if __name__ == "__main__":
    unittest.main()
