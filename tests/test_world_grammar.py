"""The world grammar.

`world_plan` validates a layout, but only one somebody wrote. It will approve a
zone that is a single square room with a spawn in it, because nothing in the
planner knows that a zone without an entrance, something to do and something to
aim at is not a zone. The structure lives in the grammar.

The test that matters is `test_an_expanded_world_passes_the_real_planner`:
everything the grammar builds goes through the same validator a hand-written
world does, including its reachability walk. A grammar whose output only it
understood would be a third world format.

Two of these exist because the real validator rejected the first version. It
used `corridorWidth` as a region's short side, and narrowed secondary and secret
routes below it to signal "lesser" -- both invent dimensions under the token
grammar's floors, which is exactly what this module's own docstring says not to
do.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.world import plan
from rqe.world.authoring import WorldSpec
from rqe.world.grammar import (
    HUB_PARTS,
    MAX_DIFFICULTY,
    ZONE_PARTS,
    Grammar,
    GrammarError,
    build_world,
    describe,
    expand_zone,
)
from rqe.luau_check import ToolchainUnavailable, ensure_compiler

REPO = Path(__file__).resolve().parents[1]
TOKENS = json.loads((REPO / "tokens" / "brickfarm.json").read_text(encoding="utf-8"))
GRAMMAR = Grammar.from_tokens(TOKENS)


class TestDimensionsComeFromTokens(unittest.TestCase):
    def test_a_token_set_without_a_scale_grammar_is_refused(self):
        """A world built to invented dimensions validates and then feels wrong
        beside the rest of the game, which is the hardest wrong to attribute."""

        with self.assertRaises(GrammarError) as caught:
            Grammar.from_tokens({"scale": {"grammar": {"corridorWidth": 12}}})
        self.assertIn("roomMinDimension", str(caught.exception))

    def test_the_dimensions_are_the_token_set_s_own(self):
        scale = TOKENS["scale"]["grammar"]
        self.assertEqual(GRAMMAR.corridor_width, scale["corridorWidth"])
        self.assertEqual(GRAMMAR.room_min, scale["roomMinDimension"])
        self.assertEqual(GRAMMAR.landmark_min_height, scale["landmarkMinHeight"])

    def test_no_region_is_narrower_than_a_usable_space(self):
        """The first thing the real validator rejected: a path built to
        corridorWidth is a strip a player squeezes through."""

        regions, _, _ = expand_zone("z", theme="t", difficulty=3, grammar=GRAMMAR)
        for region in regions:
            self.assertGreaterEqual(min(region.size), GRAMMAR.room_min, region.id)

    def test_no_route_is_narrower_than_a_corridor(self):
        """Narrowing a secondary path to signal 'lesser' makes it
        untraversable; corridorWidth is a floor, not a suggestion."""

        _, routes, _ = expand_zone("z", theme="t", difficulty=5, grammar=GRAMMAR)
        for route in routes:
            self.assertGreaterEqual(route.width or 0, GRAMMAR.corridor_width)


class TestZoneStructure(unittest.TestCase):
    def test_a_zone_always_has_its_parts(self):
        """Difficulty scales the counts; it does not remove the structure. A
        zone missing its entrance is unfinished, not easier."""

        for difficulty in range(1, MAX_DIFFICULTY + 1):
            regions, _, landmarks = expand_zone(
                "z", theme="t", difficulty=difficulty, grammar=GRAMMAR)
            ids = {region.id for region in regions}
            self.assertIn("z-entrance", ids, difficulty)
            self.assertIn("z-path", ids, difficulty)
            self.assertIn("z-landmark", ids, difficulty)
            self.assertIn("z-exit", ids, difficulty)
            self.assertTrue(landmarks, difficulty)

    def test_difficulty_adds_things_to_do(self):
        easy, _, _ = expand_zone("z", theme="t", difficulty=1, grammar=GRAMMAR)
        hard, _, _ = expand_zone("z", theme="t", difficulty=5, grammar=GRAMMAR)
        easy_nodes = [r for r in easy if "node" in r.id]
        hard_nodes = [r for r in hard if "node" in r.id]
        self.assertGreater(len(hard_nodes), len(easy_nodes))

    def test_secrets_appear_with_difficulty(self):
        for difficulty, expected in ((1, 0), (2, 1), (4, 2)):
            regions, _, _ = expand_zone(
                "z", theme="t", difficulty=difficulty, grammar=GRAMMAR)
            secrets = [r for r in regions if "secret" in r.id]
            self.assertEqual(len(secrets), expected, difficulty)

    def test_a_secret_is_not_reached_from_the_main_path(self):
        """A secret on the main route is a room."""

        _, routes, _ = expand_zone("z", theme="t", difficulty=4, grammar=GRAMMAR)
        for route in routes:
            if "secret" in route.to_id:
                self.assertNotEqual(route.from_id, "z-path")

    def test_the_landmark_is_visible_from_where_the_player_arrives(self):
        """A landmark you cannot see from the entrance orients nobody."""

        _, _, landmarks = expand_zone("z", theme="t", difficulty=3, grammar=GRAMMAR)
        self.assertIn("z-entrance", landmarks[0].visible_from)

    def test_an_impossible_difficulty_is_refused(self):
        with self.assertRaises(GrammarError):
            expand_zone("z", theme="t", difficulty=9, grammar=GRAMMAR)

    def test_the_declared_parts_all_appear(self):
        regions, _, _ = expand_zone("z", theme="t", difficulty=3, grammar=GRAMMAR)
        ids = " ".join(region.id for region in regions)
        for part in ZONE_PARTS:
            token = {"main_path": "path", "gameplay": "node",
                     "transition": "exit"}.get(part, part)
            self.assertIn(token, ids, part)


class TestWorlds(unittest.TestCase):
    def test_a_hub_has_a_portal_per_zone(self):
        """A hub claiming four zones with three doors leaves one reachable only
        by falling into it."""

        zones = [{"id": f"z{i}", "theme": "t", "difficulty": 1} for i in range(4)]
        spec = build_world("w", tokens=TOKENS, zones=zones)
        portals = {r.id for r in spec.regions if r.id.startswith("portal-")}
        self.assertEqual(len(portals), 4)

    def test_the_hub_holds_its_parts(self):
        spec = build_world("w", tokens=TOKENS,
                           zones=[{"id": "z", "theme": "t", "difficulty": 1}])
        ids = {region.id for region in spec.regions}
        for part in HUB_PARTS:
            token = {"landmark": "hub-landmark", "shops": "hub-shops",
                     "social": "hub-social"}[part]
            self.assertIn(token, ids)

    def test_exactly_one_spawn(self):
        spec = build_world("w", tokens=TOKENS,
                           zones=[{"id": "a", "theme": "t", "difficulty": 2},
                                  {"id": "b", "theme": "t", "difficulty": 3}])
        self.assertEqual(sum(1 for r in spec.regions if r.spawn), 1)

    def test_linear_levels_chain_exit_to_entrance(self):
        spec = build_world("w", tokens=TOKENS, topology="linear_levels",
                           zones=[{"id": "a", "theme": "t", "difficulty": 1},
                                  {"id": "b", "theme": "t", "difficulty": 1}])
        pairs = {(route.from_id, route.to_id) for route in spec.circulation}
        self.assertIn(("a-exit", "b-entrance"), pairs)

    def test_a_topology_with_no_structure_is_refused(self):
        """`open_world` used to be the example here, which is the point.

        It was unsupported until the regression corpus asked for it: an island
        survival brief was the one entry of twenty that would not build, because
        this grammar had only ever been asked for the three topologies a tower
        defense and a tycoon need. The property still matters, so the example
        moved to something genuinely unknown.
        """

        with self.assertRaises(GrammarError):
            build_world("w", tokens=TOKENS, topology="spiral_descent",
                        zones=[{"id": "z", "theme": "t"}])

    def test_open_world_rings_its_zones_instead_of_chaining_them(self):
        """A world you can only cross through the middle is a hub in disguise."""

        spec = build_world("w", tokens=TOKENS, topology="open_world",
                           zones=[{"id": "a", "theme": "t", "difficulty": 1},
                                  {"id": "b", "theme": "t", "difficulty": 1},
                                  {"id": "c", "theme": "t", "difficulty": 1}])
        pairs = {(route.from_id, route.to_id) for route in spec.circulation}
        self.assertIn(("a-exit", "b-entrance"), pairs)
        self.assertIn(("b-exit", "c-entrance"), pairs)
        # The loop closes: the last zone leads back to the first.
        self.assertIn(("c-exit", "a-entrance"), pairs)

    def test_open_world_has_no_hub(self):
        spec = build_world("w", tokens=TOKENS, topology="open_world",
                           zones=[{"id": "a", "theme": "t", "difficulty": 1},
                                  {"id": "b", "theme": "t", "difficulty": 1}])
        self.assertNotIn("hub", {region.id for region in spec.regions})

    def test_the_output_is_a_real_world_spec(self):
        """Not a description of one. A grammar emitting its own format would be
        a third world representation to keep in step."""

        spec = build_world("w", tokens=TOKENS,
                           zones=[{"id": "z", "theme": "t", "difficulty": 2}])
        self.assertIsInstance(spec, WorldSpec)

    def test_every_region_is_reachable_from_the_spawn(self):
        """Computed by the spec's own walk, so a disconnected zone is caught
        without Blender, Studio or a build."""

        spec = build_world("w", tokens=TOKENS,
                           zones=[{"id": "a", "theme": "t", "difficulty": 4},
                                  {"id": "b", "theme": "t", "difficulty": 2}])
        _, unreachable = spec.reachable_from_spawn()
        self.assertEqual(unreachable, set())


class TestDescribe(unittest.TestCase):
    def test_what_difficulty_means_is_readable_before_building(self):
        """So a designer can argue with 'difficulty 4 is six nodes and two
        secrets' rather than counting regions afterwards."""

        report = describe([{"id": "v", "difficulty": 4}], tokens=TOKENS)
        self.assertEqual(report["zones"][0]["gameplay"], 5)
        self.assertEqual(report["zones"][0]["secrets"], 2)

    def test_the_dimensions_name_their_source(self):
        report = describe([{"id": "v", "difficulty": 1}], tokens=TOKENS)
        self.assertIn("token set", report["dimensions"]["source"])


class TestAgainstTheRealPlanner(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(REPO)
        except ToolchainUnavailable as exc:
            raise unittest.SkipTest(f"no Luau toolchain: {exc}") from exc

    def test_an_expanded_world_passes_the_real_planner(self):
        """The test the module exists for: WorldKit's own validator, with the
        token grammar it enforces, on a world nobody wrote by hand."""

        spec = build_world("grammar-probe", tokens=TOKENS, zones=[
            {"id": "reef", "theme": "coral reef", "difficulty": 1},
            {"id": "volcanic", "theme": "volcanic", "difficulty": 4},
        ])
        result = plan(REPO, spec)
        self.assertTrue(result.ok, result.summary())

    def test_every_difficulty_produces_a_valid_world(self):
        for difficulty in range(1, MAX_DIFFICULTY + 1):
            spec = build_world(f"d{difficulty}", tokens=TOKENS,
                               zones=[{"id": "z", "theme": "t", "difficulty": difficulty}])
            result = plan(REPO, spec)
            self.assertTrue(result.ok, f"difficulty {difficulty}: {result.summary()}")


if __name__ == "__main__":
    unittest.main()
