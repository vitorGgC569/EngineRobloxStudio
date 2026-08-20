from __future__ import annotations

import tempfile
import time
import unittest
from pathlib import Path

from rqe.orchestrator import (
    CampaignBindingError,
    CampaignStage,
    DurableDagExecutor,
    ExecutionPolicy,
    HandlerRegistry,
    HandlerResult,
    LeaseUnavailable,
    SQLiteJournal,
    StaleFenceError,
    TaskSpec,
    TaskStatus,
)


PLAN_HASH = "a" * 64


def task(
    task_id: str,
    *dependencies: str,
    checks: tuple[str, ...] = ("output exists",),
    guard: bool = False,
    resources: tuple[str, ...] = (),
) -> TaskSpec:
    return TaskSpec(
        id=task_id,
        stage=CampaignStage.BUILDING,
        role=f"role-{task_id}",
        intent=f"execute {task_id}",
        blocked_by=dependencies,
        write_set=(f"work/{task_id}.json",),
        resource_claims=resources,
        completion_checks=checks,
        guard_required=guard,
        metadata={"productId": "test-product"},
    )


def success(context) -> HandlerResult:
    return HandlerResult.succeeded(
        {"task": context.task.id, "attempt": context.attempt},
        completed_checks=context.task.completion_checks,
        guard_satisfied=context.task.guard_required,
        validation_level="STATICALLY_VALIDATED",
    )


class ExecutorFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.path = Path(self.directory.name) / "orchestrator.sqlite3"
        self.journal = SQLiteJournal(self.path)

    def tearDown(self) -> None:
        self.journal.close()
        self.directory.cleanup()

    def executor(
        self,
        tasks: tuple[TaskSpec, ...],
        handlers: HandlerRegistry,
        *,
        campaign: str = "campaign-1",
        worker: str = "worker-1",
        policy: ExecutionPolicy | None = None,
    ) -> DurableDagExecutor:
        return DurableDagExecutor(
            tasks=tasks,
            plan_sha256=PLAN_HASH,
            campaign_id=campaign,
            worker_id=worker,
            journal=self.journal,
            handlers=handlers,
            policy=policy,
        )


