"""Open Cloud DataStore persistence test harness.

Executes write, read, update, and cleanup verification against real Open Cloud
DataStores or an in-memory simulated test sandbox. Produces structured, immutable
receipts suitable for evidence binding and release gate evaluation.
"""

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Mapping

from .open_cloud import CloudResult, OpenCloudClient, Outcome


@dataclass(frozen=True)
class DatastoreOperationRecord:
    operation: str
    target: str
    status: str
    duration_ms: float
    details: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "operation": self.operation,
            "target": self.target,
            "status": self.status,
            "durationMs": round(self.duration_ms, 2),
            "details": dict(self.details),
        }


@dataclass(frozen=True)
class DatastoreTestSessionReceipt:
    run_id: str
    universe_id: str
    datastore_name: str
    entry_id: str
    status: str
    outcome: str
    operations: tuple[DatastoreOperationRecord, ...]
    data_integrity: bool
    persisted_payload: Mapping[str, Any]
    blockers: tuple[str, ...] = ()
    error: str | None = None
    started_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    @property
    def ok(self) -> bool:
        return self.status == "PASS"

    def to_dict(self) -> dict[str, Any]:
        return {
            "runId": self.run_id,
            "universeId": self.universe_id,
            "datastoreName": self.datastore_name,
            "entryId": self.entry_id,
            "status": self.status,
            "outcome": self.outcome,
            "dataIntegrity": self.data_integrity,
            "persistedPayload": dict(self.persisted_payload),
            "operations": [op.to_dict() for op in self.operations],
            "blockers": list(self.blockers),
            "error": self.error,
            "startedAt": self.started_at,
        }


class SimulatedDatastoreBackend:
    """In-memory DataStore sandbox for offline verification and testing."""

    def __init__(self) -> None:
        self.stores: dict[str, dict[str, Any]] = {}

    def set_entry(self, universe_id: str, store: str, key: str, value: Any) -> CloudResult:
        full_store = f"{universe_id}:{store}"
        if full_store not in self.stores:
            self.stores[full_store] = {}
        self.stores[full_store][key] = json.loads(json.dumps(value))
        return CloudResult(outcome=Outcome.OK, status=200, data={"key": key, "value": value})

    def get_entry(self, universe_id: str, store: str, key: str) -> CloudResult:
        full_store = f"{universe_id}:{store}"
        entries = self.stores.get(full_store, {})
        if key not in entries:
            return CloudResult(outcome=Outcome.NOT_FOUND, status=404, error="entry not found")
        return CloudResult(outcome=Outcome.OK, status=200, data={"value": entries[key]})

    def delete_entry(self, universe_id: str, store: str, key: str) -> CloudResult:
        full_store = f"{universe_id}:{store}"
        if full_store in self.stores and key in self.stores[full_store]:
            del self.stores[full_store][key]
        return CloudResult(outcome=Outcome.OK, status=200, data={"deleted": True})


