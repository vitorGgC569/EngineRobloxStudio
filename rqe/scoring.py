from __future__ import annotations

from collections import defaultdict
from typing import Any

from .models import Evidence


SEVERITY_WEIGHT = {"critical": 3, "major": 2, "minor": 1, "info": 0.5}


def score_evidence(evidence: list[Evidence]) -> tuple[dict[str, float], dict[str, int], bool, list[str]]:
    buckets: dict[str, list[tuple[float, float]]] = defaultdict(list)
    summary = {"executed": len(evidence), "PASS": 0, "WARN": 0, "FAIL": 0, "critical": 0, "major": 0, "minor": 0}
    for item in evidence:
        summary[item.status] += 1
        if item.status == "FAIL" and item.severity in {"critical", "major", "minor"}:
            summary[item.severity] += 1
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
        else 100.0
        for category, values in buckets.items()
    }
    reasons: list[str] = []
    if summary["critical"]:
        reasons.append(f"{summary['critical']} critical failure(s)")
    if summary["major"]:
        reasons.append(f"{summary['major']} major failure(s)")
    if scores.get("gameplay", 0) < 95:
        reasons.append("gameplay score below 95")
    if scores.get("persistence", 0) < 100:
        reasons.append("persistence score below 100")
    if scores.get("multiplayer", 0) < 90:
        reasons.append("multiplayer score below 90")
    return scores, summary, not reasons, reasons
