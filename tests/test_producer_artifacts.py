"""Immutable, non-authorizing artifact trails for ``ProductionRun``."""

from __future__ import annotations

import json
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from rqe.producer import FAILED, OK, ProductionRun, StageResult, stages
from rqe.producer.artifacts import (
    PRODUCTION_BLOCKED,
    PRODUCTION_COMPLETE,
    PRODUCTION_FAILED,
    ProductionArtifactError,
    persist_production_run,
    verify_production_run_artifacts,
)
from rqe.provenance import sha256_file, sha256_json, tree_sha256


def _project(root: Path) -> tuple[Path, dict]:
    source_files = {
        "games/probe/src/server.lua": "return { ready = true }\n",
        "games/probe/default.project.json": '{"name":"probe"}\n',
        "roblox/lib/GameKit/init.lua": "return {}\n",
        "roblox/lib/WorldKit/init.lua": "return {}\n",
        "roblox/lib/Templates/init.lua": "return {}\n",
    }
    for relative, payload in source_files.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload, encoding="utf-8")

    place = root / ".tmp/producer/probe.rbxlx"
    place.parent.mkdir(parents=True, exist_ok=True)
    place.write_bytes(b"<roblox version='4'><Item class='Script'/></roblox>")
    paths = [
        "games/probe/src",
        "games/probe/default.project.json",
        "roblox/lib/GameKit",
        "roblox/lib/WorldKit",
        "roblox/lib/Templates",
    ]
    source_hash, source_entries = tree_sha256(root, paths)
    place_hash = sha256_file(place)
    return place, {
        "sha256": source_hash,
        "fileCount": len(source_entries),
        "paths": paths,
        "placeSha256": place_hash,
        "buildId": sha256_json({
            "sourceSha256": source_hash,
            "placeSha256": place_hash,
            "gameId": "probe",
        }),
    }


def _production(root: Path, *, final_status: str = OK) -> ProductionRun:
    place, identity = _project(root)
    build = StageResult(
        stage="build",
        status=OK,
        detail={
            "ok": True,
            "compiles": True,
            "place": place.relative_to(root).as_posix(),
            "bytes": place.stat().st_size,
            "placeSha256": identity["placeSha256"],
            "buildId": identity["buildId"],
            "source": {
                "sha256": identity["sha256"],
                "fileCount": identity["fileCount"],
                "paths": identity["paths"],
            },
        },
    )
    candidate = StageResult(
        stage="release_candidate",
        status=final_status,
        detail={
            "ok": final_status == OK,
            "status": "RELEASE_CANDIDATE" if final_status == OK else "STATICALLY_CLEAN",
            "buildId": identity["buildId"],
            "placeSha256": identity["placeSha256"],
            "sourceSha256": identity["sha256"],
        },
        error="runtime evidence is absent" if final_status == FAILED else "",
    )
    planned = tuple(item["id"] for item in stages() if item["id"] != "scaffold")
    by_stage = {
        "design": StageResult(stage="design", status=OK, detail={"genre": "exploration"}),
        "build": build,
        "reevaluate": StageResult(
            stage="reevaluate",
            status=OK,
            detail={"ok": True, "source": {"sha256": identity["sha256"]}},
        ),
        "release_candidate": candidate,
    }
    return ProductionRun(
        game_id="probe",
        brief="Construa um jogo de exploração cooperativa em ruínas antigas.",
        results=[
            by_stage.get(stage, StageResult(stage=stage, status=OK, detail={"ok": True}))
            for stage in planned
        ],
        scaffold_requested=False,
        planned_stages=planned,
    )


def test_complete_snapshot_binds_brief_stages_source_and_place_without_authorizing_release(
    tmp_path: Path,
) -> None:
    production = _production(tmp_path)
    receipt = persist_production_run(
        production,
        project_root=tmp_path,
        run_id="production-complete",
    )

    assert receipt.status == PRODUCTION_COMPLETE
    assert receipt.validation_level == "STATICALLY_VALIDATED"
    verified = verify_production_run_artifacts(receipt.directory)
    manifest = verified.manifest
    assert manifest["releaseAllowed"] is False
    assert manifest["releaseAuthorization"]["status"] == "NOT_EVALUATED"
    assert manifest["releaseAuthorization"]["authority"] is False
    assert verified.brief["text"] == production.brief
    assert [item["result"]["stage"] for item in verified.stages] == [
        item["id"] for item in stages() if item["id"] != "scaffold"
    ]
    assert verified.source["status"] == "VERIFIED"
    assert verified.build["status"] == "VERIFIED"
    assert (receipt.directory / "build/place.rbxlx").read_bytes() == (
        tmp_path / ".tmp/producer/probe.rbxlx"
    ).read_bytes()
    assert not (tmp_path / "artifacts/latest.json").exists()
    assert not (tmp_path / "artifacts/latest").exists()


def test_failed_producer_is_preserved_as_failed_even_when_build_identity_is_valid(
    tmp_path: Path,
) -> None:
    receipt = persist_production_run(
        _production(tmp_path, final_status=FAILED),
        project_root=tmp_path,
        run_id="production-failed",
    )

    assert receipt.status == PRODUCTION_FAILED
    assert receipt.validation_level == "STATICALLY_VALIDATED"
    assert any(item["code"] == "E_STAGE_FAILED" for item in receipt.blockers)
    verified = verify_production_run_artifacts(receipt.directory)
    assert verified.manifest["releaseAllowed"] is False


