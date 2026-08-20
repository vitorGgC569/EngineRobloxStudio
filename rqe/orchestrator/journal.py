"""Crash-safe append-only campaign journal backed by SQLite WAL."""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import TaskStatus


@dataclass(frozen=True)
class JournalEvent:
    sequence: int
    campaign_id: str
    kind: str
    payload: dict[str, Any]
    created_at: str


@dataclass(frozen=True)
class TaskCheckpoint:
    """Latest durable control-plane state for one task.

    Checkpoints are resumability state, not release evidence.  ``payload`` is
    deliberately an object so handlers cannot smuggle an untyped success bit
    into a scalar value that the scheduler might accidentally trust.
    """

    campaign_id: str
    task_id: str
    plan_sha256: str
    status: TaskStatus
    attempt: int
    fence_token: int
    handler_key: str | None
    idempotency_key: str | None
    payload: dict[str, Any]
    error_code: str | None
    error_message: str | None
    retryable: bool
    updated_at: str


@dataclass(frozen=True)
class TaskLease:
    campaign_id: str
    task_id: str
    owner_id: str
    fence_token: int
    expires_at: float

    def is_current(self, *, now: float | None = None) -> bool:
        return self.expires_at > (time.time() if now is None else now)


class CampaignBindingError(RuntimeError):
    """A campaign id was already bound to a different immutable plan."""


class LeaseUnavailable(RuntimeError):
    """Another live worker currently owns the requested task lease."""


class StaleFenceError(RuntimeError):
    """A worker tried to mutate task state after losing its lease fence."""


