from __future__ import annotations

from collections import defaultdict
from typing import Any

from .models import Evidence


SEVERITY_WEIGHT = {"critical": 3, "major": 2, "minor": 1, "info": 0.5}

# These never come from a Studio measurement. A PASS stamped with one of them
# used to score 100, including the hand-written frameMs in game-state.json.
_NOT_STUDIO_SOURCES = frozenset({"headless-runtime", "fixture", "luau-runtime"})


def _counts_as_measurement(item: Evidence) -> bool:
    if item.validation_level == "NOT_VALIDATED":
        return False
    if item.source in _NOT_STUDIO_SOURCES:
        return False
    return True


def score_evidence(evidence: list[Evidence]) -> tuple[dict[str, float], dict[str, int], bool, list[str]]:
    buckets: dict[str, list[tuple[float, float]]] = defaultdict(list)
    # False means the category was probed, but nothing in it was measured.
    measured: dict[str, bool] = {}
    summary = {"executed": len(evidence), "PASS": 0, "WARN": 0, "FAIL": 0, "critical": 0, "major": 0, "minor": 0}
    for item in evidence:
        summary[item.status] += 1
        if item.status == "FAIL" and item.severity in {"critical", "major", "minor"}:
            summary[item.severity] += 1
        measured.setdefault(item.category, False)
        if not _counts_as_measurement(item):
            continue
        measured[item.category] = True
        weight = SEVERITY_WEIGHT[item.severity]
        if item.status == "PASS":
            score = 1.0
        elif item.status == "WARN":
            score = 0.7
        else:
            score = 0.0
        buckets[item.category].append((score * weight, weight))

    scores = {
        category: round(100 * sum(score for score, _ in values) / sum(weight for _, weight in values), 1)
        if sum(weight for _, weight in values)
        else 0.0
        for category, values in buckets.items()
    }
    for category, was_measured in measured.items():
        if not was_measured:
            scores[category] = 0.0
    reasons: list[str] = []
    if summary["critical"]:
        reasons.append(f"{summary['critical']} critical failure(s)")
    if summary["major"]:
        reasons.append(f"{summary['major']} major failure(s)")
    for category in ("performance", "geometry", "ui"):
        if category in measured and not measured[category]:
            reasons.append(f"{category} has no Studio measurement")
    if scores.get("gameplay", 0) < 95:
        reasons.append("gameplay score below 95")
    if scores.get("persistence", 0) < 100:
        reasons.append("persistence score below 100")
    if scores.get("multiplayer", 0) < 90:
        reasons.append("multiplayer score below 90")
    return scores, summary, not reasons, reasons