def test_returned_ok_false_is_a_blocker_not_a_successful_artifact_run(tmp_path: Path) -> None:
    production = _production(tmp_path)
    production.result("release_candidate").detail["ok"] = False
    production.result("release_candidate").detail["error"] = "runtime was not observed"

    receipt = persist_production_run(
        production,
        project_root=tmp_path,
        run_id="production-declared-refusal",
    )

    assert receipt.status == PRODUCTION_BLOCKED
    assert any(item["code"] == "E_STAGE_DECLARED_REFUSAL" for item in receipt.blockers)
    verify_production_run_artifacts(receipt.directory)


def test_incomplete_or_self_declared_stage_graph_cannot_be_production_complete(
    tmp_path: Path,
) -> None:
    production = _production(tmp_path)
    production.results = [
        item for item in production.results if item.stage not in {"systems", "geometry"}
    ]
    production.planned_stages = tuple(item.stage for item in production.results)

    receipt = persist_production_run(
        production,
        project_root=tmp_path,
        run_id="production-incomplete-graph",
    )

    assert receipt.status == PRODUCTION_BLOCKED
    codes = {item["code"] for item in receipt.blockers}
    assert "E_STAGE_PLAN_NONCANONICAL" in codes
    assert "E_STAGE_GRAPH_INCOMPLETE" in codes
    verified = verify_production_run_artifacts(receipt.directory)
    assert verified.manifest["status"] == PRODUCTION_BLOCKED


def test_changed_place_is_copied_for_diagnosis_but_identity_fails_closed(tmp_path: Path) -> None:
    production = _production(tmp_path)
    place = tmp_path / production.result("build").detail["place"]
    place.write_bytes(b"changed after the producer declared its hash")

    receipt = persist_production_run(
        production,
        project_root=tmp_path,
        run_id="production-place-changed",
    )

    assert receipt.status == PRODUCTION_BLOCKED
    assert receipt.build_id is None
    assert (receipt.directory / "build/place.rbxlx").read_bytes() == place.read_bytes()
    assert any("copied place sha256 differs" in item["message"] for item in receipt.blockers)
    verified = verify_production_run_artifacts(receipt.directory)
    assert verified.build["identity"]["verified"] is False


def test_unsafe_source_root_finalizes_a_named_non_authorizing_blocker(tmp_path: Path) -> None:
    production = _production(tmp_path)
    build = production.result("build").detail
    build["source"]["paths"] = ["../outside"]

    receipt = persist_production_run(
        production,
        project_root=tmp_path,
        run_id="production-unsafe-source",
    )

    assert receipt.status == PRODUCTION_BLOCKED
    assert receipt.validation_level == "NOT_VALIDATED"
    assert any("source path is unsafe" in item["message"] for item in receipt.blockers)
    verified = verify_production_run_artifacts(receipt.directory)
    assert verified.source["status"] == "NOT_VERIFIED"


def test_artifact_and_manifest_tampering_are_detected(tmp_path: Path) -> None:
    first = persist_production_run(
        _production(tmp_path),
        project_root=tmp_path,
        run_id="production-artifact-tamper",
    )
    (first.directory / "production/brief.json").write_text("{}\n", encoding="utf-8")
    with pytest.raises(ProductionArtifactError, match="artifact (byte size|hash) changed"):
        verify_production_run_artifacts(first.directory)

    second_root = tmp_path / "second"
    second_root.mkdir()
    second = persist_production_run(
        _production(second_root),
        project_root=second_root,
        run_id="production-manifest-tamper",
    )
    manifest = json.loads(second.manifest_path.read_text(encoding="utf-8"))
    manifest["releaseAllowed"] = True
    manifest.pop("manifestSha256")
    manifest["manifestSha256"] = sha256_json(manifest)
    second.manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    with pytest.raises(ProductionArtifactError, match="can never authorize release"):
        verify_production_run_artifacts(second.directory)


def test_same_explicit_run_id_has_one_concurrent_owner(tmp_path: Path) -> None:
    production = _production(tmp_path)

    def write() -> object:
        try:
            return persist_production_run(
                production,
                project_root=tmp_path,
                run_id="production-concurrent",
            )
        except Exception as exc:  # captured for exact ownership assertions below
            return exc

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: write(), range(8)))

    receipts = [item for item in results if not isinstance(item, Exception)]
    failures = [item for item in results if isinstance(item, Exception)]
    assert len(receipts) == 1
    assert len(failures) == 7
    assert all(isinstance(item, FileExistsError) for item in failures)
    verify_production_run_artifacts(receipts[0].directory)


def test_latest_is_never_accepted_as_a_run_identity(tmp_path: Path) -> None:
    with pytest.raises(ProductionArtifactError, match="not a production run identity"):
        persist_production_run(
            _production(tmp_path),
            project_root=tmp_path,
            run_id="latest",
        )


def test_non_json_stage_detail_is_rejected_before_a_run_directory_is_created(
    tmp_path: Path,
) -> None:
    production = _production(tmp_path)
    production.result("design").detail["notJson"] = Path("somewhere")

    with pytest.raises(ProductionArtifactError, match="not deterministic JSON"):
        persist_production_run(
            production,
            project_root=tmp_path,
            run_id="production-non-json",
        )
    assert not (tmp_path / "artifacts/production-non-json").exists()
