from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from rqe.orchestrator.blueprint import (
    OUTPUT_KINDS,
    BlueprintError,
    GameProjectDefinition,
    ProductionBlueprint,
    compile_production_blueprint,
    load_production_blueprint,
)
from rqe.schema_validation import validate_schema_instance


ROOT = Path(__file__).resolve().parents[1]


def artifact_outputs(product_id: str, artifact_root: str) -> list[dict[str, object]]:
    return [
        {
            "productId": product_id,
            "artifactId": f"{product_id}.{kind.lower()}",
            "kind": kind,
            "path": f"{artifact_root}/{kind.lower()}",
        }
        for kind in sorted(OUTPUT_KINDS)
    ]


def project_definition(
    product_id: str,
    *,
    source_root: str | None = None,
    artifact_root: str | None = None,
) -> dict[str, object]:
    source = source_root or f"games/{product_id}"
    artifacts = artifact_root or f"artifacts/products/{product_id}"
    return {
        "schemaVersion": 1,
        "projectId": f"project-{product_id}",
        "productId": product_id,
        "revision": "1.0.0",
        "seed": 982451653,
        "genre": "simulation",
        "templateId": "template-simulation-v1",
        "sourceRoot": source,
        "artifactRoot": artifacts,
        "productIntentRef": {
            "productId": product_id,
            "artifactId": f"{product_id}.intent",
            "kind": "PRODUCT_INTENT",
            "path": f"{source}/definition/product-intent.json",
            "sha256": "a" * 64,
        },
        "referenceBundleRef": {
            "productId": product_id,
            "artifactId": f"{product_id}.references",
            "kind": "REFERENCE_BUNDLE",
            "path": f"{source}/definition/reference-bundle.json",
            "sha256": "b" * 64,
        },
        "subsystems": [
            {"id": "world", "capability": "world composition", "dependencies": []},
            {"id": "gameplay", "capability": "server-authoritative loop", "dependencies": ["world"]},
        ],
        "ownership": [
            {
                "subsystemId": "world",
                "ownerRole": "world-agent",
                "writeRoots": [f"{source}/src/world"],
            },
            {
                "subsystemId": "gameplay",
                "ownerRole": "gameplay-agent",
                "writeRoots": [f"{source}/src/gameplay"],
            },
        ],
        "deviceViewpointMatrix": {
            "devices": [
                {
                    "id": "desktop",
                    "viewportWidth": 1920,
                    "viewportHeight": 1080,
                    "inputModes": ["KEYBOARD_MOUSE"],
                },
                {
                    "id": "phone",
                    "viewportWidth": 390,
                    "viewportHeight": 844,
                    "inputModes": ["TOUCH"],
                },
            ],
            "viewpoints": [
                {"id": "overview", "purpose": "world readability", "cameraMode": "FIXED"},
                {"id": "player", "purpose": "core interaction", "cameraMode": "PLAYER"},
            ],
            "combinations": [
                {"deviceId": "desktop", "viewpointId": "overview"},
                {"deviceId": "phone", "viewpointId": "player"},
            ],
        },
        "scenarioClasses": [
            {
                "id": "first-session",
                "class": "ONBOARDING",
                "requiredForRelease": True,
                "actorProfile": "new-player",
            },
            {
                "id": "primary-loop",
                "class": "CORE_LOOP",
                "requiredForRelease": True,
                "actorProfile": "returning-player",
            },
        ],
        "assetNeeds": [
            {
                "id": "experience-icon",
                "type": "ICON",
                "strategy": "EITHER",
                "requiredForRelease": True,
                "consumers": ["gameplay"],
                "acceptanceProfileId": "release-quality",
            }
        ],
        "qualityProfiles": [
            {
                "id": "release-quality",
                "requiredForRelease": True,
                "appliesTo": ["GAMEPLAY", "VISUAL", "ASSETS", "RELEASE"],
                "inputRef": {
                    "productId": product_id,
                    "artifactId": f"{product_id}.quality",
                    "kind": "QUALITY_PROFILE",
                    "path": f"{source}/definition/release-quality.json",
                    "sha256": "c" * 64,
                },
            }
        ],
        "outputArtifactRefs": artifact_outputs(product_id, artifacts),
    }


def blueprint(*projects: dict[str, object]) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "blueprintId": "portfolio-production",
        "revision": "2026.08",
        "engine": {
            "engineId": "rqe",
            "version": "1.0.0",
            "sourceRoots": ["rqe", "schemas", "apps/studio-plugin", "roblox/lib"],
        },
        "projects": list(projects),
    }


