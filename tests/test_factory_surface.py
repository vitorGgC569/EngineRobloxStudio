"""The factory surface, and the two-game generality proof as an artefact.

Until now genericity was a claim about the SDK layers. `games/portfolio.blueprint.json`
turns it into something the factory compiles: two products that disagree on
topology, progression and space, travelling the same deterministic DAG.

The refusal tests matter as much as the compile ones. Half of this surface is
shaped by what it will not do -- promote a run its gate rejected, stop Studio
without confirmation, dispatch a command the manifest declares unsupported --
and a refusal nobody has seen fire is a refusal nobody should trust.
"""

from __future__ import annotations

import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from rqe.mcp import protocol
from rqe.mcp.tools import build_server


REPO = Path(__file__).resolve().parents[1]
BLUEPRINT = "games/portfolio.blueprint.json"


def write_currently_bound_blueprint(directory: Path) -> str:
    """Write a blueprint whose declared input hashes match this checkout.

    The checked-in portfolio remains useful as a compile fixture even when its
    product definitions are edited.  Execution is stricter: its verification
    handlers must see hashes that bind the exact bytes they read.
    """

    document = json.loads((REPO / BLUEPRINT).read_text(encoding="utf-8"))
    for project in document["projects"]:
        temporary_root = (
            directory.relative_to(REPO) / "artifacts" / project["productId"]
        ).as_posix()
        project["artifactRoot"] = temporary_root
        for output in project["outputArtifactRefs"]:
            output["path"] = f"{temporary_root}/{output['kind'].lower()}"
        refs = [project["productIntentRef"], project["referenceBundleRef"]]
        refs.extend(profile["inputRef"] for profile in project["qualityProfiles"])
        for reference in refs:
            reference["sha256"] = hashlib.sha256(
                (REPO / reference["path"]).read_bytes()
            ).hexdigest()
    path = directory / "bound-portfolio.blueprint.json"
    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return path.relative_to(REPO).as_posix()


class FactorySurfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = build_server(REPO)

    def call(self, name: str, arguments: dict) -> dict:
        message = protocol.encode({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        })
        sink = io.BytesIO()
        self.server.serve(io.BytesIO(message), sink)
        document = json.loads(sink.getvalue().splitlines()[0])
        return document.get("result") or {
            "isError": True,
            "structuredContent": {"error": str(document.get("error"))},
        }

    def data(self, name: str, arguments: dict) -> dict:
        result = self.call(name, arguments)
        self.assertFalse(
            result["isError"],
            f"{name} failed: {result['structuredContent'].get('error')}",
        )
        return result["structuredContent"]["data"]


