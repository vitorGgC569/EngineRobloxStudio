"""Durable, fail-closed execution of compiled production DAGs.

The executor runs only handlers explicitly registered by its caller.  It does
not discover agents, invoke an LLM, open Studio, or infer that an intent string
is executable.  A plan task without a handler is ``UNSUPPORTED`` and blocks
its dependants.

This is control-plane execution, not release evidence.  A fully successful
report therefore still has ``authorizes_release=False`` and
``validation_level=NOT_VALIDATED``.  Individual handlers may write real,
separately validated artifacts, but their release authority belongs to the
immutable release gate rather than this scheduler.
"""

from __future__ import annotations

import hashlib
import json
import queue
import threading
import time
import uuid
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from typing import Any

from rqe.models import VALIDATION_LEVELS

from .blueprint import ProductionPlan
from .dag import TaskGraph
from .journal import (
    LeaseUnavailable,
    SQLiteJournal,
    StaleFenceError,
    TaskCheckpoint,
    TaskLease,
)
from .models import CampaignStage, TaskSpec, TaskStatus
from .ownership import OwnershipRegistry


_TERMINAL_HANDLER_STATUSES = frozenset(
    {
        TaskStatus.SUCCEEDED,
        TaskStatus.FAILED,
        TaskStatus.BLOCKED,
        TaskStatus.UNSUPPORTED,
        TaskStatus.UNCERTAIN,
        TaskStatus.CANCELLED,
    }
)
_FINAL_TASK_STATUSES = _TERMINAL_HANDLER_STATUSES


class ExecutorError(RuntimeError):
    """The control plane cannot safely execute or resume this campaign."""


class HandlerRegistrationError(ValueError):
    pass


class HandlerCancelled(RuntimeError):
    """Cooperative cancellation raised by ``TaskExecutionContext``."""