class SQLiteJournal:
    """A minimal durable source for replaying orchestration decisions.

    This database is control-plane state, not release evidence.  An artifact
    adapter can export its events into a finalized immutable campaign bundle.
    """

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._closed = False
        # Handler checkpoints may arrive from the executor's supervised worker
        # thread.  All access remains serialized by ``_lock``; disabling
        # sqlite's thread-affinity check does not make access unsynchronised.
        self._connection = sqlite3.connect(
            str(self.path), timeout=30, isolation_level=None, check_same_thread=False
        )
        self._connection.execute("PRAGMA journal_mode=WAL")
        self._connection.execute("PRAGMA synchronous=FULL")
        self._connection.execute("PRAGMA foreign_keys=ON")
        self._connection.execute("PRAGMA busy_timeout=30000")
        self._connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS campaign_events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                campaign_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_campaign_events_campaign_sequence
                ON campaign_events(campaign_id, sequence);
            CREATE TABLE IF NOT EXISTS campaign_bindings (
                campaign_id TEXT PRIMARY KEY,
                plan_sha256 TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS task_leases (
                campaign_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                fence_token INTEGER NOT NULL,
                owner_id TEXT,
                expires_at REAL NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (campaign_id, task_id)
            );
            CREATE TABLE IF NOT EXISTS task_checkpoints (
                campaign_id TEXT NOT NULL,
                task_id TEXT NOT NULL,
                plan_sha256 TEXT NOT NULL,
                status TEXT NOT NULL,
                attempt INTEGER NOT NULL,
                fence_token INTEGER NOT NULL,
                handler_key TEXT,
                idempotency_key TEXT,
                payload_json TEXT NOT NULL,
                error_code TEXT,
                error_message TEXT,
                retryable INTEGER NOT NULL,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (campaign_id, task_id),
                FOREIGN KEY (campaign_id) REFERENCES campaign_bindings(campaign_id)
            );
            CREATE TABLE IF NOT EXISTS campaign_controls (
                campaign_id TEXT PRIMARY KEY,
                cancel_requested INTEGER NOT NULL,
                reason TEXT,
                updated_at TEXT NOT NULL,
                FOREIGN KEY (campaign_id) REFERENCES campaign_bindings(campaign_id)
            );
            """
        )

    def close(self) -> None:
        with self._lock:
            if not self._closed:
                self._connection.close()
                self._closed = True

    def __enter__(self) -> "SQLiteJournal":
        return self

    def __exit__(self, _exc_type: Any, _exc: Any, _traceback: Any) -> None:
        self.close()

    def append(self, campaign_id: str, kind: str, payload: dict[str, Any]) -> JournalEvent:
        if not isinstance(campaign_id, str) or not campaign_id.strip():
            raise ValueError("campaign_id must not be empty")
        if not isinstance(kind, str) or not kind.strip():
            raise ValueError("event kind must not be empty")
        if not isinstance(payload, dict):
            raise ValueError("event payload must be an object")
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        created_at = datetime.now(timezone.utc).isoformat()

        with self._lock:
            try:
                self._connection.execute("BEGIN IMMEDIATE")
                sequence = self._insert_event_locked(
                    campaign_id, kind, encoded=encoded, created_at=created_at
                )
                self._connection.execute("COMMIT")
            except Exception:
                if self._connection.in_transaction:
                    self._connection.execute("ROLLBACK")
                raise
        return JournalEvent(sequence, campaign_id, kind, dict(payload), created_at)

    def _insert_event_locked(
        self,
        campaign_id: str,
        kind: str,
        *,
        encoded: str,
        created_at: str,
    ) -> int:
        cursor = self._connection.execute(
            "INSERT INTO campaign_events(campaign_id, kind, payload_json, created_at) VALUES (?, ?, ?, ?)",
            (campaign_id, kind, encoded, created_at),
        )
        return int(cursor.lastrowid)

    def events(self, campaign_id: str, *, after_sequence: int = 0) -> tuple[JournalEvent, ...]:
        if after_sequence < 0:
            raise ValueError("after_sequence must be non-negative")
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT sequence, campaign_id, kind, payload_json, created_at
                FROM campaign_events
                WHERE campaign_id = ? AND sequence > ?
                ORDER BY sequence ASC
                """,
                (campaign_id, after_sequence),
            ).fetchall()
        return tuple(
            JournalEvent(
                sequence=int(row[0]),
                campaign_id=str(row[1]),
                kind=str(row[2]),
                payload=json.loads(str(row[3])),
                created_at=str(row[4]),
            )
            for row in rows
        )

    def bind_campaign(self, campaign_id: str, plan_sha256: str) -> None:
        """Bind a resumable campaign id to exactly one immutable plan hash."""

        if not isinstance(campaign_id, str) or not campaign_id.strip():
            raise ValueError("campaign_id must not be empty")
        if not isinstance(plan_sha256, str) or len(plan_sha256) != 64:
            raise ValueError("plan_sha256 must be a 64-character digest")
        created_at = datetime.now(timezone.utc).isoformat()
        with self._lock:
            try:
                self._connection.execute("BEGIN IMMEDIATE")
                row = self._connection.execute(
                    "SELECT plan_sha256 FROM campaign_bindings WHERE campaign_id = ?",
                    (campaign_id,),
                ).fetchone()
                if row is None:
                    self._connection.execute(
                        "INSERT INTO campaign_bindings(campaign_id, plan_sha256, created_at) VALUES (?, ?, ?)",
                        (campaign_id, plan_sha256, created_at),
                    )
                    payload = json.dumps(
                        {"planSha256": plan_sha256},
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                    self._insert_event_locked(
                        campaign_id,
                        "CAMPAIGN_BOUND",
                        encoded=payload,
                        created_at=created_at,
                    )
                elif str(row[0]) != plan_sha256:
                    raise CampaignBindingError(
                        f"campaign {campaign_id!r} is already bound to plan {row[0]!r}, "
                        f"not {plan_sha256!r}"
                    )
                self._connection.execute("COMMIT")
            except Exception:
                if self._connection.in_transaction:
                    self._connection.execute("ROLLBACK")
                raise

    def acquire_task_lease(
        self,
        campaign_id: str,
        task_id: str,
        owner_id: str,
        *,
        ttl_seconds: float,
        now: float | None = None,
    ) -> TaskLease:
        """Acquire or renew one durable lease with a monotonic fencing token."""

        if not all(isinstance(value, str) and value.strip() for value in (campaign_id, task_id, owner_id)):
            raise ValueError("campaign_id, task_id, and owner_id must not be empty")
        if ttl_seconds <= 0:
            raise ValueError("ttl_seconds must be positive")
        current_time = time.time() if now is None else float(now)
        expires_at = current_time + float(ttl_seconds)
        updated_at = datetime.now(timezone.utc).isoformat()
        with self._lock:
            try:
                self._connection.execute("BEGIN IMMEDIATE")
                row = self._connection.execute(
                    """
                    SELECT fence_token, owner_id, expires_at
                    FROM task_leases WHERE campaign_id = ? AND task_id = ?
                    """,
                    (campaign_id, task_id),
                ).fetchone()
                if row is None:
                    fence_token = 1
                    self._connection.execute(
                        """
                        INSERT INTO task_leases(
                            campaign_id, task_id, fence_token, owner_id, expires_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        (campaign_id, task_id, fence_token, owner_id, expires_at, updated_at),
                    )
                else:
                    previous_token = int(row[0])
                    previous_owner = None if row[1] is None else str(row[1])
                    previous_expiry = float(row[2])
                    if previous_owner == owner_id and previous_expiry > current_time:
                        fence_token = previous_token
                    elif previous_owner is not None and previous_expiry > current_time:
                        raise LeaseUnavailable(
                            f"task {task_id!r} is leased by {previous_owner!r} until {previous_expiry}"
                        )
                    else:
                        fence_token = previous_token + 1
                    self._connection.execute(
                        """
                        UPDATE task_leases
                        SET fence_token = ?, owner_id = ?, expires_at = ?, updated_at = ?
                        WHERE campaign_id = ? AND task_id = ?
                        """,
                        (
                            fence_token,
                            owner_id,
                            expires_at,
                            updated_at,
                            campaign_id,
                            task_id,
                        ),
                    )
                self._connection.execute("COMMIT")
            except Exception:
                if self._connection.in_transaction:
                    self._connection.execute("ROLLBACK")
                raise
        return TaskLease(campaign_id, task_id, owner_id, fence_token, expires_at)

    def renew_task_lease(
        self,
        lease: TaskLease,
        *,
        ttl_seconds: float,
        now: float | None = None,
    ) -> TaskLease:
        if ttl_seconds <= 0:
            raise ValueError("ttl_seconds must be positive")
        current_time = time.time() if now is None else float(now)
        expires_at = current_time + float(ttl_seconds)
        updated_at = datetime.now(timezone.utc).isoformat()
        with self._lock:
            try:
                self._connection.execute("BEGIN IMMEDIATE")
                row = self._connection.execute(
                    """
                    SELECT owner_id, fence_token, expires_at FROM task_leases
                    WHERE campaign_id = ? AND task_id = ?
                    """,
                    (lease.campaign_id, lease.task_id),
                ).fetchone()
                if (
                    row is None
                    or row[0] != lease.owner_id
                    or int(row[1]) != lease.fence_token
                    or float(row[2]) <= current_time
                ):
                    raise StaleFenceError(
                        f"lease fence {lease.fence_token} for task {lease.task_id!r} is stale"
                    )
                self._connection.execute(
                    """
                    UPDATE task_leases SET expires_at = ?, updated_at = ?
                    WHERE campaign_id = ? AND task_id = ?
                    """,
                    (expires_at, updated_at, lease.campaign_id, lease.task_id),
                )
                self._connection.execute("COMMIT")
            except Exception:
                if self._connection.in_transaction:
                    self._connection.execute("ROLLBACK")
                raise
        return TaskLease(
            lease.campaign_id, lease.task_id, lease.owner_id, lease.fence_token, expires_at
        )

    def release_task_lease(self, lease: TaskLease, *, now: float | None = None) -> None:
        current_time = time.time() if now is None else float(now)
        updated_at = datetime.now(timezone.utc).isoformat()
        with self._lock:
            try:
                self._connection.execute("BEGIN IMMEDIATE")
                row = self._connection.execute(
                    """
                    SELECT owner_id, fence_token FROM task_leases
                    WHERE campaign_id = ? AND task_id = ?
                    """,
                    (lease.campaign_id, lease.task_id),
                ).fetchone()
                if row is None or row[0] != lease.owner_id or int(row[1]) != lease.fence_token:
                    raise StaleFenceError(
                        f"lease fence {lease.fence_token} for task {lease.task_id!r} is stale"
                    )
                self._connection.execute(
                    """
                    UPDATE task_leases
                    SET owner_id = NULL, expires_at = ?, updated_at = ?
                    WHERE campaign_id = ? AND task_id = ?
                    """,
                    (current_time, updated_at, lease.campaign_id, lease.task_id),
                )
                self._connection.execute("COMMIT")
            except Exception:
                if self._connection.in_transaction:
                    self._connection.execute("ROLLBACK")
                raise

    def task_lease(self, campaign_id: str, task_id: str) -> TaskLease | None:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT owner_id, fence_token, expires_at FROM task_leases
                WHERE campaign_id = ? AND task_id = ?
                """,
                (campaign_id, task_id),
            ).fetchone()
        if row is None or row[0] is None:
            return None
        return TaskLease(campaign_id, task_id, str(row[0]), int(row[1]), float(row[2]))

    def record_task_checkpoint(
        self,
        lease: TaskLease,
        *,
        plan_sha256: str,
        status: TaskStatus,
        attempt: int,
        handler_key: str | None,
        idempotency_key: str | None,
        payload: dict[str, Any] | None = None,
        error_code: str | None = None,
        error_message: str | None = None,
        retryable: bool = False,
        event_kind: str = "TASK_CHECKPOINTED",
        now: float | None = None,
    ) -> TaskCheckpoint:
        """Atomically persist task state and its corresponding journal event."""

        if not isinstance(status, TaskStatus):
            raise ValueError(f"invalid task status: {status!r}")
        if attempt < 0:
            raise ValueError("attempt must be non-negative")
        body = dict(payload or {})
        encoded_body = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        current_time = time.time() if now is None else float(now)
        updated_at = datetime.now(timezone.utc).isoformat()
        event_payload = {
            "taskId": lease.task_id,
            "status": status.value,
            "attempt": attempt,
            "fenceToken": lease.fence_token,
            "handlerKey": handler_key,
            "idempotencyKey": idempotency_key,
            "errorCode": error_code,
            "errorMessage": error_message,
            "retryable": bool(retryable),
            "payload": body,
        }
        encoded_event = json.dumps(
            event_payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )
        with self._lock:
            try:
                self._connection.execute("BEGIN IMMEDIATE")
                binding = self._connection.execute(
                    "SELECT plan_sha256 FROM campaign_bindings WHERE campaign_id = ?",
                    (lease.campaign_id,),
                ).fetchone()
                if binding is None or str(binding[0]) != plan_sha256:
                    raise CampaignBindingError(
                        f"campaign {lease.campaign_id!r} is not bound to plan {plan_sha256!r}"
                    )
                row = self._connection.execute(
                    """
                    SELECT owner_id, fence_token, expires_at FROM task_leases
                    WHERE campaign_id = ? AND task_id = ?
                    """,
                    (lease.campaign_id, lease.task_id),
                ).fetchone()
                if (
                    row is None
                    or row[0] != lease.owner_id
                    or int(row[1]) != lease.fence_token
                    or float(row[2]) <= current_time
                ):
                    raise StaleFenceError(
                        f"lease fence {lease.fence_token} for task {lease.task_id!r} is stale"
                    )
                self._connection.execute(
                    """
                    INSERT INTO task_checkpoints(
                        campaign_id, task_id, plan_sha256, status, attempt, fence_token,
                        handler_key, idempotency_key, payload_json, error_code,
                        error_message, retryable, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(campaign_id, task_id) DO UPDATE SET
                        plan_sha256 = excluded.plan_sha256,
                        status = excluded.status,
                        attempt = excluded.attempt,
                        fence_token = excluded.fence_token,
                        handler_key = excluded.handler_key,
                        idempotency_key = excluded.idempotency_key,
                        payload_json = excluded.payload_json,
                        error_code = excluded.error_code,
                        error_message = excluded.error_message,
                        retryable = excluded.retryable,
                        updated_at = excluded.updated_at
                    """,
                    (
                        lease.campaign_id,
                        lease.task_id,
                        plan_sha256,
                        status.value,
                        attempt,
                        lease.fence_token,
                        handler_key,
                        idempotency_key,
                        encoded_body,
                        error_code,
                        error_message,
                        int(bool(retryable)),
                        updated_at,
                    ),
                )
                self._insert_event_locked(
                    lease.campaign_id,
                    event_kind,
                    encoded=encoded_event,
                    created_at=updated_at,
                )
                self._connection.execute("COMMIT")
            except Exception:
                if self._connection.in_transaction:
                    self._connection.execute("ROLLBACK")
                raise
        return TaskCheckpoint(
            campaign_id=lease.campaign_id,
            task_id=lease.task_id,
            plan_sha256=plan_sha256,
            status=status,
            attempt=attempt,
            fence_token=lease.fence_token,
            handler_key=handler_key,
            idempotency_key=idempotency_key,
            payload=body,
            error_code=error_code,
            error_message=error_message,
            retryable=bool(retryable),
            updated_at=updated_at,
        )

    @staticmethod
    def _checkpoint_from_row(row: tuple[Any, ...]) -> TaskCheckpoint:
        return TaskCheckpoint(
            campaign_id=str(row[0]),
            task_id=str(row[1]),
            plan_sha256=str(row[2]),
            status=TaskStatus(str(row[3])),
            attempt=int(row[4]),
            fence_token=int(row[5]),
            handler_key=None if row[6] is None else str(row[6]),
            idempotency_key=None if row[7] is None else str(row[7]),
            payload=json.loads(str(row[8])),
            error_code=None if row[9] is None else str(row[9]),
            error_message=None if row[10] is None else str(row[10]),
            retryable=bool(row[11]),
            updated_at=str(row[12]),
        )

    def task_checkpoint(self, campaign_id: str, task_id: str) -> TaskCheckpoint | None:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT campaign_id, task_id, plan_sha256, status, attempt, fence_token,
                       handler_key, idempotency_key, payload_json, error_code,
                       error_message, retryable, updated_at
                FROM task_checkpoints WHERE campaign_id = ? AND task_id = ?
                """,
                (campaign_id, task_id),
            ).fetchone()
        return None if row is None else self._checkpoint_from_row(row)

    def task_checkpoints(self, campaign_id: str) -> tuple[TaskCheckpoint, ...]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT campaign_id, task_id, plan_sha256, status, attempt, fence_token,
                       handler_key, idempotency_key, payload_json, error_code,
                       error_message, retryable, updated_at
                FROM task_checkpoints WHERE campaign_id = ? ORDER BY task_id ASC
                """,
                (campaign_id,),
            ).fetchall()
        return tuple(self._checkpoint_from_row(row) for row in rows)

    def request_cancellation(self, campaign_id: str, reason: str) -> None:
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError("cancellation reason must not be empty")
        updated_at = datetime.now(timezone.utc).isoformat()
        payload = json.dumps(
            {"reason": reason.strip()}, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        )
        with self._lock:
            try:
                self._connection.execute("BEGIN IMMEDIATE")
                binding = self._connection.execute(
                    "SELECT 1 FROM campaign_bindings WHERE campaign_id = ?", (campaign_id,)
                ).fetchone()
                if binding is None:
                    raise CampaignBindingError(f"campaign {campaign_id!r} is not bound")
                self._connection.execute(
                    """
                    INSERT INTO campaign_controls(campaign_id, cancel_requested, reason, updated_at)
                    VALUES (?, 1, ?, ?)
                    ON CONFLICT(campaign_id) DO UPDATE SET
                        cancel_requested = 1, reason = excluded.reason, updated_at = excluded.updated_at
                    """,
                    (campaign_id, reason.strip(), updated_at),
                )
                self._insert_event_locked(
                    campaign_id,
                    "CAMPAIGN_CANCEL_REQUESTED",
                    encoded=payload,
                    created_at=updated_at,
                )
                self._connection.execute("COMMIT")
            except Exception:
                if self._connection.in_transaction:
                    self._connection.execute("ROLLBACK")
                raise

    def cancellation(self, campaign_id: str) -> tuple[bool, str | None]:
        with self._lock:
            row = self._connection.execute(
                "SELECT cancel_requested, reason FROM campaign_controls WHERE campaign_id = ?",
                (campaign_id,),
            ).fetchone()
        if row is None:
            return False, None
        return bool(row[0]), None if row[1] is None else str(row[1])
