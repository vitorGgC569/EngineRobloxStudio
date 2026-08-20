from __future__ import annotations

import re
from typing import Any

from .models import VALIDATION_LEVELS


REQUIRED_TOP_LEVEL = {"schemaVersion", "contractId", "game", "performance_budget", "visualQuality", "release_gate", "requirements"}
ALLOWED_TOP_LEVEL = REQUIRED_TOP_LEVEL | {"$schema", "productId", "productTruth"}
REQUIRED_GAME_FIELDS = {"name", "genre", "max_players", "target_devices"}
ALLOWED_GAME_FIELDS = REQUIRED_GAME_FIELDS
REQUIRED_REQUIREMENT_FIELDS = {"id", "probe", "type", "severity"}
ALLOWED_REQUIREMENT_FIELDS = REQUIRED_REQUIREMENT_FIELDS | {"category", "from", "to", "devices", "validation"}
ALLOWED_VALIDATION_FIELDS = {"minimum_level", "minimum_coverage", "maximum_age_seconds", "allowed_sources"}
VALID_SEVERITIES = {"critical", "major", "minor", "info"}
VALID_TYPES = {"structural", "security", "visual", "geometry", "gameplay", "scenario", "navigation", "ui", "runtime", "performance", "persistence", "multiplayer"}
VALID_DEVICES = {"desktop", "phone", "tablet", "console", "vr"}
ID_PATTERN = re.compile(r"^[a-z][a-z0-9._-]+$")


def _unknown_fields(value: dict[str, Any], allowed: set[str], label: str) -> list[str]:
    return [f"{label} has unknown field: {field}" for field in sorted(set(value) - allowed)]


def _fraction(value: Any) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float)) and 0 <= value <= 1


