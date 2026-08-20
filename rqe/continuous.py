from __future__ import annotations

import json
import signal
from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import Event
from typing import Any

from .audit import run_audit
from .fixes import write_fix_plan
from .project import Project
from .reporting import write_reports


STATUS_FILENAME = "continuous-status.json"


def _timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def _write_error_status(root: Path, error: Exception, cycle_started_at: str) -> None:
    reports_dir = root / "reports"
    try:
        reports_dir = Project.load(root).reports_dir
    except Exception:
        reports_dir.mkdir(parents=True, exist_ok=True)
    _write_json(
        reports_dir / STATUS_FILENAME,
        {
            "status": "ERROR",
            "cycleStartedAt": cycle_started_at,
            "cycleFinishedAt": _timestamp(),
            "releaseAllowed": False,
            "error": {"type": type(error).__name__, "message": str(error)},
            "nextAction": "repair the project and wait for the next cycle",
        },
    )


def _quality_focus(project: Project) -> dict[str, Any]:
    relative_path = project.config.get("qualityFocus", "quality/quality-focus.json")
    path = project.root / relative_path
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("domains"), dict):
        raise ValueError("quality focus must define a domains object")
    return payload


def _evaluate_quality_focus(project: Project, report: Any, focus: dict[str, Any]) -> dict[str, Any]:
    domain_results: dict[str, Any] = {}
    gaps: list[dict[str, Any]] = []
    raw_visual_score = float(project.fixture.get("ui", {}).get("visualScore", 0)) * 100
    for domain, settings in focus["domains"].items():
        target = float(settings.get("targetScore", 100))
        actual = raw_visual_score if domain == "visual" else float(report.scores.get(domain, 0))
        result = {
            "actualScore": round(actual, 1),
            "targetScore": round(target, 1),
            "onTarget": actual >= target,
            "focus": settings.get("focus", "") ,
        }
        domain_results[domain] = result
        if actual < target:
            gaps.append({"domain": domain, "gap": round(target - actual, 1), **result})

    review = focus.get("visualReview", {})
    snapshots = project.fixture.get("ui", {}).get("snapshots", [])
    required_snapshots = review.get("requiredSnapshots", [])
    missing_snapshots = sorted(set(required_snapshots) - set(snapshots))
    visual_review = {
        "rawScore": round(raw_visual_score, 1),
        "minimumRawScore": float(review.get("minimumRawVisualScore", 95)),
        "snapshots": snapshots,
        "missingSnapshots": missing_snapshots,
        "onTarget": raw_visual_score >= float(review.get("minimumRawVisualScore", 95)) and not missing_snapshots,
    }
    if not visual_review["onTarget"]:
        gaps.append({"domain": "visual_review", "gap": max(0.0, visual_review["minimumRawScore"] - visual_review["rawScore"]), "missingSnapshots": missing_snapshots})
    manifest_path = project.root / "assets/asset-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    pending_art = [
        asset["key"]
        for asset in manifest.get("assets", [])
        if asset.get("source") == "generated-raster" and asset.get("runtimeReference") == "pending-roblox-upload"
    ]
    art_readiness = {
        "pendingRuntimeUpload": pending_art,
        "ready": not pending_art,
    }
    if pending_art:
        gaps.append({"domain": "art_asset_readiness", "gap": len(pending_art), "pendingRuntimeUpload": pending_art})
    return {
        "status": "ON_TARGET" if not gaps else "IMPROVE",
        "domains": domain_results,
        "visualReview": visual_review,
        "artReadiness": art_readiness,
        "gaps": gaps,
    }


def run_cycle(root: str | Path) -> dict[str, Any]:
    project_root = Path(root).resolve()
    cycle_started_at = _timestamp()
    project = Project.load(project_root)
    focus = _quality_focus(project)
    report = run_audit(project_root)
    json_path, markdown_path = write_reports(report, project.reports_dir)
    fix_path = write_fix_plan(report, project.reports_dir)
    cycle_finished_at = _timestamp()
    failed = [
        {"id": item.id, "probe": item.probe, "severity": item.severity, "message": item.message}
        for item in report.evidence
        if item.status == "FAIL"
    ]
    quality_focus = _evaluate_quality_focus(project, report, focus)
    improvement_actions = [
        f"Raise {gap['domain']} by {gap.get('gap', 0):.1f} points"
        for gap in quality_focus["gaps"]
    ]
    if not improvement_actions:
        improvement_actions = [
            "Review the next visual snapshot set",
            "Check for composition, readability and onboarding polish regressions",
            "Re-run structural, gameplay, security and performance evidence",
        ]
    status = {
        "status": "PASS" if report.release_allowed else "BLOCKED",
        "cycleStartedAt": cycle_started_at,
        "cycleFinishedAt": cycle_finished_at,
        "releaseAllowed": report.release_allowed,
        "summary": report.summary,
        "scores": report.scores,
        "failures": failed,
        "releaseReasons": report.release_reasons,
        "qualityFocus": quality_focus,
        "improvementActions": improvement_actions,
        "reports": {
            "evidenceJson": str(json_path),
            "markdown": str(markdown_path),
            "fixPlan": str(fix_path),
        },
        "nextAction": "continue the quality improvement backlog" if report.release_allowed else "apply the fix plan and quality backlog before the next cycle",
    }
    _write_json(project.reports_dir / STATUS_FILENAME, status)
    return status


def run_forever(root: str | Path, interval_seconds: float = 300.0) -> None:
    if interval_seconds <= 0:
        raise ValueError("interval_seconds must be positive")

    project_root = Path(root).resolve()
    stop_event = Event()
    previous_handlers: dict[signal.Signals, Any] = {}

    def request_stop(_signum: int, _frame: Any) -> None:
        stop_event.set()

    for signum in (signal.SIGINT, signal.SIGTERM):
        try:
            previous_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, request_stop)
        except (ValueError, OSError):
            pass

    try:
        while not stop_event.is_set():
            cycle_started_at = _timestamp()
            try:
                run_cycle(project_root)
            except Exception as exc:  # the watcher must survive a broken iteration
                _write_error_status(project_root, exc, cycle_started_at)
            next_run = datetime.now(timezone.utc) + timedelta(seconds=interval_seconds)
            stop_event.wait(max(0.1, (next_run - datetime.now(timezone.utc)).total_seconds()))
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
