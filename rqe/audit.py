from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .contract import validate_contract
from .bridge.adapters import HeadlessGameAdapter
from .bridge.core import GameAgentBridge
from .models import AuditReport, Evidence
from .project import Project
from .probes import PROBE_CATALOG, run_probes
from .runtime import MvpGameRuntime, run_luau_scenario
from .scanner import scan_structure
from .scoring import score_evidence


def run_audit(root: str | Path) -> AuditReport:
    project = Project.load(root)
    evidence, static_scan = scan_structure(project)
    contract_issues = validate_contract(project.contract)
    evidence.append(Evidence(
        id="contract.schema",
        probe="contract_schema",
        category="structural",
        status="FAIL" if contract_issues else "PASS",
        severity="critical" if contract_issues else "info",
        message="Game Contract válido" if not contract_issues else "Game Contract inválido",
        details={"issues": contract_issues},
        source="contract-validator",
        validation_level="STATICALLY_VALIDATED",
    ))
    required_probes = {item.get("probe") for item in project.contract.get("requirements", [])}
    available_probes = {name for name, _, _ in PROBE_CATALOG}
    uncovered = sorted(required_probes - available_probes)
    evidence.append(Evidence(
        id="contract.probe_coverage",
        probe="contract_coverage",
        category="structural",
        status="FAIL" if uncovered else "PASS",
        severity="critical" if uncovered else "info",
        message="Cada requisito aponta para um probe executável" if not uncovered else "Há requisitos sem probe executável",
        details={"requiredProbes": sorted(required_probes), "uncovered": uncovered},
        source="probe-registry",
        validation_level="STATICALLY_VALIDATED",
    ))
    runtime_trace = run_luau_scenario(project.root)
    if runtime_trace is None:
        runtime = MvpGameRuntime()
        runtime_trace = runtime.run_purchase_scenario()
    evidence.extend(run_probes(project, runtime_trace, static_scan))
    scenario_path = project.root / project.config.get("agentScenario", "contracts/scenarios/purchase-first-pack.json")
    agent_bridge = GameAgentBridge(HeadlessGameAdapter(project), "blackbox")
    agent_session = agent_bridge.run_scenario(json.loads(scenario_path.read_text(encoding="utf-8")))
    evidence.append(Evidence(
        id="agent.scenario.purchase_first_pack",
        probe="agent_blackbox_scenario",
        category="gameplay",
        status="PASS" if agent_session.get("status") == "PASS" else "FAIL",
        severity="critical",
        message="the agent completed the human purchase flow" if agent_session.get("status") == "PASS" else "the agent could not complete the human flow",
        details={"scenario": agent_session.get("scenario"), "stepsExecuted": agent_session.get("stepsExecuted"), "actionRecords": agent_session.get("actionRecords", [])},
        source="game-agent-bridge",
        validation_level="NOT_VALIDATED",
    ))
    scores, summary, release_allowed, reasons = score_evidence(evidence)
    # This pipeline intentionally contains the historical fixture-backed probes
    # and the Python game reimplementation.  It remains useful for diagnostics,
    # but it is not admissible release evidence.  Only the compiled, immutable
    # `rqe release` run may make a release decision.
    if release_allowed:
        release_allowed = False
    reasons = [
        *reasons,
        "legacy audit is diagnostic only; fixture/headless evidence cannot release a build",
    ]
    return AuditReport(
        project=str(project.root),
        generated_at=datetime.now(timezone.utc).isoformat(),
        evidence=evidence,
        scores=scores,
        summary=summary,
        release_allowed=release_allowed,
        release_reasons=reasons,
        runtime_trace=runtime_trace,
        static_scan=static_scan,
        agent_session=agent_session,
    )