class DatastoreHarness:
    """Runs end-to-end DataStore validation against Open Cloud or simulated sandbox."""

    def __init__(
        self,
        client: OpenCloudClient | None = None,
        *,
        simulated: bool = False,
    ) -> None:
        self.client = client or OpenCloudClient()
        self.simulated = simulated
        self._sim_backend = SimulatedDatastoreBackend() if simulated else None

    def run_test_session(
        self,
        universe_id: str,
        datastore: str = "RQE_PersistenceTest",
        *,
        run_id: str = "datastore-test-001",
        scope: str = "global",
    ) -> DatastoreTestSessionReceipt:
        """Execute a full write-read-update-verify-delete cycle."""
        timestamp = int(time.time())
        entry_id = f"__rqe_test_{run_id}_{timestamp}"
        operations: list[DatastoreOperationRecord] = []
        started_iso = datetime.now(timezone.utc).isoformat()

        if not self.simulated and not self.client.api_key:
            return DatastoreTestSessionReceipt(
                run_id=run_id,
                universe_id=universe_id,
                datastore_name=datastore,
                entry_id=entry_id,
                status="BLOCKED",
                outcome=Outcome.BLOCKED.value,
                operations=(),
                data_integrity=False,
                persisted_payload={},
                blockers=(
                    "ROBLOX_OPEN_CLOUD_KEY is not configured with universe.datastore:read and universe.datastore:write permissions",
                ),
                started_at=started_iso,
            )

        # 1. Initial Write
        initial_payload = {
            "testRunId": run_id,
            "currency": 1000,
            "inventory": ["basic_mining_pack"],
            "plot": "PlotA",
            "floorLevel": 1,
            "updatedAt": timestamp,
        }

        t0 = time.perf_counter()
        if self.simulated:
            write_res = self._sim_backend.set_entry(universe_id, datastore, entry_id, initial_payload)  # type: ignore[union-attr]
        else:
            write_res = self.client.set_datastore_entry(universe_id, datastore, entry_id, initial_payload, scope=scope)
        dur1 = (time.perf_counter() - t0) * 1000
        operations.append(DatastoreOperationRecord("set_entry", entry_id, write_res.outcome.value, dur1, {"payload": initial_payload}))

        if not write_res.ok:
            return DatastoreTestSessionReceipt(
                run_id=run_id,
                universe_id=universe_id,
                datastore_name=datastore,
                entry_id=entry_id,
                status="FAIL",
                outcome=write_res.outcome.value,
                operations=tuple(operations),
                data_integrity=False,
                persisted_payload={},
                error=write_res.error,
                started_at=started_iso,
            )

        # 2. Read back & verify
        t0 = time.perf_counter()
        if self.simulated:
            read_res = self._sim_backend.get_entry(universe_id, datastore, entry_id)  # type: ignore[union-attr]
        else:
            read_res = self.client.datastore_entry(universe_id, datastore, entry_id, scope=scope)
        dur2 = (time.perf_counter() - t0) * 1000
        read_val = read_res.data.get("value") if isinstance(read_res.data, dict) else read_res.data
        matches_initial = read_val == initial_payload
        operations.append(DatastoreOperationRecord("get_entry", entry_id, read_res.outcome.value, dur2, {"verified": matches_initial}))

        if not matches_initial:
            return DatastoreTestSessionReceipt(
                run_id=run_id,
                universe_id=universe_id,
                datastore_name=datastore,
                entry_id=entry_id,
                status="FAIL",
                outcome="DATA_CORRUPTION",
                operations=tuple(operations),
                data_integrity=False,
                persisted_payload=read_val if isinstance(read_val, dict) else {},
                error="Read payload does not match written initial payload",
                started_at=started_iso,
            )

        # 3. Update (Atomic Delta)
        updated_payload = dict(initial_payload)
        updated_payload["currency"] = 900
        updated_payload["inventory"] = ["basic_mining_pack", "copper_lynx_prospector"]
        updated_payload["floorLevel"] = 2

        t0 = time.perf_counter()
        if self.simulated:
            update_res = self._sim_backend.set_entry(universe_id, datastore, entry_id, updated_payload)  # type: ignore[union-attr]
        else:
            update_res = self.client.set_datastore_entry(universe_id, datastore, entry_id, updated_payload, scope=scope)
        dur3 = (time.perf_counter() - t0) * 1000
        operations.append(DatastoreOperationRecord("update_entry", entry_id, update_res.outcome.value, dur3, {"updated": updated_payload}))

        # 4. Verify Update
        t0 = time.perf_counter()
        if self.simulated:
            verify_res = self._sim_backend.get_entry(universe_id, datastore, entry_id)  # type: ignore[union-attr]
        else:
            verify_res = self.client.datastore_entry(universe_id, datastore, entry_id, scope=scope)
        dur4 = (time.perf_counter() - t0) * 1000
        verified_val = verify_res.data.get("value") if isinstance(verify_res.data, dict) else verify_res.data
        matches_update = verified_val == updated_payload
        operations.append(DatastoreOperationRecord("verify_update", entry_id, verify_res.outcome.value, dur4, {"verified": matches_update}))

        # 5. Cleanup
        t0 = time.perf_counter()
        if self.simulated:
            del_res = self._sim_backend.delete_entry(universe_id, datastore, entry_id)  # type: ignore[union-attr]
        else:
            del_res = self.client.delete_datastore_entry(universe_id, datastore, entry_id, scope=scope)
        dur5 = (time.perf_counter() - t0) * 1000
        operations.append(DatastoreOperationRecord("delete_entry", entry_id, del_res.outcome.value, dur5, {"cleanedUp": del_res.ok}))

        final_status = "PASS" if (matches_initial and matches_update and del_res.ok) else "FAIL"
        return DatastoreTestSessionReceipt(
            run_id=run_id,
            universe_id=universe_id,
            datastore_name=datastore,
            entry_id=entry_id,
            status=final_status,
            outcome=Outcome.OK.value if final_status == "PASS" else Outcome.FAILED.value,
            operations=tuple(operations),
            data_integrity=matches_initial and matches_update,
            persisted_payload=updated_payload,
            started_at=started_iso,
        )