def validate_contract(contract: dict[str, Any]) -> list[str]:
    """Validate the release contract without relying on an optional dependency.

    The JSON Schema remains the editor/interchange definition; these semantic
    guards execute in every environment and fail on unknown fields so a typo can
    never weaken the release policy silently.
    """

    issues: list[str] = []
    if not isinstance(contract, dict):
        return ["contract must be an object"]
    issues.extend(_unknown_fields(contract, ALLOWED_TOP_LEVEL, "contract"))
    issues.extend(f"contract missing top-level field: {field}" for field in sorted(REQUIRED_TOP_LEVEL - set(contract)))
    if contract.get("schemaVersion") != 1:
        issues.append("contract.schemaVersion must equal 1")
    contract_id = contract.get("contractId")
    if not isinstance(contract_id, str) or not ID_PATTERN.fullmatch(contract_id):
        issues.append("contract.contractId must be a stable lowercase id")
    product_id = contract.get("productId")
    if product_id is not None and (
        not isinstance(product_id, str) or not ID_PATTERN.fullmatch(product_id)
    ):
        issues.append("contract.productId must be a stable lowercase id")

    game = contract.get("game", {})
    if not isinstance(game, dict):
        issues.append("contract.game must be an object")
    else:
        issues.extend(_unknown_fields(game, ALLOWED_GAME_FIELDS, "contract.game"))
        issues.extend(f"contract.game missing field: {field}" for field in sorted(REQUIRED_GAME_FIELDS - set(game)))
        if not isinstance(game.get("name"), str) or not game.get("name"):
            issues.append("contract.game.name must be a non-empty string")
        if not isinstance(game.get("genre"), str) or not game.get("genre"):
            issues.append("contract.game.genre must be a non-empty string")
        if not isinstance(game.get("max_players"), int) or isinstance(game.get("max_players"), bool) or game.get("max_players", 0) < 1:
            issues.append("contract.game.max_players must be a positive integer")
        devices = game.get("target_devices")
        if not isinstance(devices, list) or not devices or any(item not in VALID_DEVICES for item in devices):
            issues.append("contract.game.target_devices must contain supported device names")

    performance = contract.get("performance_budget")
    if not isinstance(performance, dict):
        issues.append("contract.performance_budget must be an object")
    else:
        client = performance.get("client")
        instances = performance.get("instances")
        mobile = performance.get("mobile")
        if not isinstance(client, dict) or not isinstance(client.get("target_fps"), (int, float)) or client.get("target_fps", 0) <= 0:
            issues.append("performance_budget.client.target_fps must be positive")
        if not isinstance(client, dict) or not isinstance(client.get("max_frame_ms"), (int, float)) or client.get("max_frame_ms", 0) <= 0:
            issues.append("performance_budget.client.max_frame_ms must be positive")
        if not isinstance(instances, dict) or not isinstance(instances.get("max_workspace"), int) or instances.get("max_workspace", 0) < 1:
            issues.append("performance_budget.instances.max_workspace must be a positive integer")
        if not isinstance(mobile, dict) or not isinstance(mobile.get("mandatory"), bool):
            issues.append("performance_budget.mobile.mandatory must be boolean")

    visual = contract.get("visualQuality")
    if not isinstance(visual, dict):
        issues.append("contract.visualQuality must be an object")
    else:
        expected = {"spec", "specId", "schemaMajor", "required", "release"}
        issues.extend(_unknown_fields(visual, expected, "contract.visualQuality"))
        if not isinstance(visual.get("spec"), str) or not visual.get("spec"):
            issues.append("visualQuality.spec must be a non-empty relative path")
        if not isinstance(visual.get("specId"), str) or not ID_PATTERN.fullmatch(str(visual.get("specId", ""))):
            issues.append("visualQuality.specId must be a stable lowercase id")
        if visual.get("schemaMajor") != 1:
            issues.append("visualQuality.schemaMajor must equal 1")
        if visual.get("required") is not True:
            issues.append("visualQuality.required must be true")
        release = visual.get("release")
        if not isinstance(release, dict):
            issues.append("visualQuality.release must be an object")
        else:
            if not isinstance(release.get("minimumScore"), (int, float)) or not 0 <= release.get("minimumScore", -1) <= 100:
                issues.append("visualQuality.release.minimumScore must be between 0 and 100")
            if not _fraction(release.get("minimumRuleCoverage")):
                issues.append("visualQuality.release.minimumRuleCoverage must be between 0 and 1")
            if release.get("minimumValidationLevel") != "VISUALLY_VALIDATED":
                issues.append("visualQuality.release.minimumValidationLevel must be VISUALLY_VALIDATED")
            if release.get("missingEvidence") != "FAIL":
                issues.append("visualQuality.release.missingEvidence must be FAIL")

    gate = contract.get("release_gate")
    if not isinstance(gate, dict):
        issues.append("contract.release_gate must be an object")
    else:
        allowed_gate = {"required_categories", "forbidden_sources", "minimum_requirement_coverage", "minimum_category_coverage", "minimum_validation_by_type", "maximum_evidence_age_seconds_by_level", "minimum_visual_score", "require_trustworthy_captures"}
        issues.extend(_unknown_fields(gate, allowed_gate, "contract.release_gate"))
        if not isinstance(gate.get("required_categories"), list) or not gate.get("required_categories"):
            issues.append("release_gate.required_categories must be a non-empty array")
        forbidden = gate.get("forbidden_sources")
        if not isinstance(forbidden, list) or "headless-runtime" not in forbidden:
            issues.append("release_gate.forbidden_sources must include headless-runtime")
        if not _fraction(gate.get("minimum_requirement_coverage")):
            issues.append("release_gate.minimum_requirement_coverage must be between 0 and 1")
        category_coverage = gate.get("minimum_category_coverage")
        if not isinstance(category_coverage, dict) or any(not _fraction(value) for value in category_coverage.values()):
            issues.append("release_gate.minimum_category_coverage values must be between 0 and 1")
        levels = gate.get("minimum_validation_by_type")
        if not isinstance(levels, dict) or any(value not in VALIDATION_LEVELS[1:] for value in levels.values()):
            issues.append("release_gate.minimum_validation_by_type contains an invalid level")
        ages = gate.get("maximum_evidence_age_seconds_by_level")
        positive_levels = set(VALIDATION_LEVELS[1:])
        if not isinstance(ages, dict) or set(ages) != positive_levels or any(
            isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0
            for value in (ages.values() if isinstance(ages, dict) else ())
        ):
            issues.append(
                "release_gate.maximum_evidence_age_seconds_by_level must define a positive TTL for every positive validation level"
            )
        if not isinstance(gate.get("minimum_visual_score"), (int, float)) or not 0 <= gate.get("minimum_visual_score", -1) <= 100:
            issues.append("release_gate.minimum_visual_score must be between 0 and 100")
        if not isinstance(gate.get("require_trustworthy_captures"), bool):
            issues.append("release_gate.require_trustworthy_captures must be boolean")

    requirements = contract.get("requirements", [])
    if not isinstance(requirements, list) or not requirements:
        return issues + ["contract.requirements must be a non-empty array"]

    seen: set[str] = set()
    for index, requirement in enumerate(requirements):
        label = f"requirements[{index}]"
        if not isinstance(requirement, dict):
            issues.append(f"{label} must be an object")
            continue
        issues.extend(_unknown_fields(requirement, ALLOWED_REQUIREMENT_FIELDS, label))
        missing_fields = REQUIRED_REQUIREMENT_FIELDS - set(requirement)
        issues.extend(f"{label} missing field: {field}" for field in sorted(missing_fields))
        req_id = requirement.get("id")
        if not isinstance(req_id, str) or not req_id:
            issues.append(f"{label}.id must be a non-empty string")
        elif req_id in seen:
            issues.append(f"duplicate requirement id: {req_id}")
        else:
            seen.add(req_id)
        if not isinstance(requirement.get("probe"), str) or not requirement.get("probe"):
            issues.append(f"{label}.probe must be a non-empty string")
        if requirement.get("type") not in VALID_TYPES:
            issues.append(f"{label}.type is invalid")
        if requirement.get("severity") not in VALID_SEVERITIES:
            issues.append(f"{label}.severity is invalid")
        validation = requirement.get("validation")
        if validation is not None:
            if not isinstance(validation, dict):
                issues.append(f"{label}.validation must be an object")
            else:
                issues.extend(_unknown_fields(validation, ALLOWED_VALIDATION_FIELDS, f"{label}.validation"))
                if "minimum_level" in validation and validation["minimum_level"] not in VALIDATION_LEVELS[1:]:
                    issues.append(f"{label}.validation.minimum_level is invalid")
                if "minimum_coverage" in validation and not _fraction(validation["minimum_coverage"]):
                    issues.append(f"{label}.validation.minimum_coverage must be between 0 and 1")
                allowed_sources = validation.get("allowed_sources")
                if allowed_sources is not None and (not isinstance(allowed_sources, list) or any(not isinstance(item, str) or not item for item in allowed_sources)):
                    issues.append(f"{label}.validation.allowed_sources must contain strings")

    truth = contract.get("productTruth")
    if truth is not None:
        if not isinstance(truth, dict):
            issues.append("contract.productTruth must be an object")
        else:
            issues.extend(_unknown_fields(
                truth, {"intentId", "semanticBindings"}, "contract.productTruth"
            ))
            intent_id = truth.get("intentId")
            if not isinstance(intent_id, str) or not ID_PATTERN.fullmatch(intent_id):
                issues.append("contract.productTruth.intentId must be a stable lowercase id")
            bindings = truth.get("semanticBindings")
            if not isinstance(bindings, dict):
                issues.append("contract.productTruth.semanticBindings must be an object")
            else:
                groups = {"worldRoles", "uiSurfaces", "gameplayVerbs"}
                issues.extend(_unknown_fields(
                    bindings, groups, "contract.productTruth.semanticBindings"
                ))
                for group in sorted(groups):
                    values = bindings.get(group)
                    label = f"contract.productTruth.semanticBindings.{group}"
                    if not isinstance(values, dict) or not values:
                        issues.append(f"{label} must be a non-empty object")
                        continue
                    for semantic_id, requirement_ids in values.items():
                        path = f"{label}.{semantic_id}"
                        if not isinstance(semantic_id, str) or not ID_PATTERN.fullmatch(semantic_id):
                            issues.append(f"{path} uses an invalid semantic id")
                        if (
                            not isinstance(requirement_ids, list)
                            or not requirement_ids
                            or any(not isinstance(item, str) or not item for item in requirement_ids)
                        ):
                            issues.append(f"{path} must name at least one requirement id")
                            continue
                        if len(requirement_ids) != len(set(requirement_ids)):
                            issues.append(f"{path} contains duplicate requirement ids")
                        unknown = sorted(set(requirement_ids) - seen)
                        if unknown:
                            issues.append(f"{path} names unknown requirements: {', '.join(unknown)}")
    return issues