class TestTwoGameBlueprint(FactorySurfaceTests):
    """The generality proof, as an artefact rather than an assertion."""

    def test_the_blueprint_exists_and_holds_two_products(self):
        document = json.loads((REPO / BLUEPRINT).read_text(encoding="utf-8"))
        self.assertEqual(len(document["projects"]), 2)

    def test_both_products_compile_through_the_same_dag(self):
        data = self.data("factory_create_project", {"definition": BLUEPRINT})
        self.assertEqual(data["productCount"], 2)
        stages = [set(product["stages"]) for product in data["products"]]
        # Identical stage sets is the claim: two different games, one pipeline.
        self.assertEqual(stages[0], stages[1])
        self.assertEqual(data["products"][0]["tasks"], data["products"][1]["tasks"])

    def test_the_two_products_disagree_on_every_structural_axis(self):
        document = json.loads((REPO / BLUEPRINT).read_text(encoding="utf-8"))
        intents = []
        for project in document["projects"]:
            path = REPO / project["productIntentRef"]["path"]
            intents.append(json.loads(path.read_text(encoding="utf-8")))
        first, second = intents
        for axis in ("topology", "progression", "privateSpace"):
            self.assertNotEqual(first[axis], second[axis], axis)

    def test_the_pipeline_covers_specification_through_regression(self):
        data = self.data("factory_create_project", {"definition": BLUEPRINT})
        stages = set(data["products"][0]["stages"])
        for required in ("SPECIFYING", "BUILDING", "PLAYING", "CAPTURING",
                         "EVALUATING", "REPAIRING", "REGRESSION_FULL"):
            self.assertIn(required, stages)

    def test_a_plan_is_deterministic(self):
        """Same blueprint, same plan hash. Without this a regression cannot be
        attributed to a change rather than to the compiler."""

        first = self.data("factory_create_project", {"definition": BLUEPRINT})
        second = self.data("factory_create_project", {"definition": BLUEPRINT})
        self.assertEqual(first["planSha256"], second["planSha256"])

    def test_compiling_a_plan_executes_nothing(self):
        data = self.data("factory_create_project", {"definition": BLUEPRINT})
        self.assertIn("nothing has been executed", data["note"])

    def test_references_are_bound_by_content_hash(self):
        """A citation nobody can check is decoration."""

        import hashlib

        document = json.loads((REPO / BLUEPRINT).read_text(encoding="utf-8"))
        bundle_path = REPO / document["projects"][0]["referenceBundleRef"]["path"]
        bundle = json.loads(bundle_path.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(bundle["references"]), 5)
        for reference in bundle["references"]:
            frame = REPO / reference["path"]
            self.assertTrue(frame.is_file(), reference["path"])
            self.assertEqual(
                hashlib.sha256(frame.read_bytes()).hexdigest(), reference["sha256"]
            )

    def test_a_contract_is_not_a_blueprint(self):
        result = self.call(
            "factory_create_project",
            {"definition": "contracts/mining-tycoon.robloxqa.json"},
        )
        self.assertTrue(result["isError"])


class TestPlanShapeIsReadCorrectly(FactorySurfaceTests):
    """Tasks live under each project and carry a `stage`, not a `phase`.

    Reading either wrongly reported zero tasks, which looks like a blueprint
    that compiled to nothing rather than a reader looking in the wrong place.
    Only a real blueprint exposed it.
    """

    def test_factory_inspect_finds_the_tasks(self):
        data = self.data("factory_inspect", {"project": BLUEPRINT})
        self.assertGreater(data["tasks"], 0)
        self.assertEqual(data["productCount"], 2)

    def test_every_task_is_attributed_to_a_role(self):
        data = self.data("factory_inspect", {"project": BLUEPRINT})
        for product in data["products"]:
            self.assertTrue(product["roles"], product["productId"])


class TestDestructiveToolsRefuse(FactorySurfaceTests):
    def test_stopping_studio_needs_confirmation(self):
        result = self.call("studio_stop", {})
        self.assertTrue(result["isError"])
        self.assertIn("discards unsaved work", result["structuredContent"]["error"])

    def test_restarting_studio_needs_confirmation(self):
        result = self.call("studio_restart", {"place": BLUEPRINT})
        self.assertTrue(result["isError"])
        self.assertIn("confirmDiscardUnsavedWork", result["structuredContent"]["error"])

    def test_a_path_outside_the_project_is_refused(self):
        result = self.call("factory_inspect", {"project": "../../../etc/passwd"})
        self.assertTrue(result["isError"])


