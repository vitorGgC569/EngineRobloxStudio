"""The project generator.

The complaint it answers is exact: an agent should not start a game by deciding
where files go. Two agents deciding independently produce two layouts, and every
tool that walks a project then has to handle both.

The property under test is stronger than "it made some directories". A
scaffolded project must **compile immediately** and must **round-trip**: the
model read back off disk has to be the model that was written. A tree that looks
like a project and fails at the first real command has only moved the failure to
whoever comes next.
"""

from __future__ import annotations

import json
import shutil
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from rqe.ir import GameModelError, load_model
from rqe.ir.compiler import compile_model
from rqe.ir.scaffold import DIRECTORIES, ScaffoldError, load_project_model, scaffold_project

REPO = Path(__file__).resolve().parents[1]

OCEAN = {
    "id": "scaffold-probe", "genre": "tycoon", "theme": "underwater research lab",
    "pitch": "A submarine lab tycoon: explore reefs, collect specimens, automate research.",
    "coreLoop": ["explore", "collect", "process", "upgrade", "unlock"],
    "world": {"topology": "hub_and_zones", "zones": [
        {"id": "reef", "theme": "coral reef", "difficulty": 1, "unlockedAtTier": 0},
        {"id": "abyss", "theme": "lightless trench", "difficulty": 3, "unlockedAtTier": 5},
    ]},
    "progression": {"kind": "tiered", "tiers": 8, "firstTierSeconds": 45, "sessionMinutes": 15},
    "economy": {"currencies": [
        {"id": "credits", "displayName": "Credits", "earnedBy": ["process"],
         "spentOn": ["upgrade"]},
        {"id": "research", "displayName": "Research", "earnedBy": ["collect"],
         "spentOn": ["unlock"]},
    ]},
    "systems": ["economy", "progression", "save", "inventory", "analytics"],
    "tokenSet": "tokens/brickfarm.json", "concurrentPlayers": 6,
}


class ScaffoldCase(unittest.TestCase):
    def scaffold(self, document=None, **kwargs):
        """Scaffold into a temporary root that still sees the real schemas.

        The compiler validates against `schemas/`, so the temporary root gets a
        link to the repository's rather than a copy that could go stale.
        """

        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        (root / "schemas").mkdir()
        for schema in (REPO / "schemas").glob("*.json"):
            (root / "schemas" / schema.name).write_bytes(schema.read_bytes())
        (root / "quality").mkdir()
        shutil.copyfile(
            REPO / "quality" / "probe-registry.v1.json",
            root / "quality" / "probe-registry.v1.json",
        )
        (root / "tokens").mkdir()
        shutil.copyfile(
            REPO / "tokens" / "brickfarm.json",
            root / "tokens" / "brickfarm.json",
        )
        model = load_model(document or OCEAN)
        return root, model, scaffold_project(model, root=root, **kwargs)


class TestLayout(ScaffoldCase):
    def test_every_declared_directory_exists(self):
        root, model, _ = self.scaffold()
        for directory in DIRECTORIES:
            self.assertTrue((root / "games" / model.id / directory).is_dir(), directory)

    def test_the_source_roots_match_the_blueprint_ownership(self):
        """A write root the blueprint assigns but the scaffold never made is a
        directory the owning agent creates wherever it happens to be."""

        root, model, _ = self.scaffold()
        blueprint = json.loads(
            (root / "games" / model.id / "blueprint.json").read_text(encoding="utf-8"))
        for entry in blueprint["projects"][0]["ownership"]:
            for write_root in entry["writeRoots"]:
                self.assertTrue((root / write_root).is_dir(), write_root)

    def test_the_model_is_written_where_it_can_be_read_back(self):
        root, model, _ = self.scaffold()
        self.assertTrue((root / "games" / model.id / "game.json").is_file())


