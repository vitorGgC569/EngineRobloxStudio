"""Publication authority comes only from a finalized, hash-bound release run."""
from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

from .orchestrator.metrics import MetricsError, verify_finalized_run


def verify_release_payload(run_directory: Path, payload: bytes) -> dict[str, Any]:
    run = verify_finalized_run(run_directory)
    manifest = run.manifest
    gate = run.read_json_artifact(manifest.get("gate"))
    provenance = run.read_json_artifact(manifest.get("provenance"))
    if not isinstance(gate, dict) or not isinstance(provenance, dict):
        raise MetricsError("release gate and provenance must be objects")
    if manifest.get("releaseAllowed") is not True or gate.get("releaseAllowed") is not True:
        raise MetricsError("the immutable release run blocks publication")
    if gate.get("blockers"):
        raise MetricsError("the release gate contains blockers")
    if gate.get("runId") != run.run_id or gate.get("buildHash") != manifest.get("buildId"):
        raise MetricsError("release gate is not bound to this run and build")
    if provenance.get("buildId") != manifest.get("buildId"):
        raise MetricsError("build provenance belongs to a different build")
    digest = hashlib.sha256(payload).hexdigest()
    place = provenance.get("place") or {}
    if place.get("sha256") != digest or place.get("bytes") != len(payload):
        raise MetricsError("publication bytes differ from the validated place")
    if (provenance.get("hashes") or {}).get("place") != digest:
        raise MetricsError("place hash does not match the build identity")
    candidates = [entry for path, entry in run.artifacts.items()
                  if Path(path).suffix in {".rbxlx", ".rbxl"}
                  and entry["sha256"] == digest and entry["bytes"] == len(payload)]
    if not candidates:
        raise MetricsError("validated place is not an immutable run artifact")
    return {"runId": run.run_id, "manifestSha256": run.manifest_sha256,
            "buildId": manifest["buildId"], "placeSha256": digest, "bytes": len(payload)}