class GameProjectDefinitionTests(unittest.TestCase):
    def test_genre_and_template_are_optional_product_choices(self) -> None:
        raw = project_definition("alpha-game")
        del raw["genre"]
        del raw["templateId"]

        project = GameProjectDefinition.from_dict(raw)

        self.assertIsNone(project.genre)
        self.assertIsNone(project.template_id)

    def test_schema_and_semantics_fail_closed_when_an_essential_field_is_missing(self) -> None:
        raw = project_definition("alpha-game")
        del raw["deviceViewpointMatrix"]

        with self.assertRaisesRegex(BlueprintError, "deviceViewpointMatrix.*required"):
            GameProjectDefinition.from_dict(raw)

    def test_every_declared_subsystem_requires_exactly_one_isolated_owner(self) -> None:
        raw = project_definition("alpha-game")
        raw["ownership"] = raw["ownership"][:1]

        with self.assertRaisesRegex(BlueprintError, "ownership must cover every subsystem exactly once"):
            GameProjectDefinition.from_dict(raw)

        raw = project_definition("alpha-game")
        raw["ownership"][1]["writeRoots"] = ["games/alpha-game/src/world/nested"]
        with self.assertRaisesRegex(BlueprintError, "conflicts"):
            GameProjectDefinition.from_dict(raw)

    def test_unknown_and_cyclic_subsystem_dependencies_are_rejected(self) -> None:
        raw = project_definition("alpha-game")
        raw["subsystems"][1]["dependencies"] = ["missing"]
        with self.assertRaisesRegex(BlueprintError, "unknown dependencies"):
            GameProjectDefinition.from_dict(raw)

        raw = project_definition("alpha-game")
        raw["subsystems"][0]["dependencies"] = ["gameplay"]
        with self.assertRaisesRegex(BlueprintError, "cycle"):
            GameProjectDefinition.from_dict(raw)

    def test_matrix_must_resolve_and_cover_every_declared_device_and_viewpoint(self) -> None:
        raw = project_definition("alpha-game")
        raw["deviceViewpointMatrix"]["combinations"] = [
            {"deviceId": "desktop", "viewpointId": "missing"}
        ]
        with self.assertRaisesRegex(BlueprintError, "unknown viewpointId"):
            GameProjectDefinition.from_dict(raw)

        raw = project_definition("alpha-game")
        raw["deviceViewpointMatrix"]["combinations"] = [
            {"deviceId": "desktop", "viewpointId": "overview"}
        ]
        with self.assertRaisesRegex(BlueprintError, "leaves entries uncovered"):
            GameProjectDefinition.from_dict(raw)

    def test_all_industrial_output_roots_are_explicit_and_non_overlapping(self) -> None:
        raw = project_definition("alpha-game")
        raw["outputArtifactRefs"] = raw["outputArtifactRefs"][:-1]
        with self.assertRaisesRegex(BlueprintError, "must bind every production output exactly once"):
            GameProjectDefinition.from_dict(raw)

        raw = project_definition("alpha-game")
        raw["outputArtifactRefs"][1]["path"] = raw["outputArtifactRefs"][0]["path"] + "/nested"
        with self.assertRaisesRegex(BlueprintError, "output artifact roots must be isolated"):
            GameProjectDefinition.from_dict(raw)


class ProductIsolationTests(unittest.TestCase):
    def test_product_and_project_identities_are_unique_across_a_blueprint(self) -> None:
        alpha = project_definition("alpha-game")
        duplicate_product = project_definition("alpha-game", source_root="games/alpha-copy")
        duplicate_product["projectId"] = "project-alpha-copy"
        duplicate_product["artifactRoot"] = "artifacts/products/alpha-copy"
        duplicate_product["outputArtifactRefs"] = artifact_outputs(
            "alpha-game", "artifacts/products/alpha-copy"
        )
        with self.assertRaisesRegex(BlueprintError, "duplicate productId"):
            ProductionBlueprint.from_dict(blueprint(alpha, duplicate_product))

        beta = project_definition("beta-game")
        beta["projectId"] = alpha["projectId"]
        with self.assertRaisesRegex(BlueprintError, "duplicate projectId"):
            ProductionBlueprint.from_dict(blueprint(alpha, beta))

    def test_a_project_cannot_reference_an_artifact_owned_by_another_product(self) -> None:
        raw = project_definition("alpha-game")
        raw["productIntentRef"]["productId"] = "beta-game"

        with self.assertRaisesRegex(BlueprintError, "belongs to productId 'beta-game'"):
            ProductionBlueprint.from_dict(blueprint(raw))

    def test_owner_label_cannot_hide_a_path_inside_another_project(self) -> None:
        raw = project_definition("alpha-game")
        raw["referenceBundleRef"]["path"] = "games/beta-game/definition/reference-bundle.json"

        with self.assertRaisesRegex(BlueprintError, "escapes this project's"):
            ProductionBlueprint.from_dict(blueprint(raw))

    def test_project_roots_cannot_overlap_each_other_or_engine_source(self) -> None:
        alpha = project_definition("alpha-game")
        beta = project_definition("beta-game", source_root="games/alpha-game/embedded")
        with self.assertRaisesRegex(BlueprintError, "are not isolated"):
            ProductionBlueprint.from_dict(blueprint(alpha, beta))

        engine_child = project_definition("engine-child", source_root="rqe/game-project")
        with self.assertRaisesRegex(BlueprintError, "overlaps engine root"):
            ProductionBlueprint.from_dict(blueprint(engine_child))

    def test_two_games_compile_into_disjoint_dags_and_artifact_spaces(self) -> None:
        definition = ProductionBlueprint.from_dict(
            blueprint(project_definition("alpha-game"), project_definition("beta-game"))
        )
        plan = compile_production_blueprint(definition)

        self.assertEqual([item.product_id for item in plan.projects], ["alpha-game", "beta-game"])
        alpha_tasks = {task.id for task in plan.projects[0].tasks}
        beta_tasks = {task.id for task in plan.projects[1].tasks}
        self.assertTrue(alpha_tasks)
        self.assertTrue(beta_tasks)
        self.assertFalse(alpha_tasks & beta_tasks)

        for project_plan, expected_root, forbidden_root in (
            (plan.projects[0], "games/alpha-game", "games/beta-game"),
            (plan.projects[1], "games/beta-game", "games/alpha-game"),
        ):
            for task in project_plan.tasks:
                for path in (*task.read_set, *task.write_set):
                    self.assertNotEqual(path, forbidden_root)
                    self.assertFalse(path.startswith(forbidden_root + "/"))
                self.assertEqual(task.metadata["productId"], project_plan.product_id)

        alpha_intents = {
            task.id.removeprefix("alpha-game."): task.intent for task in plan.projects[0].tasks
        }
        beta_intents = {
            task.id.removeprefix("beta-game."): task.intent for task in plan.projects[1].tasks
        }
        self.assertEqual(alpha_intents, beta_intents)