class TestDerivation(ScaffoldCase):
    def test_the_model_round_trips(self):
        """If it did not, the project on disk would be a different game from the
        one that was asked for, and nothing would say so."""

        root, model, _ = self.scaffold()
        self.assertEqual(load_project_model(root, model.id).sha256, model.sha256)

    def test_the_intent_is_derived_from_the_model(self):
        root, model, _ = self.scaffold()
        intent = json.loads(
            (root / "games" / model.id / "definition" / "product-intent.json")
            .read_text(encoding="utf-8"))
        self.assertEqual(intent["coreLoop"], list(model.core_loop))
        self.assertEqual(intent["productId"], model.id)

    def test_zones_become_asset_needs(self):
        """The world says there are two zones; the asset plan has to know."""

        root, model, _ = self.scaffold()
        blueprint = json.loads(
            (root / "games" / model.id / "blueprint.json").read_text(encoding="utf-8"))
        ids = {need["id"] for need in blueprint["projects"][0]["assetNeeds"]}
        self.assertIn("zone-reef-kit", ids)
        self.assertIn("zone-abyss-kit", ids)

    def test_the_reference_bundle_is_empty_rather_than_invented(self):
        """Made-up references would let the visual gate compare against
        something nobody chose."""

        root, model, _ = self.scaffold()
        bundle = json.loads(
            (root / "games" / model.id / "definition" / "reference-bundle.json")
            .read_text(encoding="utf-8"))
        self.assertEqual(bundle["references"], [])

    def test_an_economy_is_written_when_one_is_solved(self):
        root, model, _ = self.scaffold(economy={"tierCosts": [1, 2, 3]})
        self.assertTrue((root / "games" / model.id / "economy" / "ladder.json").is_file())

    def test_no_economy_file_when_none_was_solved(self):
        """An empty ladder file would read downstream as a solved economy of
        zero tiers."""

        root, model, _ = self.scaffold()
        self.assertFalse((root / "games" / model.id / "economy" / "ladder.json").exists())


class TestItActuallyWorks(ScaffoldCase):
    def test_a_scaffolded_project_compiles_immediately(self):
        """The whole claim. A tree that fails at the first real command has
        moved the failure rather than removed it."""

        root, model, _ = self.scaffold()
        out = compile_model(load_project_model(root, model.id), root=root)
        tasks = out["plan"]["projects"][0]["tasks"]
        self.assertTrue(tasks)
        self.assertGreater(len({task["stage"] for task in tasks}), 5)

    def test_the_written_blueprint_is_the_one_that_compiles(self):
        root, model, _ = self.scaffold()
        from rqe.orchestrator.blueprint import compile_production_blueprint

        blueprint = json.loads(
            (root / "games" / model.id / "blueprint.json").read_text(encoding="utf-8"))
        plan = compile_production_blueprint(blueprint)
        self.assertTrue(plan.to_dict()["projects"][0]["tasks"])