class DurableExecutionTests(ExecutorFixture):
    def test_registered_handlers_execute_in_dependency_order(self) -> None:
        order: list[str] = []
        registry = HandlerRegistry()

        def ordered(context) -> HandlerResult:
            order.append(context.task.id)
            context.checkpoint({"phase": "written"})
            return success(context)

        registry.register_stage(
            CampaignStage.BUILDING,
            ordered,
            version="1",
            replay_safe=True,
        )
        executor = self.executor((task("build"), task("measure", "build")), registry)

        report = executor.run()

        self.assertTrue(report.all_succeeded)
        self.assertEqual(order, ["build", "measure"])
        self.assertFalse(report.authorizes_release)
        self.assertEqual(report.validation_level, "NOT_VALIDATED")
        self.assertEqual(
            [event.kind for event in self.journal.events("campaign-1") if "TASK" in event.kind],
            [
                "TASK_STARTED",
                "TASK_PROGRESS_CHECKPOINTED",
                "TASK_SUCCEEDED",
                "TASK_STARTED",
                "TASK_PROGRESS_CHECKPOINTED",
                "TASK_SUCCEEDED",
            ],
        )

    def test_missing_handler_is_unsupported_and_transitively_blocks_dependants(self) -> None:
        registry = HandlerRegistry()
        registry.register_task("implemented", success, version="1", replay_safe=True)
        registry.register_task("downstream", success, version="1", replay_safe=True)
        executor = self.executor(
            (
                task("implemented"),
                task("missing", "implemented"),
                task("downstream", "missing"),
            ),
            registry,
        )

        report = executor.run()
        states = {item.task_id: item for item in report.tasks}

        self.assertIs(states["implemented"].status, TaskStatus.SUCCEEDED)
        self.assertIs(states["missing"].status, TaskStatus.UNSUPPORTED)
        self.assertEqual(states["missing"].error_code, "NO_REGISTERED_HANDLER")
        self.assertIs(states["downstream"].status, TaskStatus.BLOCKED)
        self.assertEqual(states["downstream"].error_code, "DEPENDENCY_NOT_SUCCEEDED")

    def test_successful_idempotency_key_is_replayed_without_calling_handler(self) -> None:
        calls = 0
        registry = HandlerRegistry()

        def counted(context) -> HandlerResult:
            nonlocal calls
            calls += 1
            return success(context)

        registry.register_task("only", counted, version="v1", replay_safe=True)
        first = self.executor((task("only"),), registry)
        self.assertTrue(first.run().all_succeeded)

        # Process-style reconstruction over the same durable journal.
        second = self.executor((task("only"),), registry, worker="worker-2")
        self.assertTrue(second.run().all_succeeded)
        self.assertEqual(calls, 1)

    def test_retryable_failure_is_retried_and_attempts_are_durable(self) -> None:
        calls = 0
        registry = HandlerRegistry()

        def flaky(context) -> HandlerResult:
            nonlocal calls
            calls += 1
            if calls == 1:
                return HandlerResult.failed("TEMPORARY", "try again", retryable=True)
            return success(context)

        registry.register_task(
            "flaky",
            flaky,
            version="1",
            replay_safe=True,
            max_attempts=2,
        )

        report = self.executor((task("flaky"),), registry).run()
        state = report.tasks[0]

        self.assertIs(state.status, TaskStatus.SUCCEEDED)
        self.assertEqual(state.attempt, 2)
        self.assertEqual(calls, 2)
        task_events = [
            event.kind for event in self.journal.events("campaign-1") if event.kind.startswith("TASK_")
        ]
        self.assertEqual(
            task_events,
            ["TASK_STARTED", "TASK_FAILED", "TASK_STARTED", "TASK_SUCCEEDED"],
        )

    def test_completion_checks_and_required_guard_are_enforced_by_executor(self) -> None:
        registry = HandlerRegistry()
        registry.register_task(
            "guarded",
            lambda _context: HandlerResult.succeeded(completed_checks=("output exists",)),
            version="1",
        )

        report = self.executor((task("guarded", guard=True),), registry).run()

        self.assertIs(report.tasks[0].status, TaskStatus.FAILED)
        self.assertEqual(report.tasks[0].error_code, "REQUIRED_GUARD_MISSING")

    def test_handler_cannot_succeed_without_all_declared_completion_checks(self) -> None:
        registry = HandlerRegistry()
        registry.register_task(
            "unchecked",
            lambda _context: HandlerResult.succeeded(),
            version="1",
        )

        report = self.executor((task("unchecked", checks=("proof exists",)),), registry).run()

        self.assertIs(report.tasks[0].status, TaskStatus.FAILED)
        self.assertEqual(report.tasks[0].error_code, "COMPLETION_CHECKS_MISSING")

    def test_timeout_is_uncertain_not_a_retryable_fake_failure(self) -> None:
        registry = HandlerRegistry()

        def ignores_cooperative_cancel(context) -> HandlerResult:
            time.sleep(0.15)
            return success(context)

        registry.register_task(
            "slow",
            ignores_cooperative_cancel,
            version="1",
            replay_safe=True,
        )
        registry.register_task("after", success, version="1", replay_safe=True)
        policy = ExecutionPolicy(
            max_attempts=3,
            timeout_seconds=0.02,
            lease_ttl_seconds=0.5,
            heartbeat_seconds=0.05,
            cancellation_grace_seconds=0.01,
        )

        report = self.executor((task("slow"), task("after", "slow")), registry, policy=policy).run()
        states = {item.task_id: item for item in report.tasks}

        self.assertIs(states["slow"].status, TaskStatus.UNCERTAIN)
        self.assertEqual(states["slow"].error_code, "HANDLER_TIMEOUT")
        self.assertEqual(states["slow"].attempt, 1)
        self.assertIs(states["after"].status, TaskStatus.BLOCKED)
        # A timed-out daemon may still be finishing.  Its task and product
        # fences are deliberately retained until lease expiry instead of being
        # released for a concurrent writer immediately.
        self.assertIsNotNone(self.journal.task_lease("campaign-1", "slow"))

    def test_durable_cancellation_prevents_handlers_from_starting(self) -> None:
        calls = 0
        registry = HandlerRegistry()

        def counted(context) -> HandlerResult:
            nonlocal calls
            calls += 1
            return success(context)

        registry.register_stage(CampaignStage.BUILDING, counted, version="1")
        executor = self.executor((task("one"), task("two", "one")), registry)
        executor.request_cancellation("operator stopped the campaign")

        report = executor.run()

        self.assertTrue(report.cancellation_requested)
        self.assertEqual(calls, 0)
        self.assertEqual({item.status for item in report.tasks}, {TaskStatus.CANCELLED})

    def test_live_resource_claim_stalls_another_campaign_without_false_failure(self) -> None:
        registry = HandlerRegistry()
        registry.register_task("studio", success, version="1")
        specification = task("studio", resources=("studio-window:shared",))
        self.journal.bind_campaign("campaign-1", PLAN_HASH)
        self.journal.acquire_task_lease(
            "__orchestrator_global_claims__",
            "resource:studio-window:shared",
            "another-campaign",
            ttl_seconds=30,
        )

        report = self.executor((specification,), registry).run()

        self.assertIs(report.tasks[0].status, TaskStatus.PENDING)
        self.assertTrue(any("another-campaign" in reason for reason in report.stall_reasons))

    def test_orphaned_running_task_is_uncertain_when_replay_was_not_declared_safe(self) -> None:
        registry = HandlerRegistry()
        registry.register_task("started", success, version="1", replay_safe=False)
        executor = self.executor((task("started"),), registry)
        self.journal.bind_campaign("campaign-1", PLAN_HASH)
        expired = self.journal.acquire_task_lease(
            "campaign-1", "started", "dead-worker", ttl_seconds=1, now=100.0
        )
        self.journal.record_task_checkpoint(
            expired,
            plan_sha256=PLAN_HASH,
            status=TaskStatus.RUNNING,
            attempt=1,
            handler_key="task:started",
            idempotency_key="unknown-after-crash",
            payload={"lastKnownStep": "mutating"},
            event_kind="TASK_STARTED",
            now=100.5,
        )

        report = executor.run()

        self.assertIs(report.tasks[0].status, TaskStatus.UNCERTAIN)
        self.assertEqual(report.tasks[0].error_code, "ORPHANED_RUNNING_TASK")

    def test_orphaned_running_task_resumes_only_when_matching_handler_declares_replay_safe(self) -> None:
        calls = 0
        registry = HandlerRegistry()

        def counted(context) -> HandlerResult:
            nonlocal calls
            calls += 1
            return success(context)

        specification = task("started")
        registry.register_task(
            "started", counted, version="1", replay_safe=True, max_attempts=2
        )
        idem_key = registry.idempotency_key(PLAN_HASH, specification)
        self.assertIsNotNone(idem_key)
        executor = self.executor((specification,), registry)
        self.journal.bind_campaign("campaign-1", PLAN_HASH)
        expired = self.journal.acquire_task_lease(
            "campaign-1", "started", "dead-worker", ttl_seconds=1, now=100.0
        )
        self.journal.record_task_checkpoint(
            expired,
            plan_sha256=PLAN_HASH,
            status=TaskStatus.RUNNING,
            attempt=1,
            handler_key="task:started",
            idempotency_key=idem_key,
            payload={"lastKnownStep": "safe boundary"},
            event_kind="TASK_STARTED",
            now=100.5,
        )

        report = executor.run()

        self.assertIs(report.tasks[0].status, TaskStatus.SUCCEEDED)
        self.assertEqual(report.tasks[0].attempt, 2)
        self.assertEqual(calls, 1)

    def test_handler_version_change_blocks_retry_instead_of_replaying_side_effect(self) -> None:
        first_registry = HandlerRegistry()
        first_registry.register_task(
            "versioned",
            lambda _context: HandlerResult.failed("TEMP", "retry later", retryable=True),
            version="1",
            max_attempts=1,
        )
        specification = task("versioned")
        first = self.executor((specification,), first_registry)
        self.assertIs(first.run().tasks[0].status, TaskStatus.FAILED)

        second_registry = HandlerRegistry()
        second_registry.register_task(
            "versioned", success, version="2", replay_safe=True, max_attempts=2
        )
        second = self.executor((specification,), second_registry, worker="worker-2")
        report = second.run()

        self.assertIs(report.tasks[0].status, TaskStatus.BLOCKED)
        self.assertEqual(report.tasks[0].error_code, "IDEMPOTENCY_KEY_MISMATCH")