@dataclass(frozen=True)
class HandlerResult:
    """Typed result returned by every deterministic task handler."""

    status: TaskStatus
    payload: dict[str, Any] = field(default_factory=dict)
    completed_checks: tuple[str, ...] = ()
    blockers: tuple[str, ...] = ()
    error_code: str | None = None
    message: str | None = None
    retryable: bool = False
    guard_satisfied: bool = False
    validation_level: str = "NOT_VALIDATED"

    def __post_init__(self) -> None:
        if self.status not in _TERMINAL_HANDLER_STATUSES:
            raise ValueError(f"handler cannot return non-terminal status {self.status.value}")
        if not isinstance(self.payload, dict):
            raise ValueError("handler payload must be an object")
        # Fail before execution records an outcome it cannot replay.
        json.dumps(self.payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        if self.validation_level not in VALIDATION_LEVELS:
            raise ValueError(f"invalid validation level: {self.validation_level!r}")
        if any(not isinstance(item, str) or not item.strip() for item in self.completed_checks):
            raise ValueError("completed_checks entries must be non-empty strings")
        if any(not isinstance(item, str) or not item.strip() for item in self.blockers):
            raise ValueError("blockers entries must be non-empty strings")
        if self.retryable and self.status is not TaskStatus.FAILED:
            raise ValueError("only FAILED handler results may be retryable")
        if self.status is TaskStatus.SUCCEEDED:
            if self.error_code is not None or self.blockers:
                raise ValueError("a successful handler result cannot carry errors or blockers")
        elif not self.error_code:
            raise ValueError(f"{self.status.value} handler result requires an error_code")

    @classmethod
    def succeeded(
        cls,
        payload: Mapping[str, Any] | None = None,
        *,
        completed_checks: Iterable[str] = (),
        guard_satisfied: bool = False,
        validation_level: str = "NOT_VALIDATED",
    ) -> "HandlerResult":
        return cls(
            status=TaskStatus.SUCCEEDED,
            payload=dict(payload or {}),
            completed_checks=tuple(completed_checks),
            guard_satisfied=guard_satisfied,
            validation_level=validation_level,
        )

    @classmethod
    def failed(
        cls,
        error_code: str,
        message: str,
        *,
        retryable: bool = False,
        payload: Mapping[str, Any] | None = None,
    ) -> "HandlerResult":
        return cls(
            status=TaskStatus.FAILED,
            payload=dict(payload or {}),
            error_code=error_code,
            message=message,
            retryable=retryable,
        )

    @classmethod
    def blocked(
        cls,
        error_code: str,
        message: str,
        *,
        blockers: Iterable[str] = (),
        payload: Mapping[str, Any] | None = None,
    ) -> "HandlerResult":
        return cls(
            status=TaskStatus.BLOCKED,
            payload=dict(payload or {}),
            blockers=tuple(blockers) or (message,),
            error_code=error_code,
            message=message,
        )

    @classmethod
    def unsupported(cls, message: str, *, error_code: str = "UNSUPPORTED") -> "HandlerResult":
        return cls(
            status=TaskStatus.UNSUPPORTED,
            blockers=(message,),
            error_code=error_code,
            message=message,
        )

    @classmethod
    def uncertain(
        cls,
        error_code: str,
        message: str,
        *,
        payload: Mapping[str, Any] | None = None,
    ) -> "HandlerResult":
        return cls(
            status=TaskStatus.UNCERTAIN,
            payload=dict(payload or {}),
            blockers=(message,),
            error_code=error_code,
            message=message,
        )

    @classmethod
    def cancelled(cls, message: str = "handler cooperatively cancelled") -> "HandlerResult":
        return cls(
            status=TaskStatus.CANCELLED,
            blockers=(message,),
            error_code="CANCELLED",
            message=message,
        )


TaskHandler = Callable[["TaskExecutionContext"], HandlerResult]


@dataclass(frozen=True)
class HandlerRegistration:
    key: str
    handler: TaskHandler
    version: str
    replay_safe: bool = False
    retry_exceptions: bool = False
    max_attempts: int | None = None
    timeout_seconds: float | None = None

    def __post_init__(self) -> None:
        if not self.key.strip():
            raise HandlerRegistrationError("handler key must not be empty")
        if not callable(self.handler):
            raise HandlerRegistrationError(f"handler {self.key!r} is not callable")
        if not self.version.strip():
            raise HandlerRegistrationError(f"handler {self.key!r} needs an explicit version")
        if self.max_attempts is not None and self.max_attempts < 1:
            raise HandlerRegistrationError("handler max_attempts must be positive")
        if self.timeout_seconds is not None and self.timeout_seconds <= 0:
            raise HandlerRegistrationError("handler timeout_seconds must be positive")


class HandlerRegistry:
    """Explicit deterministic routing from task attributes to handlers.

    Resolution is strict and stable: exact task id, capability, role, then
    stage.  Merely resembling an intent string never makes a task executable.
    """

    def __init__(self) -> None:
        self._registrations: dict[str, HandlerRegistration] = {}

    def register(
        self,
        key: str,
        handler: TaskHandler,
        *,
        version: str,
        replay_safe: bool = False,
        retry_exceptions: bool = False,
        max_attempts: int | None = None,
        timeout_seconds: float | None = None,
    ) -> HandlerRegistration:
        if key in self._registrations:
            raise HandlerRegistrationError(f"handler key already registered: {key!r}")
        registration = HandlerRegistration(
            key=key,
            handler=handler,
            version=version,
            replay_safe=replay_safe,
            retry_exceptions=retry_exceptions,
            max_attempts=max_attempts,
            timeout_seconds=timeout_seconds,
        )
        self._registrations[key] = registration
        return registration

    def register_task(self, task_id: str, handler: TaskHandler, **options: Any) -> HandlerRegistration:
        return self.register(f"task:{task_id}", handler, **options)

    def register_capability(
        self, capability: str, handler: TaskHandler, **options: Any
    ) -> HandlerRegistration:
        return self.register(f"capability:{capability}", handler, **options)

    def register_role(self, role: str, handler: TaskHandler, **options: Any) -> HandlerRegistration:
        return self.register(f"role:{role}", handler, **options)

    def register_stage(
        self, stage: CampaignStage, handler: TaskHandler, **options: Any
    ) -> HandlerRegistration:
        if not isinstance(stage, CampaignStage):
            raise HandlerRegistrationError(f"invalid campaign stage: {stage!r}")
        return self.register(f"stage:{stage.value}", handler, **options)

    def resolve(self, task: TaskSpec) -> HandlerRegistration | None:
        candidates = [f"task:{task.id}"]
        capability = task.metadata.get("capability")
        if isinstance(capability, str) and capability.strip():
            candidates.append(f"capability:{capability}")
        candidates.extend((f"role:{task.role}", f"stage:{task.stage.value}"))
        for key in candidates:
            registration = self._registrations.get(key)
            if registration is not None:
                return registration
        return None

    def idempotency_key(self, plan_sha256: str, task: TaskSpec) -> str | None:
        """Return the exact key the executor will pass to this task's handler."""

        registration = self.resolve(task)
        return (
            None
            if registration is None
            else _idempotency_key(plan_sha256, task, registration)
        )

    def keys(self) -> tuple[str, ...]:
        return tuple(sorted(self._registrations))


@dataclass(frozen=True)
class ExecutionPolicy:
    max_attempts: int = 3
    timeout_seconds: float = 300.0
    lease_ttl_seconds: float = 30.0
    heartbeat_seconds: float = 5.0
    cancellation_grace_seconds: float = 1.0
    retry_backoff_seconds: float = 0.0

    def __post_init__(self) -> None:
        if self.max_attempts < 1:
            raise ValueError("max_attempts must be positive")
        if self.timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if self.lease_ttl_seconds <= 0:
            raise ValueError("lease_ttl_seconds must be positive")
        if self.heartbeat_seconds <= 0 or self.heartbeat_seconds >= self.lease_ttl_seconds:
            raise ValueError("heartbeat_seconds must be positive and shorter than the lease TTL")
        if self.cancellation_grace_seconds < 0:
            raise ValueError("cancellation_grace_seconds must be non-negative")
        if self.retry_backoff_seconds < 0:
            raise ValueError("retry_backoff_seconds must be non-negative")


class TaskExecutionContext:
    """Fenced, checkpoint-capable context passed to one registered handler."""

    def __init__(
        self,
        *,
        campaign_id: str,
        plan_sha256: str,
        task: TaskSpec,
        attempt: int,
        handler_key: str,
        idempotency_key: str,
        journal: SQLiteJournal,
        lease: TaskLease,
        lease_ttl_seconds: float,
        cancel_event: threading.Event,
    ) -> None:
        self.campaign_id = campaign_id
        self.plan_sha256 = plan_sha256
        self.task = task
        self.attempt = attempt
        self.handler_key = handler_key
        self.idempotency_key = idempotency_key
        self.fence_token = lease.fence_token
        self._journal = journal
        self._lease = lease
        self._lease_ttl_seconds = lease_ttl_seconds
        self._cancel_event = cancel_event
        self._lease_lock = threading.RLock()

    @property
    def cancellation_requested(self) -> bool:
        requested, _reason = self._journal.cancellation(self.campaign_id)
        return self._cancel_event.is_set() or requested

    def raise_if_cancelled(self) -> None:
        if self.cancellation_requested:
            raise HandlerCancelled(f"campaign {self.campaign_id!r} was cancelled")

    def heartbeat(self) -> int:
        """Renew this task lease or fail if a newer worker owns its fence."""

        with self._lease_lock:
            self._lease = self._journal.renew_task_lease(
                self._lease, ttl_seconds=self._lease_ttl_seconds
            )
            return self._lease.fence_token

    def checkpoint(self, payload: Mapping[str, Any]) -> TaskCheckpoint:
        """Persist resumability state without claiming that the task succeeded."""

        with self._lease_lock:
            return self._journal.record_task_checkpoint(
                self._lease,
                plan_sha256=self.plan_sha256,
                status=TaskStatus.RUNNING,
                attempt=self.attempt,
                handler_key=self.handler_key,
                idempotency_key=self.idempotency_key,
                payload=dict(payload),
                event_kind="TASK_PROGRESS_CHECKPOINTED",
            )

    def _replace_lease(self, lease: TaskLease) -> None:
        with self._lease_lock:
            self._lease = lease


@dataclass(frozen=True)
class TaskExecutionState:
    task_id: str
    status: TaskStatus
    attempt: int
    handler_key: str | None
    error_code: str | None
    message: str | None
    retryable: bool

    def to_dict(self) -> dict[str, Any]:
        return {
            "taskId": self.task_id,
            "status": self.status.value,
            "attempt": self.attempt,
            "handlerKey": self.handler_key,
            "errorCode": self.error_code,
            "message": self.message,
            "retryable": self.retryable,
        }


@dataclass(frozen=True)
class CampaignExecutionReport:
    campaign_id: str
    plan_sha256: str
    tasks: tuple[TaskExecutionState, ...]
    scheduler_acquired: bool
    cancellation_requested: bool
    stall_reasons: tuple[str, ...]
    validation_level: str = "NOT_VALIDATED"
    authorizes_release: bool = False

    @property
    def all_succeeded(self) -> bool:
        return bool(self.tasks) and all(item.status is TaskStatus.SUCCEEDED for item in self.tasks)

    @property
    def finished(self) -> bool:
        return bool(self.tasks) and all(item.status in _FINAL_TASK_STATUSES for item in self.tasks)

    def to_dict(self) -> dict[str, Any]:
        return {
            "campaignId": self.campaign_id,
            "planSha256": self.plan_sha256,
            "tasks": [item.to_dict() for item in self.tasks],
            "allSucceeded": self.all_succeeded,
            "finished": self.finished,
            "schedulerAcquired": self.scheduler_acquired,
            "cancellationRequested": self.cancellation_requested,
            "stallReasons": list(self.stall_reasons),
            "validationLevel": self.validation_level,
            "authorizesRelease": self.authorizes_release,
            "note": "control-plane execution is not release evidence",
        }


@dataclass
class _InvocationState:
    scheduler_lease: TaskLease
    task_lease: TaskLease
    claim_leases: list[TaskLease]


def _canonical_task_payload(task: TaskSpec) -> dict[str, Any]:
    return {
        "id": task.id,
        "stage": task.stage.value,
        "role": task.role,
        "intent": task.intent,
        "blockedBy": list(task.blocked_by),
        "readSet": list(task.read_set),
        "writeSet": list(task.write_set),
        "resourceClaims": list(task.resource_claims),
        "completionChecks": list(task.completion_checks),
        "guardRequired": task.guard_required,
        "metadata": task.metadata,
    }


def _idempotency_key(
    plan_sha256: str, task: TaskSpec, registration: HandlerRegistration
) -> str:
    encoded = json.dumps(
        {
            "planSha256": plan_sha256,
            "task": _canonical_task_payload(task),
            "handlerKey": registration.key,
            "handlerVersion": registration.version,
        },
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


class DurableDagExecutor:
    """Serial durable scheduler for an immutable, compiled task graph.

    A durable campaign lease gives one scheduler ownership of a campaign.  A
    second product-scoped lease prevents another campaign from mutating the
    same product concurrently.  The serial policy is deliberate for this first
    executor: parallelism can be added later without weakening the checkpoint
    and fencing protocol.
    """

    _SCHEDULER_TASK = "__scheduler__"
    _GLOBAL_CAMPAIGN = "__orchestrator_global_claims__"

    def __init__(
        self,
        *,
        tasks: Iterable[TaskSpec],
        plan_sha256: str,
        campaign_id: str,
        worker_id: str,
        journal: SQLiteJournal,
        handlers: HandlerRegistry,
        policy: ExecutionPolicy | None = None,
    ) -> None:
        if not isinstance(plan_sha256, str) or len(plan_sha256) != 64:
            raise ValueError("plan_sha256 must be a 64-character digest")
        if not isinstance(campaign_id, str) or not campaign_id.strip():
            raise ValueError("campaign_id must not be empty")
        if not isinstance(worker_id, str) or not worker_id.strip():
            raise ValueError("worker_id must not be empty")
        self.graph = TaskGraph(tuple(tasks))
        self.plan_sha256 = plan_sha256
        self.campaign_id = campaign_id
        self.worker_id = worker_id
        # Worker labels are useful diagnostics but are not process identities.
        # A per-executor nonce prevents two restarted processes that reuse the
        # same label from being mistaken for one lease owner.
        self._lease_owner_id = f"{worker_id}:{uuid.uuid4().hex}"
        self.journal = journal
        self.handlers = handlers
        self.policy = policy or ExecutionPolicy()
        self._task_by_id = {task.id: task for task in self.graph.tasks}
        self._ownership = OwnershipRegistry()

    @classmethod
    def from_plan(
        cls,
        plan: ProductionPlan,
        *,
        campaign_id: str,
        worker_id: str,
        journal: SQLiteJournal,
        handlers: HandlerRegistry,
        policy: ExecutionPolicy | None = None,
    ) -> "DurableDagExecutor":
        if not isinstance(plan, ProductionPlan):
            raise TypeError("plan must be a compiled ProductionPlan")
        return cls(
            tasks=(task for project in plan.projects for task in project.tasks),
            plan_sha256=plan.sha256,
            campaign_id=campaign_id,
            worker_id=worker_id,
            journal=journal,
            handlers=handlers,
            policy=policy,
        )

    def request_cancellation(self, reason: str) -> None:
        self.journal.bind_campaign(self.campaign_id, self.plan_sha256)
        self.journal.request_cancellation(self.campaign_id, reason)

    def inspect(self) -> CampaignExecutionReport:
        self.journal.bind_campaign(self.campaign_id, self.plan_sha256)
        return self._report(scheduler_acquired=False, stall_reasons=())

    def run(self, *, max_tasks: int | None = None) -> CampaignExecutionReport:
        if max_tasks is not None and max_tasks < 1:
            raise ValueError("max_tasks must be positive")
        self.journal.bind_campaign(self.campaign_id, self.plan_sha256)
        try:
            scheduler_lease = self.journal.acquire_task_lease(
                self.campaign_id,
                self._SCHEDULER_TASK,
                self._lease_owner_id,
                ttl_seconds=self.policy.lease_ttl_seconds,
            )
        except LeaseUnavailable as exc:
            return self._report(scheduler_acquired=False, stall_reasons=(str(exc),))

        stall_reasons: list[str] = []
        executed = 0
        try:
            recovery_stalls = self._recover_incomplete()
            stall_reasons.extend(recovery_stalls)
            while not recovery_stalls:
                requested, reason = self.journal.cancellation(self.campaign_id)
                if requested:
                    self._cancel_pending(reason or "campaign cancellation requested")
                    break

                self._propagate_dependency_failures()
                statuses = self._statuses()
                ready = self.graph.ready_tasks(statuses)
                if not ready:
                    break

                for task in ready:
                    if max_tasks is not None and executed >= max_tasks:
                        stall_reasons.append("max_tasks limit reached")
                        break
                    scheduler_lease = self.journal.renew_task_lease(
                        scheduler_lease, ttl_seconds=self.policy.lease_ttl_seconds
                    )
                    try:
                        self._execute_task(task, scheduler_lease)
                    except LeaseUnavailable as exc:
                        stall_reasons.append(str(exc))
                        break
                    executed += 1
                    requested, _reason = self.journal.cancellation(self.campaign_id)
                    if requested:
                        break
                else:
                    continue
                break

            self._propagate_dependency_failures()
            statuses = self._statuses()
            if not all(status is TaskStatus.SUCCEEDED for status in statuses.values()):
                pending = sorted(task_id for task_id, status in statuses.items() if status is TaskStatus.PENDING)
                if pending and not stall_reasons:
                    stall_reasons.append("no runnable tasks remain: " + ", ".join(pending))
        finally:
            try:
                self.journal.release_task_lease(scheduler_lease)
            except StaleFenceError:
                # Losing the scheduler fence is already reflected by task-level
                # uncertainty; never overwrite a newer worker's lease.
                pass
        return self._report(scheduler_acquired=True, stall_reasons=tuple(stall_reasons))

    def _statuses(self) -> dict[str, TaskStatus]:
        checkpoints = {item.task_id: item for item in self.journal.task_checkpoints(self.campaign_id)}
        unknown = sorted(set(checkpoints) - set(self._task_by_id))
        if unknown:
            raise ExecutorError(
                "campaign contains checkpoints for tasks outside this plan: " + ", ".join(unknown)
            )
        for checkpoint in checkpoints.values():
            if checkpoint.plan_sha256 != self.plan_sha256:
                raise ExecutorError(
                    f"task {checkpoint.task_id!r} checkpoint belongs to another plan"
                )
        return {
            task.id: checkpoints.get(task.id).status if task.id in checkpoints else TaskStatus.PENDING
            for task in self.graph.tasks
        }

    def _recover_incomplete(self) -> tuple[str, ...]:
        stalls: list[str] = []
        for checkpoint in self.journal.task_checkpoints(self.campaign_id):
            if checkpoint.task_id not in self._task_by_id:
                raise ExecutorError(f"unknown checkpoint task {checkpoint.task_id!r}")
            task = self._task_by_id[checkpoint.task_id]
            registration = self.handlers.resolve(task)
            max_attempts = self._max_attempts(registration)
            expected_key = (
                _idempotency_key(self.plan_sha256, task, registration)
                if registration is not None
                else None
            )

            if checkpoint.status is TaskStatus.RUNNING:
                current = self.journal.task_lease(self.campaign_id, task.id)
                if current is not None and current.is_current():
                    stalls.append(f"task {task.id!r} still has a live lease owned by {current.owner_id!r}")
                    continue
                lease = self._acquire_task_lease(task)
                try:
                    can_replay = (
                        registration is not None
                        and registration.replay_safe
                        and checkpoint.idempotency_key == expected_key
                        and checkpoint.attempt < max_attempts
                    )
                    if can_replay:
                        self.journal.record_task_checkpoint(
                            lease,
                            plan_sha256=self.plan_sha256,
                            status=TaskStatus.PENDING,
                            attempt=checkpoint.attempt,
                            handler_key=registration.key,
                            idempotency_key=expected_key,
                            payload={"recoveredFrom": "RUNNING"},
                            retryable=True,
                            event_kind="TASK_RECOVERED_FOR_RETRY",
                        )
                    else:
                        self.journal.record_task_checkpoint(
                            lease,
                            plan_sha256=self.plan_sha256,
                            status=TaskStatus.UNCERTAIN,
                            attempt=checkpoint.attempt,
                            handler_key=checkpoint.handler_key,
                            idempotency_key=checkpoint.idempotency_key,
                            payload=checkpoint.payload,
                            error_code="ORPHANED_RUNNING_TASK",
                            error_message=(
                                "the worker disappeared after the task started; effects cannot be "
                                "replayed safely"
                            ),
                            event_kind="TASK_BECAME_UNCERTAIN",
                        )
                finally:
                    self.journal.release_task_lease(lease)

            elif checkpoint.status is TaskStatus.FAILED and checkpoint.retryable:
                if (
                    registration is not None
                    and checkpoint.idempotency_key == expected_key
                    and checkpoint.attempt < max_attempts
                ):
                    lease = self._acquire_task_lease(task)
                    try:
                        self.journal.record_task_checkpoint(
                            lease,
                            plan_sha256=self.plan_sha256,
                            status=TaskStatus.PENDING,
                            attempt=checkpoint.attempt,
                            handler_key=registration.key,
                            idempotency_key=expected_key,
                            payload={"recoveredFrom": "FAILED"},
                            retryable=True,
                            event_kind="TASK_RETRY_RESUMED",
                        )
                    finally:
                        self.journal.release_task_lease(lease)
                elif checkpoint.idempotency_key != expected_key:
                    self._block_idempotency_mismatch(task, checkpoint, expected_key)
        return tuple(stalls)

    def _propagate_dependency_failures(self) -> None:
        while True:
            statuses = self._statuses()
            blocked = self.graph.blocked_by_failure(statuses)
            if not blocked:
                return
            for task_id, dependencies in sorted(blocked.items()):
                task = self._task_by_id[task_id]
                lease = self._acquire_task_lease(task)
                try:
                    self.journal.record_task_checkpoint(
                        lease,
                        plan_sha256=self.plan_sha256,
                        status=TaskStatus.BLOCKED,
                        attempt=0,
                        handler_key=None,
                        idempotency_key=None,
                        payload={"failedDependencies": list(dependencies)},
                        error_code="DEPENDENCY_NOT_SUCCEEDED",
                        error_message="dependency did not succeed: " + ", ".join(dependencies),
                        event_kind="TASK_BLOCKED_BY_DEPENDENCY",
                    )
                finally:
                    self.journal.release_task_lease(lease)

    def _cancel_pending(self, reason: str) -> None:
        for task in self.graph.tasks:
            if self._statuses()[task.id] is not TaskStatus.PENDING:
                continue
            lease = self._acquire_task_lease(task)
            try:
                self.journal.record_task_checkpoint(
                    lease,
                    plan_sha256=self.plan_sha256,
                    status=TaskStatus.CANCELLED,
                    attempt=0,
                    handler_key=None,
                    idempotency_key=None,
                    payload={},
                    error_code="CAMPAIGN_CANCELLED",
                    error_message=reason,
                    event_kind="TASK_CANCELLED",
                )
            finally:
                self.journal.release_task_lease(lease)

    def _execute_task(self, task: TaskSpec, scheduler_lease: TaskLease) -> None:
        registration = self.handlers.resolve(task)
        task_lease = self._acquire_task_lease(task)
        claim_leases: list[TaskLease] = []
        ownership_acquired = False
        preserve_fenced_leases = False
        try:
            if task.write_set:
                self._ownership.acquire(task.id, task.write_set)
                ownership_acquired = True
            claim_leases = self._acquire_global_claims(task)

            if registration is None:
                self.journal.record_task_checkpoint(
                    task_lease,
                    plan_sha256=self.plan_sha256,
                    status=TaskStatus.UNSUPPORTED,
                    attempt=0,
                    handler_key=None,
                    idempotency_key=None,
                    payload={"resolutionOrder": ["task", "capability", "role", "stage"]},
                    error_code="NO_REGISTERED_HANDLER",
                    error_message=f"no deterministic handler is registered for task {task.id!r}",
                    event_kind="TASK_UNSUPPORTED",
                )
                return

            idem_key = _idempotency_key(self.plan_sha256, task, registration)
            existing = self.journal.task_checkpoint(self.campaign_id, task.id)
            if existing is not None and existing.idempotency_key not in {None, idem_key}:
                self._record_idempotency_mismatch(task_lease, task, existing, idem_key)
                return
            if existing is not None and existing.status is TaskStatus.SUCCEEDED:
                # A completed idempotency key is replayed from durable state,
                # never by calling the handler a second time.
                return

            attempt = 0 if existing is None else existing.attempt
            max_attempts = self._max_attempts(registration)
            while attempt < max_attempts:
                attempt += 1
                self.journal.record_task_checkpoint(
                    task_lease,
                    plan_sha256=self.plan_sha256,
                    status=TaskStatus.RUNNING,
                    attempt=attempt,
                    handler_key=registration.key,
                    idempotency_key=idem_key,
                    payload={},
                    event_kind="TASK_STARTED",
                )
                cancel_event = threading.Event()
                context = TaskExecutionContext(
                    campaign_id=self.campaign_id,
                    plan_sha256=self.plan_sha256,
                    task=task,
                    attempt=attempt,
                    handler_key=registration.key,
                    idempotency_key=idem_key,
                    journal=self.journal,
                    lease=task_lease,
                    lease_ttl_seconds=self.policy.lease_ttl_seconds,
                    cancel_event=cancel_event,
                )
                active = _InvocationState(scheduler_lease, task_lease, claim_leases)
                result, active = self._invoke_handler(registration, context, active, cancel_event)
                scheduler_lease = active.scheduler_lease
                task_lease = active.task_lease
                claim_leases = active.claim_leases
                context._replace_lease(task_lease)
                result = self._enforce_completion_contract(task, result)
                self._record_result(task_lease, registration, idem_key, attempt, result)
                preserve_fenced_leases = result.status is TaskStatus.UNCERTAIN and result.error_code in {
                    "HANDLER_TIMEOUT",
                    "CANCELLATION_UNCONFIRMED",
                    "LEASE_LOST",
                }
                if not (result.status is TaskStatus.FAILED and result.retryable and attempt < max_attempts):
                    return
                if self.policy.retry_backoff_seconds:
                    if self._wait_for_retry_or_cancel(self.policy.retry_backoff_seconds):
                        return
        finally:
            if not preserve_fenced_leases:
                for claim in reversed(claim_leases):
                    try:
                        self.journal.release_task_lease(claim)
                    except StaleFenceError:
                        pass
            if ownership_acquired:
                self._ownership.release(task.id)
            if not preserve_fenced_leases:
                try:
                    self.journal.release_task_lease(task_lease)
                except StaleFenceError:
                    pass

    def _invoke_handler(
        self,
        registration: HandlerRegistration,
        context: TaskExecutionContext,
        active: _InvocationState,
        cancel_event: threading.Event,
    ) -> tuple[HandlerResult, _InvocationState]:
        responses: queue.Queue[tuple[str, Any]] = queue.Queue(maxsize=1)

        def worker() -> None:
            try:
                result = registration.handler(context)
                if not isinstance(result, HandlerResult):
                    raise TypeError(
                        f"handler {registration.key!r} returned {type(result).__name__}, "
                        "expected HandlerResult"
                    )
                responses.put(("result", result))
            except HandlerCancelled as exc:
                responses.put(("result", HandlerResult.cancelled(str(exc))))
            except Exception as exc:  # noqa: BLE001 - converted to a typed fail-closed result
                responses.put(("exception", exc))

        thread = threading.Thread(
            target=worker,
            name=f"rqe-task-{context.task.id}",
            daemon=True,
        )
        thread.start()
        started = time.monotonic()
        timeout = registration.timeout_seconds or self.policy.timeout_seconds
        deadline = started + timeout
        next_heartbeat = started + self.policy.heartbeat_seconds
        cancellation_started: float | None = None
        deadline_exceeded = False

        while True:
            now = time.monotonic()
            wait_until = min(deadline, next_heartbeat)
            if cancellation_started is not None:
                wait_until = min(
                    wait_until, cancellation_started + self.policy.cancellation_grace_seconds
                )
            wait_seconds = max(0.001, wait_until - now)
            try:
                kind, value = responses.get(timeout=wait_seconds)
                if deadline_exceeded:
                    return (
                        HandlerResult.uncertain(
                            "HANDLER_TIMEOUT",
                            f"handler {registration.key!r} returned after its {timeout}s deadline",
                            payload={"lateResultKind": kind},
                        ),
                        active,
                    )
                if kind == "result":
                    return value, active
                exception = value
                return (
                    HandlerResult.failed(
                        "HANDLER_EXCEPTION",
                        f"{type(exception).__name__}: {exception}",
                        retryable=registration.retry_exceptions,
                        payload={"exceptionType": type(exception).__name__},
                    ),
                    active,
                )
            except queue.Empty:
                pass

            now = time.monotonic()
            if now >= next_heartbeat:
                try:
                    active = self._renew_invocation_leases(active)
                    context._replace_lease(active.task_lease)
                except StaleFenceError as exc:
                    cancel_event.set()
                    return (
                        HandlerResult.uncertain("LEASE_LOST", str(exc)),
                        active,
                    )
                next_heartbeat = now + self.policy.heartbeat_seconds

            requested, reason = self.journal.cancellation(self.campaign_id)
            if requested and cancellation_started is None:
                cancellation_started = now
                cancel_event.set()
            if now >= deadline and not deadline_exceeded:
                deadline_exceeded = True
                cancellation_started = now
                cancel_event.set()

            if cancellation_started is not None:
                grace_deadline = cancellation_started + self.policy.cancellation_grace_seconds
                if now >= grace_deadline:
                    if deadline_exceeded:
                        return (
                            HandlerResult.uncertain(
                                "HANDLER_TIMEOUT",
                                f"handler {registration.key!r} did not stop after its {timeout}s deadline",
                            ),
                            active,
                        )
                    return (
                        HandlerResult.uncertain(
                            "CANCELLATION_UNCONFIRMED",
                            reason or "handler did not confirm cancellation before the grace period ended",
                        ),
                        active,
                    )

    def _renew_invocation_leases(self, active: _InvocationState) -> _InvocationState:
        return _InvocationState(
            scheduler_lease=self.journal.renew_task_lease(
                active.scheduler_lease, ttl_seconds=self.policy.lease_ttl_seconds
            ),
            task_lease=self.journal.renew_task_lease(
                active.task_lease, ttl_seconds=self.policy.lease_ttl_seconds
            ),
            claim_leases=[
                self.journal.renew_task_lease(
                    lease, ttl_seconds=self.policy.lease_ttl_seconds
                )
                for lease in active.claim_leases
            ],
        )

    def _record_result(
        self,
        lease: TaskLease,
        registration: HandlerRegistration,
        idem_key: str,
        attempt: int,
        result: HandlerResult,
    ) -> None:
        payload = {
            "result": result.payload,
            "completedChecks": list(result.completed_checks),
            "blockers": list(result.blockers),
            "guardSatisfied": result.guard_satisfied,
            "validationLevel": result.validation_level,
        }
        event = {
            TaskStatus.SUCCEEDED: "TASK_SUCCEEDED",
            TaskStatus.FAILED: "TASK_FAILED",
            TaskStatus.BLOCKED: "TASK_BLOCKED",
            TaskStatus.UNSUPPORTED: "TASK_UNSUPPORTED",
            TaskStatus.UNCERTAIN: "TASK_BECAME_UNCERTAIN",
            TaskStatus.CANCELLED: "TASK_CANCELLED",
        }[result.status]
        self.journal.record_task_checkpoint(
            lease,
            plan_sha256=self.plan_sha256,
            status=result.status,
            attempt=attempt,
            handler_key=registration.key,
            idempotency_key=idem_key,
            payload=payload,
            error_code=result.error_code,
            error_message=result.message,
            retryable=result.retryable,
            event_kind=event,
        )

    @staticmethod
    def _enforce_completion_contract(task: TaskSpec, result: HandlerResult) -> HandlerResult:
        if result.status is not TaskStatus.SUCCEEDED:
            return result
        missing = sorted(set(task.completion_checks) - set(result.completed_checks))
        if missing:
            return HandlerResult.failed(
                "COMPLETION_CHECKS_MISSING",
                "handler did not attest required completion checks: " + ", ".join(missing),
                payload={"missingChecks": missing, "handlerPayload": result.payload},
            )
        if task.guard_required and not result.guard_satisfied:
            return HandlerResult.failed(
                "REQUIRED_GUARD_MISSING",
                "task requires an automated guard before it may succeed",
                payload={"handlerPayload": result.payload},
            )
        return result

    def _max_attempts(self, registration: HandlerRegistration | None) -> int:
        if registration is not None and registration.max_attempts is not None:
            return registration.max_attempts
        return self.policy.max_attempts

    def _wait_for_retry_or_cancel(self, seconds: float) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            requested, _reason = self.journal.cancellation(self.campaign_id)
            if requested:
                return True
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(0.05, remaining))
        return False

    def _acquire_task_lease(self, task: TaskSpec) -> TaskLease:
        return self.journal.acquire_task_lease(
            self.campaign_id,
            task.id,
            self._lease_owner_id,
            ttl_seconds=self.policy.lease_ttl_seconds,
        )

    def _global_claim_keys(self, task: TaskSpec) -> tuple[str, ...]:
        keys = {f"resource:{claim.casefold()}" for claim in task.resource_claims}
        product = task.metadata.get("productId")
        if isinstance(product, str) and product.strip():
            keys.add(f"product:{product.casefold()}")
        else:
            keys.update(f"write-root:{path.split('/', 1)[0]}" for path in task.write_set)
        return tuple(sorted(keys or {f"plan:{self.plan_sha256}"}))

    def _acquire_global_claims(self, task: TaskSpec) -> list[TaskLease]:
        acquired: list[TaskLease] = []
        try:
            for key in self._global_claim_keys(task):
                acquired.append(
                    self.journal.acquire_task_lease(
                        self._GLOBAL_CAMPAIGN,
                        key,
                        f"{self.campaign_id}:{self._lease_owner_id}:{task.id}",
                        ttl_seconds=self.policy.lease_ttl_seconds,
                    )
                )
        except Exception:
            for lease in reversed(acquired):
                self.journal.release_task_lease(lease)
            raise
        return acquired

    def _block_idempotency_mismatch(
        self,
        task: TaskSpec,
        checkpoint: TaskCheckpoint,
        expected_key: str | None,
    ) -> None:
        lease = self._acquire_task_lease(task)
        try:
            self._record_idempotency_mismatch(lease, task, checkpoint, expected_key)
        finally:
            self.journal.release_task_lease(lease)

    def _record_idempotency_mismatch(
        self,
        lease: TaskLease,
        task: TaskSpec,
        checkpoint: TaskCheckpoint,
        expected_key: str | None,
    ) -> None:
        self.journal.record_task_checkpoint(
            lease,
            plan_sha256=self.plan_sha256,
            status=TaskStatus.BLOCKED,
            attempt=checkpoint.attempt,
            handler_key=checkpoint.handler_key,
            idempotency_key=checkpoint.idempotency_key,
            payload={"expectedIdempotencyKey": expected_key},
            error_code="IDEMPOTENCY_KEY_MISMATCH",
            error_message=(
                f"handler identity for task {task.id!r} changed after execution began; "
                "automatic replay is unsafe"
            ),
            event_kind="TASK_BLOCKED_IDEMPOTENCY_MISMATCH",
        )

    def _report(
        self, *, scheduler_acquired: bool, stall_reasons: tuple[str, ...]
    ) -> CampaignExecutionReport:
        checkpoints = {item.task_id: item for item in self.journal.task_checkpoints(self.campaign_id)}
        states: list[TaskExecutionState] = []
        for task in self.graph.tasks:
            checkpoint = checkpoints.get(task.id)
            if checkpoint is None:
                states.append(
                    TaskExecutionState(task.id, TaskStatus.PENDING, 0, None, None, None, False)
                )
            else:
                states.append(
                    TaskExecutionState(
                        task_id=task.id,
                        status=checkpoint.status,
                        attempt=checkpoint.attempt,
                        handler_key=checkpoint.handler_key,
                        error_code=checkpoint.error_code,
                        message=checkpoint.error_message,
                        retryable=checkpoint.retryable,
                    )
                )
        cancelled, _reason = self.journal.cancellation(self.campaign_id)
        return CampaignExecutionReport(
            campaign_id=self.campaign_id,
            plan_sha256=self.plan_sha256,
            tasks=tuple(states),
            scheduler_acquired=scheduler_acquired,
            cancellation_requested=cancelled,
            stall_reasons=tuple(stall_reasons),
        )