class TestOperationalReleaseContract(ScaffoldCase):
    def test_project_loads_from_the_game_root_without_a_fixture(self):
        from rqe.project import Project

        root, model, _ = self.scaffold()
        project = Project.load(root / "games" / model.id)
        self.assertEqual(project.root.name, model.id)
        self.assertEqual(project.contract["productId"], model.id)
        self.assertIsNone(project.fixture)
        self.assertNotIn("mining-tycoon", json.dumps(project.config))

    def test_contract_and_visual_spec_compile_into_the_industrial_plan(self):
        from rqe.contract import validate_contract
        from rqe.measurement_plan import compile_measurement_plan
        from rqe.project import Project
        from rqe.visual_spec import load_visual_spec

        root, model, _ = self.scaffold()
        project = Project.load(root / "games" / model.id, include_fixture=False)
        self.assertEqual(validate_contract(project.contract), [])
        visual = load_visual_spec(project)
        plan = compile_measurement_plan(project)
        self.assertEqual(visual.data["productId"], model.id)
        self.assertEqual(plan.metadata["contractName"], "Scaffold Probe")
        self.assertEqual(plan.metadata["tokenConformance"]["status"], "CONFORMS")
        self.assertTrue(plan.metadata["probeRegistry"]["orphans"])

    def test_model_verbs_become_fail_closed_e2e_requirements(self):
        from rqe.measurement_plan import compile_measurement_plan
        from rqe.project import Project

        root, model, _ = self.scaffold()
        project = Project.load(root / "games" / model.id, include_fixture=False)
        plan = compile_measurement_plan(project)
        by_id = {item.id: item for item in plan.requirements}
        for verb in model.core_loop:
            requirement = by_id[f"gameplay_{verb}"]
            self.assertEqual(requirement.minimum_validation_level, "E2E_VALIDATED")
            self.assertEqual(requirement.producer_status, "UNAVAILABLE")

    def test_unapproved_product_truth_blocks_before_build_stamping(self):
        from rqe.product_stamp import ProductStampError, load_product_identity_stamp
        from rqe.project import Project

        root, model, _ = self.scaffold()
        project = Project.load(root / "games" / model.id, include_fixture=False)
        with self.assertRaises(ProductStampError) as caught:
            load_product_identity_stamp(project)
        self.assertIn("not approved release input", str(caught.exception))

    def test_references_and_assets_are_absent_not_fabricated(self):
        root, model, _ = self.scaffold()
        product = root / "games" / model.id
        benchmark = json.loads(
            (product / "definition/reference-benchmark.json").read_text(encoding="utf-8")
        )
        manifest = json.loads(
            (product / "assets/asset-manifest.json").read_text(encoding="utf-8")
        )
        profile = json.loads(
            (product / "definition/release-quality.json").read_text(encoding="utf-8")
        )
        self.assertEqual(benchmark["sources"], [])
        self.assertEqual(benchmark["observations"], [])
        self.assertEqual(manifest["assets"], [])
        self.assertEqual(profile["status"], "BLOCKED")
        self.assertIn("INDEPENDENT_REFERENCE_BENCHMARK_REQUIRED", profile["blockers"])

    def test_initial_scenario_does_not_claim_the_core_loop(self):
        root, model, _ = self.scaffold()
        scenario = json.loads(
            (root / "games" / model.id / "scenarios/initial-runtime.json")
            .read_text(encoding="utf-8")
        )
        self.assertEqual(scenario["releaseEvidence"], [])
        self.assertEqual([next(iter(step)) for step in scenario["steps"]], ["reset", "attach"])

    def test_all_configured_paths_resolve_inside_the_product(self):
        root, model, _ = self.scaffold()
        product = root / "games" / model.id
        config = json.loads((product / "rqe.project.json").read_text(encoding="utf-8"))
        for key in (
            "contract", "productIntent", "rojoProject", "assetManifest",
            "qualityFocus", "probeRegistry", "tokenSet", "agentScenario",
        ):
            self.assertTrue((product / config[key]).exists(), key)
        self.assertFalse(any("mining-tycoon" in item for item in config["expectedPaths"]))

    def test_static_release_reaches_the_real_gate_and_blocks_missing_authority(self):
        if shutil.which("rojo") is None:
            self.skipTest("Rojo is not installed")
        from rqe.release import execute_release

        root, model, _ = self.scaffold()
        shutil.copytree(REPO / "roblox" / "lib", root / "roblox" / "lib")
        product = root / "games" / model.id
        outcome = execute_release(
            product, run_id="scaffold-static-release", static_only=True
        )
        self.assertFalse(outcome.gate.release_allowed)
        self.assertFalse(any(
            "release infrastructure failed" in blocker
            for blocker in outcome.gate.blockers
        ), outcome.gate.blockers)
        preflight = json.loads(
            (outcome.directory / "product-truth/stamp-preflight.json")
            .read_text(encoding="utf-8")
        )
        self.assertEqual(preflight["status"], "BLOCKED")
        self.assertIn("not approved release input", preflight["error"])


class TestRefusals(ScaffoldCase):
    def test_an_incoherent_model_scaffolds_nothing(self):
        """A project tree for a game the model already says will not work is a
        tree somebody has to discover is wrong."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            broken = load_model({**OCEAN, "systems": ["economy"]})
            with self.assertRaises(ScaffoldError):
                scaffold_project(broken, root=root)
            self.assertFalse((root / "games").exists())

    def test_existing_files_are_left_alone_and_named(self):
        """Clobbering a definition would destroy the game it was asked to
        start."""

        root, model, _ = self.scaffold()
        marker = root / "games" / model.id / "game.json"
        marker.write_text('{"sentinel": true}', encoding="utf-8")
        again = scaffold_project(model, root=root)
        self.assertIn("game.json", again.skipped)
        self.assertEqual(marker.read_text(encoding="utf-8"), '{"sentinel": true}')

    def test_force_overwrites_when_asked(self):
        root, model, _ = self.scaffold()
        (root / "games" / model.id / "game.json").write_text("{}", encoding="utf-8")
        again = scaffold_project(model, root=root, force=True)
        self.assertIn("game.json", again.created)
        self.assertEqual(load_project_model(root, model.id).sha256, model.sha256)

    def test_reading_a_project_that_has_no_model_is_refused(self):
        with TemporaryDirectory() as directory:
            with self.assertRaises(ScaffoldError) as caught:
                load_project_model(Path(directory), "nothing-here")
            self.assertIn("cannot be recompiled", str(caught.exception))

    def test_a_corrupt_model_names_the_file(self):
        root, model, _ = self.scaffold()
        (root / "games" / model.id / "game.json").write_text("{not json", encoding="utf-8")
        with self.assertRaises(ScaffoldError) as caught:
            load_project_model(root, model.id)
        self.assertIn("game.json", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