class DurableJournalProtocolTests(ExecutorFixture):
    def test_fence_increases_and_stale_worker_cannot_checkpoint(self) -> None:
        self.journal.bind_campaign("campaign-1", PLAN_HASH)
        first = self.journal.acquire_task_lease(
            "campaign-1", "build", "worker-1", ttl_seconds=10, now=100.0
        )
        with self.assertRaises(LeaseUnavailable):
            self.journal.acquire_task_lease(
                "campaign-1", "build", "worker-2", ttl_seconds=10, now=101.0
            )
        self.journal.record_task_checkpoint(
            first,
            plan_sha256=PLAN_HASH,
            status=TaskStatus.RUNNING,
            attempt=1,
            handler_key="task:build",
            idempotency_key="first",
            now=101.0,
        )
        self.journal.release_task_lease(first, now=102.0)
        second = self.journal.acquire_task_lease(
            "campaign-1", "build", "worker-2", ttl_seconds=10, now=103.0
        )

        self.assertGreater(second.fence_token, first.fence_token)
        with self.assertRaises(StaleFenceError):
            self.journal.record_task_checkpoint(
                first,
                plan_sha256=PLAN_HASH,
                status=TaskStatus.SUCCEEDED,
                attempt=1,
                handler_key="task:build",
                idempotency_key="first",
                now=104.0,
            )

    def test_campaign_id_cannot_resume_against_a_different_plan(self) -> None:
        self.journal.bind_campaign("campaign-1", PLAN_HASH)

        with self.assertRaises(CampaignBindingError):
            self.journal.bind_campaign("campaign-1", "b" * 64)

    def test_live_scheduler_lease_returns_a_typed_stall_without_executing(self) -> None:
        registry = HandlerRegistry()
        calls = 0

        def counted(context) -> HandlerResult:
            nonlocal calls
            calls += 1
            return success(context)

        registry.register_task("only", counted, version="1")
        self.journal.bind_campaign("campaign-1", PLAN_HASH)
        self.journal.acquire_task_lease(
            "campaign-1", "__scheduler__", "other-worker", ttl_seconds=30
        )

        report = self.executor((task("only"),), registry).run()

        self.assertFalse(report.scheduler_acquired)
        self.assertIs(report.tasks[0].status, TaskStatus.PENDING)
        self.assertTrue(report.stall_reasons)
        self.assertEqual(calls, 0)


if __name__ == "__main__":
    unittest.main()
