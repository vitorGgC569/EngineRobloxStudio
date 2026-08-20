from __future__ import annotations

import json
from pathlib import Path

from .models import AuditReport


def write_reports(report: AuditReport, reports_dir: Path) -> tuple[Path, Path]:
    reports_dir.mkdir(parents=True, exist_ok=True)
    payload = report.to_dict()
    json_path = reports_dir / "latest.json"
    md_path = reports_dir / "latest.md"
    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    lines = [
        "# Roblox Quality Engine",
        "",
        f"Projeto: `{report.project}`",
        f"Gerado: `{report.generated_at}`",
        "",
        "## Resultado",
        "",
        f"- Checks executados: **{report.summary['executed']}**",
        f"- PASS: **{report.summary['PASS']}**",
        f"- WARN: **{report.summary['WARN']}**",
        f"- FAIL: **{report.summary['FAIL']}**",
        f"- Release: **{'ALLOWED' if report.release_allowed else 'BLOCKED'}**",
        "",
        "## Scores",
        "",
    ]
    for category, score in sorted(report.scores.items()):
        lines.append(f"- {category}: **{score:.1f}/100**")
    lines.extend(["", "## Evidências", "", "| Status | Severidade | Probe | Mensagem |", "|---|---|---|---|"])
    for item in report.evidence:
        lines.append(f"| {item.status} | {item.severity} | `{item.probe}` | {item.message} |")
    if report.release_reasons:
        lines.extend(["", "## Bloqueios", ""])
        lines.extend(f"- {reason}" for reason in report.release_reasons)
    lines.extend(["", "## Runtime scenario trace", "", "```json", json.dumps(report.runtime_trace, indent=2, ensure_ascii=False), "```", ""])
    lines.extend(["## Game Agent Bridge", "", f"- Scenario: **{report.agent_session.get('scenario', 'n/a')}**", f"- Status: **{report.agent_session.get('status', 'n/a')}**", f"- Steps: **{report.agent_session.get('stepsExecuted', 0)}**", ""])
    md_path.write_text("\n".join(lines), encoding="utf-8")
    return json_path, md_path


def terminal_summary(report: AuditReport) -> str:
    status = "ALLOWED" if report.release_allowed else "BLOCKED"
    lines = [
        "ROBLOX QUALITY ENGINE",
        "",
        f"{report.summary['executed']} checks executed",
        f"PASS    {report.summary['PASS']}",
        f"WARN    {report.summary['WARN']}",
        f"FAIL    {report.summary['FAIL']}",
        "",
        f"CRITICAL failures: {report.summary['critical']}",
        f"MAJOR failures:    {report.summary['major']}",
        f"MINOR failures:    {report.summary['minor']}",
        "",
    ]
    lines.extend(f"{category.title():15} {score:5.1f}/100" for category, score in sorted(report.scores.items()))
    lines.extend(["", f"Release: {status}"])
    if report.release_reasons:
        lines.extend(f"- {reason}" for reason in report.release_reasons)
    return "\n".join(lines)