class ProductionPlanTests(unittest.TestCase):
    def test_compilation_is_deterministic_and_only_claims_static_validation(self) -> None:
        raw = blueprint(project_definition("alpha-game"), project_definition("beta-game"))
        first = compile_production_blueprint(raw)

        reordered = copy.deepcopy(raw)
        reordered["projects"].reverse()
        reordered["engine"]["sourceRoots"].reverse()
        for item in reordered["projects"]:
            item["subsystems"].reverse()
            item["ownership"].reverse()
            item["scenarioClasses"].reverse()
            item["outputArtifactRefs"].reverse()
        second = compile_production_blueprint(reordered)

        self.assertEqual(first.to_dict(), second.to_dict())
        self.assertEqual(first.sha256, second.sha256)
        self.assertEqual(first.validation_level, "STATICALLY_VALIDATED")
        self.assertEqual(first.to_dict()["planSha256"], first.sha256)
        schema = json.loads((ROOT / "schemas" / "production-plan.v1.schema.json").read_text(encoding="utf-8"))
        self.assertEqual([], validate_schema_instance(first.to_dict(), schema))

    def test_plan_contains_the_generic_full_production_flow_but_does_not_release(self) -> None:
        plan = compile_production_blueprint(blueprint(project_definition("alpha-game")))
        tasks = plan.projects[0].tasks
        suffixes = {task.id.removeprefix("alpha-game.") for task in tasks}

        self.assertTrue(
            {
                "specify",
                "design",
                "assets.finalize",
                "build.world",
                "build.gameplay",
                "source.finalize",
                "integrate",
                "measure",
                "play.first-session",
                "capture.desktop.overview",
                "evaluate.release-quality",
                "repair.plan",
                "regression.impacted",
                "regression.full",
                "release.candidate",
            }.issubset(suffixes)
        )
        self.assertFalse(any(task.id.endswith(".release") for task in tasks))
        candidate = next(task for task in tasks if task.id.endswith("release.candidate"))
        self.assertIn("candidate", candidate.intent)
        self.assertIn("regression.full", candidate.blocked_by[0])

    def test_zero_asset_needs_is_an_explicit_supported_choice_not_an_omission(self) -> None:
        raw_project = project_definition("alpha-game")
        raw_project["assetNeeds"] = []
        plan = compile_production_blueprint(blueprint(raw_project))
        suffixes = {task.id.removeprefix("alpha-game.") for task in plan.projects[0].tasks}

        self.assertIn("assets.finalize", suffixes)
        self.assertFalse(any(suffix.startswith("asset.") for suffix in suffixes))

    def test_blueprint_can_be_loaded_from_a_file_without_touching_a_game(self) -> None:
        raw = blueprint(project_definition("alpha-game"))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "portfolio.blueprint.json"
            path.write_text(json.dumps(raw), encoding="utf-8")
            loaded = load_production_blueprint(path)

        self.assertEqual(loaded.blueprint_id, "portfolio-production")
        self.assertEqual(loaded.projects[0].product_id, "alpha-game")


if __name__ == "__main__":
    unittest.main()