class TestReleasePromotion(FactorySurfaceTests):
    def test_a_run_whose_gate_refused_cannot_be_promoted(self):
        data = self.data("release_promote", {"run": "artifacts/p0-provenance-static-003"})
        self.assertFalse(data["promoted"])
        self.assertIn("did not allow", data["reason"])

    def test_a_run_that_was_never_evaluated_cannot_be_promoted(self):
        result = self.call("release_promote", {"run": "artifacts/run-00002"})
        self.assertTrue(result["isError"])
        self.assertIn("never evaluated", result["structuredContent"]["error"])

    def test_promotion_requires_an_explicit_decision(self):
        """Even a passing gate is not permission on its own: promotion sends
        something outward and must never be reached by a default argument."""

        import tempfile

        with tempfile.TemporaryDirectory(dir=REPO / ".tmp") as directory:
            run = Path(directory)
            (run / "gate.json").write_text(
                json.dumps({"releaseAllowed": True, "runId": "r1", "blockers": []}),
                encoding="utf-8",
            )
            relative = run.relative_to(REPO).as_posix()
            data = self.data("release_promote", {"run": relative})
            self.assertFalse(data["promoted"])
            self.assertIn("explicit decision", data["reason"])

            promoted = self.data(
                "release_promote", {"run": relative, "confirmPromotion": True}
            )
            self.assertTrue(promoted["promoted"])
            # Approved by the engine is not published to Roblox, and the receipt
            # has to say which one happened.
            self.assertIn("separate human action", promoted["note"])
            self.assertTrue((run / "promotion.json").is_file())


class TestCapabilityInventory(FactorySurfaceTests):
    def test_the_inventory_reads_the_catalogue_not_the_summary(self):
        """Reading ids off the coverage report gives a listing with no risks,
        limitations or gaps in it -- exactly the part that decides what to rely
        on."""

        # Pick a capability that still has gaps rather than naming one.
        #
        # This asserted against `assets.geometry.author` by name, and broke the
        # day that capability was finished and its gaps were legitimately
        # emptied -- the catalogue refuses an AVAILABLE capability that still
        # declares one. A test that fails when the project improves is a test
        # that argues against improving it.
        listing = self.data("capabilities_explain", {})
        capability_ids = [
            capability_id
            for group in listing["byStatus"].values()
            for capability_id in group
        ]
        self.assertTrue(capability_ids, "capability catalogue is unexpectedly empty")

        chosen = None
        for capability_id in capability_ids:
            data = self.data("capabilities_explain", {"capabilityId": capability_id})
            if data["gaps"] or data["limitations"]:
                chosen = data
                break
        if chosen is None:
            chosen = self.data(
                "capabilities_explain", {"capabilityId": capability_ids[0]}
            )

        self.assertIn("risks", chosen)
        self.assertIn("gaps", chosen)
        self.assertIn("limitations", chosen)
        if chosen.get("status") == "AVAILABLE":
            self.assertEqual(chosen["gaps"], [])

    def test_the_inventory_groups_by_status(self):
        data = self.data("capabilities_explain", {})
        self.assertGreater(data["capabilityCount"], 30)
        self.assertIn("AVAILABLE", data["byStatus"])
        self.assertFalse(data["authorizesRelease"])

    def test_an_unknown_capability_lists_the_real_ones(self):
        result = self.call("capabilities_explain", {"capabilityId": "nope"})
        self.assertTrue(result["isError"])
        self.assertIn("assets.geometry.author", result["structuredContent"]["error"])

    def test_a_selection_never_authorises_a_release(self):
        data = self.data("capabilities_select", {"phases": ["edit"]})
        self.assertFalse(data["authorizesRelease"])
        self.assertIn("never that it is good enough to ship", data["note"])

    def test_an_unknown_phase_is_refused(self):
        result = self.call("capabilities_select", {"phases": ["imaginary"]})
        self.assertTrue(result["isError"])


class TestCampaignStateMachine(FactorySurfaceTests):
    def test_a_fresh_campaign_starts_created(self):
        data = self.data("factory_campaign", {"campaign": "test-fresh", "action": "inspect"})
        self.assertEqual(data["state"], "CREATED")
        self.assertFalse(data["terminal"])

    def test_released_is_unreachable_without_a_passing_gate(self):
        result = self.call(
            "factory_campaign",
            {"campaign": "test-illegal", "action": "execute", "stage": "RELEASED",
             "journal": ".tmp/test-illegal.sqlite"},
        )
        self.assertTrue(result["isError"])

    def test_an_unknown_stage_is_refused(self):
        result = self.call(
            "factory_campaign",
            {"campaign": "test-bogus", "action": "execute", "stage": "IMAGINARY",
             "journal": ".tmp/test-bogus.sqlite"},
        )
        self.assertTrue(result["isError"])


