from __future__ import annotations

import json
from pathlib import Path

from rqe.scenario import scenario_document_issues

ROOT = Path(__file__).resolve().parents[1]


def test_release_scenario_bindings_match_each_game_contract() -> None:
    for config_path in sorted((ROOT / "games").glob("*/rqe.project.json")):
        project_root = config_path.parent
        config = json.loads(config_path.read_text(encoding="utf-8"))
        release_scenarios = config.get("releaseScenarios") or []
        assert isinstance(release_scenarios, list), f"{config_path}: releaseScenarios must be an array"
        if not release_scenarios:
            continue

        visual_path = project_root / str(config["visualContract"] if "visualContract" in config else "contracts/visual/visual-quality.json")
        visual = json.loads(visual_path.read_text(encoding="utf-8"))
        visual_scenarios = {
            str(state.get("scenario"))
            for state in visual.get("evaluationStates", {}).values()
            if isinstance(state, dict) and state.get("scenario")
        }

        contract_path = project_root / str(config["contract"])
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        requirements = {
            str(item["id"]): item
            for item in contract.get("requirements", [])
            if isinstance(item, dict) and item.get("id")
        }

        seen_evidence: set[str] = set()
        for relative in release_scenarios:
            assert isinstance(relative, str) and relative.strip(), f"{config_path}: invalid release scenario path"
            assert relative not in visual_scenarios, (
                f"{config_path}: {relative} is both a visual evaluation scenario and an additional release scenario"
            )
            scenario_path = (project_root / relative).resolve()
            scenario_path.relative_to(project_root.resolve())
            assert scenario_path.is_file(), f"missing release scenario: {scenario_path}"
            scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
            assert scenario_document_issues(scenario) == [], f"{scenario_path}: malformed scenario document"

            for binding in scenario.get("releaseEvidence", []):
                evidence_id = str(binding["id"])
                assert evidence_id not in seen_evidence, f"duplicate release evidence id: {evidence_id}"
                seen_evidence.add(evidence_id)
                requirement = requirements.get(evidence_id)
                assert requirement is not None, f"{scenario_path}: unknown contract evidence id {evidence_id!r}"
                assert binding["probe"] == requirement["probe"], f"{scenario_path}: probe drift for {evidence_id}"
                assert binding["category"] == requirement["category"], f"{scenario_path}: category drift for {evidence_id}"
                assert binding["severity"] == requirement["severity"], f"{scenario_path}: severity drift for {evidence_id}"
