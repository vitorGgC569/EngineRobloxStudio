from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from rqe.orchestrator import (
    CampaignStage,
    CampaignStateMachine,
    ImpactSelector,
    OwnershipConflict,
    OwnershipRegistry,
    SQLiteJournal,
    TaskGraph,
    TaskSpec,
    TaskStatus,
    TransitionError,
    ValidationOutcome,
    ValidationScope,
)


ROOT = Path(__file__).resolve().parents[1]


def task(task_id: str, *blocked_by: str) -> TaskSpec:
    return TaskSpec(
        id=task_id,
        stage=CampaignStage.BUILDING,
        role="test-role",
        intent=f"execute {task_id}",
        blocked_by=blocked_by,
        write_set=(f"work/{task_id}.txt",),
    )


class TaskDagInvariantTests(unittest.TestCase):
    def test_blocked_dependency_never_enters_ready_queue(self) -> None:
        graph = TaskGraph((task("build"), task("measure", "build")))

        self.assertEqual([item.id for item in graph.ready_tasks({})], ["build"])
        self.assertNotIn("measure", [item.id for item in graph.ready_tasks({"build": TaskStatus.RUNNING})])
        self.assertNotIn("measure", [item.id for item in graph.ready_tasks({"build": TaskStatus.FAILED})])
        self.assertEqual(graph.blocked_by_failure({"build": TaskStatus.FAILED}), {"measure": ("build",)})
        self.assertEqual(
            [item.id for item in graph.ready_tasks({"build": TaskStatus.SUCCEEDED})],
            ["measure"],
        )

    def test_dependency_cycle_is_rejected_before_scheduling(self) -> None:
        with self.assertRaisesRegex(ValueError, "cycle"):
            TaskGraph((task("world", "ui"), task("ui", "world")))


class OwnershipInvariantTests(unittest.TestCase):
    def test_two_tasks_cannot_own_the_same_casefolded_windows_path_or_ancestor(self) -> None:
        registry = OwnershipRegistry()
        registry.acquire("world", ("Roblox/MVP/src/ServerScriptService",))

        with self.assertRaises(OwnershipConflict):
            registry.acquire(
                "gameplay",
                ("ROBLOX\\mvp\\SRC\\serverscriptservice\\Services\\StoreService.lua",),
            )

        registry.acquire("ui", ("roblox/mvp/src/StarterPlayer",))
        self.assertEqual(set(registry.snapshot()), {"world", "ui"})

    def test_parent_traversal_is_rejected_before_ownership_is_granted(self) -> None:
        with self.assertRaisesRegex(ValueError, "traverse"):
            OwnershipRegistry().acquire("escape", ("roblox/mvp/../../outside.lua",))


class ImpactInvariantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.selector = ImpactSelector.from_file(ROOT / "quality" / "impact-map.json")

    def test_unknown_changed_path_selects_full_regression(self) -> None:
        result = self.selector.select(("new-subsystem/unknown.file",))

        self.assertIs(result.scope, ValidationScope.FULL)
        self.assertEqual(result.unknown_paths, ("new-subsystem/unknown.file",))
        self.assertIn("MEASURE", result.stages)
        self.assertIn("EVALUATE", result.stages)

    def test_known_ui_change_selects_an_impacted_subset(self) -> None:
        result = self.selector.select(
            ("roblox/mvp/src/StarterPlayer/StarterPlayerScripts/FarmHud.client.lua",)
        )

        self.assertIs(result.scope, ValidationScope.IMPACTED)
        self.assertEqual(result.unknown_paths, ())
        self.assertIn("client-ui", result.matched_rules)
        self.assertIn("mobile_ui_valid", result.requirements)


class ReleaseAuthorizationInvariantTests(unittest.TestCase):
    def test_impacted_subset_never_authorizes_release(self) -> None:
        impacted = ValidationOutcome(
            scope=ValidationScope.IMPACTED,
            checks_passed=True,
            deterministic_gate_allowed=True,
        )
        self.assertFalse(impacted.authorizes_release)

        machine = CampaignStateMachine(state=CampaignStage.EVALUATING, history=[CampaignStage.EVALUATING])
        with self.assertRaisesRegex(TransitionError, "FULL"):
            machine.transition(CampaignStage.RELEASED, validation=impacted)

        full = ValidationOutcome(
            scope=ValidationScope.FULL,
            checks_passed=True,
            deterministic_gate_allowed=True,
        )
        self.assertTrue(full.authorizes_release)
        self.assertIs(machine.transition(CampaignStage.RELEASED, validation=full), CampaignStage.RELEASED)


class SQLiteJournalTests(unittest.TestCase):
    def test_committed_events_survive_process_style_reopen(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "orchestrator.sqlite3"
            with SQLiteJournal(path) as journal:
                first = journal.append("campaign-1", "TASK_READY", {"taskId": "world"})
                journal.append("campaign-1", "TASK_SUCCEEDED", {"taskId": "world"})

            with SQLiteJournal(path) as reopened:
                events = reopened.events("campaign-1")
                after_first = reopened.events("campaign-1", after_sequence=first.sequence)

            self.assertEqual([event.kind for event in events], ["TASK_READY", "TASK_SUCCEEDED"])
            self.assertEqual([event.kind for event in after_first], ["TASK_SUCCEEDED"])
            self.assertEqual(events[1].payload, {"taskId": "world"})


if __name__ == "__main__":
    unittest.main()
