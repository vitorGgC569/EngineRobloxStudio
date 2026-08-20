from __future__ import annotations

from pathlib import Path

from .models import AuditReport


def write_fix_plan(report: AuditReport, reports_dir: Path) -> Path:
    reports_dir.mkdir(parents=True, exist_ok=True)
    path = reports_dir / "fix-plan.md"
    failed = [item for item in report.evidence if item.status == "FAIL"]
    lines = ["# RQE Fix Plan", "", "Generated from the latest audit.", ""]
    if not failed:
        lines.extend(["No failing evidence found. The project is ready for release review.", ""])
    else:
        lines.extend([f"{len(failed)} finding(s) require attention:", ""])
        for item in failed:
            lines.extend([
                f"## [{item.severity.upper()}] `{item.probe}`",
                "",
                item.message,
                "",
                f"Evidence: `{item.id}`",
                f"Details: `{item.details}`",
                "",
                "Suggested action: reproduce the probe in Studio, apply the smallest server-authoritative fix, then run `python rqe.py verify .`.",
                "",
            ])
    path.write_text("\n".join(lines), encoding="utf-8")
    return path