class TestDurableFactoryExecution(FactorySurfaceTests):
    def test_blueprint_run_resume_and_inspect_use_only_proven_handlers(self):
        with tempfile.TemporaryDirectory(dir=REPO / ".tmp") as temporary:
            directory = Path(temporary)
            source = write_currently_bound_blueprint(directory)
            journal = (directory / "durable.sqlite3").relative_to(REPO).as_posix()

            first = self.data(
                "factory_execute",
                {
                    "source": source,
                    "campaign": "verified-blueprint",
                    "action": "run",
                    "journal": journal,
                    # Exactly the two specification and two design tasks. The
                    # next production task must not be reached in this pass.
                    "maxTasks": 4,
                },
            )
            self.assertEqual(first["statusCounts"]["SUCCEEDED"], 4)
            self.assertEqual(len(first["registeredHandlers"]), 4)
            self.assertTrue(
                all(
                    key.endswith((".specify", ".design"))
                    for key in first["registeredHandlers"]
                )
            )
            self.assertFalse(first["authorizesRelease"])
            self.assertEqual(first["validationLevel"], "NOT_VALIDATED")
            self.assertFalse(first["studioUsed"])
            self.assertEqual(first["studioEvidence"], "NOT_COLLECTED")
            self.assertTrue(first["journalPersisted"])
            for product in ("anime-card-farm", "lantern-siege"):
                production_plan = directory / "artifacts" / product / "production_plan"
                specification = production_plan / "specification" / "verification.json"
                design = production_plan / "design" / "verification.json"
                self.assertTrue(specification.is_file())
                self.assertTrue(design.is_file())
                for receipt_path in (specification, design):
                    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                    self.assertEqual(receipt["planSha256"], first["planSha256"])
                    self.assertEqual(receipt["validationLevel"], "STATICALLY_VALIDATED")
                    self.assertFalse(receipt["authorizesRelease"])
                    self.assertFalse(receipt["studioUsed"])

            resumed = self.data(
                "factory_execute",
                {
                    "source": source,
                    "campaign": "verified-blueprint",
                    "action": "resume",
                    "journal": journal,
                },
            )
            self.assertTrue(resumed["finished"])
            self.assertGreater(resumed["statusCounts"]["UNSUPPORTED"], 0)
            self.assertGreater(resumed["statusCounts"]["BLOCKED"], 0)
            self.assertFalse(resumed["allSucceeded"])
            self.assertIn("no registered executor adapter", resumed["remainingGap"])

            inspected = self.data(
                "factory_execute",
                {
                    "source": source,
                    "campaign": "verified-blueprint",
                    "action": "inspect",
                    "journal": journal,
                },
            )
            self.assertEqual(inspected["tasks"], resumed["tasks"])
            self.assertEqual(inspected["journalEventCount"], resumed["journalEventCount"])
            self.assertFalse(inspected["authorizesRelease"])

    def test_serialized_plan_has_an_empty_registry_and_fails_closed(self):
        with tempfile.TemporaryDirectory(dir=REPO / ".tmp") as temporary:
            directory = Path(temporary)
            output = directory.relative_to(REPO).as_posix()
            compiled = self.data(
                "factory_create_project",
                {"definition": BLUEPRINT, "output": output},
            )
            journal = (directory / "serialized.sqlite3").relative_to(REPO).as_posix()

            result = self.data(
                "factory_execute",
                {
                    "source": compiled["plan"],
                    "campaign": "serialized-plan",
                    "action": "run",
                    "journal": journal,
                },
            )

            self.assertEqual(result["sourceKind"], "COMPILED_PLAN")
            self.assertEqual(result["registeredHandlers"], [])
            self.assertTrue(result["finished"])
            self.assertGreater(result["statusCounts"]["UNSUPPORTED"], 0)
            self.assertGreater(result["statusCounts"]["BLOCKED"], 0)
            self.assertEqual(result["statusCounts"].get("SUCCEEDED", 0), 0)
            self.assertFalse(result["authorizesRelease"])
            self.assertFalse(result["studioUsed"])

    def test_a_blueprint_with_an_input_hash_mismatch_is_blocked(self):
        with tempfile.TemporaryDirectory(dir=REPO / ".tmp") as temporary:
            directory = Path(temporary)
            source = write_currently_bound_blueprint(directory)
            source_path = REPO / source
            payload = json.loads(source_path.read_text(encoding="utf-8"))
            payload["projects"][0]["productIntentRef"]["sha256"] = "0" * 64
            source_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            journal = (directory / "mismatch.sqlite3").relative_to(REPO).as_posix()

            result = self.data(
                "factory_execute",
                {
                    "source": source,
                    "campaign": "mismatched-input",
                    "action": "run",
                    "journal": journal,
                    "maxTasks": 2,
                },
            )

            states = {item["taskId"]: item for item in result["tasks"]}
            self.assertEqual(states["anime-card-farm.specify"]["status"], "BLOCKED")
            self.assertEqual(
                states["anime-card-farm.specify"]["errorCode"],
                "SPECIFICATION_NOT_VERIFIED",
            )
            self.assertEqual(states["lantern-siege.specify"]["status"], "SUCCEEDED")
            self.assertFalse(result["authorizesRelease"])
            self.assertFalse(
                (
                    directory
                    / "artifacts"
                    / "anime-card-farm"
                    / "production_plan"
                    / "specification"
                    / "verification.json"
                ).exists()
            )

    def test_an_altered_compiled_plan_is_refused_before_journalling(self):
        with tempfile.TemporaryDirectory(dir=REPO / ".tmp") as temporary:
            directory = Path(temporary)
            output = directory.relative_to(REPO).as_posix()
            compiled = self.data(
                "factory_create_project",
                {"definition": BLUEPRINT, "output": output},
            )
            plan_path = REPO / compiled["plan"]
            payload = json.loads(plan_path.read_text(encoding="utf-8"))
            payload["projects"][0]["tasks"][0]["intent"] = "altered after compilation"
            plan_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            journal_path = directory / "must-not-exist.sqlite3"

            result = self.call(
                "factory_execute",
                {
                    "source": compiled["plan"],
                    "campaign": "altered-plan",
                    "action": "run",
                    "journal": journal_path.relative_to(REPO).as_posix(),
                },
            )

            self.assertTrue(result["isError"])
            self.assertIn("compiled plan hash mismatch", result["structuredContent"]["error"])
            self.assertFalse(journal_path.exists())

    def test_cancel_is_durable_and_never_starts_a_handler(self):
        with tempfile.TemporaryDirectory(dir=REPO / ".tmp") as temporary:
            directory = Path(temporary)
            source = write_currently_bound_blueprint(directory)
            journal = (directory / "cancel.sqlite3").relative_to(REPO).as_posix()

            result = self.data(
                "factory_execute",
                {
                    "source": source,
                    "campaign": "cancel-before-run",
                    "action": "cancel",
                    "cancellationReason": "operator stopped before execution",
                    "journal": journal,
                },
            )

            self.assertTrue(result["cancellationRequested"])
            self.assertEqual(set(result["statusCounts"]), {"CANCELLED"})
            self.assertTrue(result["finished"])
            self.assertFalse(result["allSucceeded"])
            self.assertFalse(result["authorizesRelease"])


class TestScenarioStepBounds(FactorySurfaceTests):
    def test_an_out_of_range_step_is_refused_before_touching_studio(self):
        result = self.call(
            "scenario_step",
            {"scenario": "contracts/scenarios/purchase-first-pack.json", "index": 99},
        )
        self.assertTrue(result["isError"])
        self.assertIn("does not exist", result["structuredContent"]["error"])


if __name__ == "__main__":
    unittest.main()
