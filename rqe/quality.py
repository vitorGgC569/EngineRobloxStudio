"""Deterministic visual-quality rules over a raw Studio snapshot.

The Studio plugin reports geometry and sampled ray outcomes.  Policy stays in
Python: thresholds come exclusively from the versioned visual spec and every
rule emits independently admissible release evidence.
"""

from __future__ import annotations

import colorsys
import math
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from statistics import median
from typing import Any, Iterable

from .models import Evidence
from .project import Project, read_json
from .provenance import sha256_json
from .schema_validation import validate_schema_instance
from .visual_spec import VisualQualitySpec


SOURCE = "studio-quality-validator"
LEVEL = "RUNTIME_VALIDATED"


def _dot(a: Iterable[float], b: Iterable[float]) -> float:
    return sum(float(x) * float(y) for x, y in zip(a, b))


def _sub(a: Iterable[float], b: Iterable[float]) -> tuple[float, float, float]:
    values = tuple(float(x) - float(y) for x, y in zip(a, b))
    return values[0], values[1], values[2]


def _percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def _inside_obb(point: list[float], obb: dict[str, Any]) -> bool:
    delta = _sub(point, obb["center"])
    for axis_name, size in zip(("right", "up", "back"), obb["size"]):
        if abs(_dot(delta, obb[axis_name])) > float(size) / 2 + 1e-6:
            return False
    return True


def _inside_horizontal(point: tuple[float, float, float], obb: dict[str, Any]) -> bool:
    delta = _sub(point, obb["center"])
    for axis_name, size in (("right", obb["size"][0]), ("back", obb["size"][2])):
        axis = obb[axis_name]
        horizontal = (float(axis[0]), 0.0, float(axis[2]))
        length = math.hypot(horizontal[0], horizontal[2])
        if length <= 1e-9:
            return False
        normalized = (horizontal[0] / length, 0.0, horizontal[2] / length)
        if abs(_dot(delta, normalized)) > float(size) / 2 + 1e-6:
            return False
    return True


def _region_roots(region: dict[str, Any], roots: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [root for root in roots if _inside_obb(root["obb"]["center"], region["obb"])]


def _footprint_coverage(
    region: dict[str, Any], roots: list[dict[str, Any]], samples_per_axis: int = 32
) -> float:
    """Measure OBB footprint union with a deterministic region-local grid."""

    if not roots:
        return 0.0
    obb = region["obb"]
    center = obb["center"]
    right = obb["right"]
    back = obb["back"]
    size_x, _, size_z = (float(item) for item in obb["size"])
    covered = 0
    total = samples_per_axis * samples_per_axis
    for xi in range(samples_per_axis):
        local_x = ((xi + 0.5) / samples_per_axis - 0.5) * size_x
        for zi in range(samples_per_axis):
            local_z = ((zi + 0.5) / samples_per_axis - 0.5) * size_z
            point = (
                float(center[0]) + float(right[0]) * local_x + float(back[0]) * local_z,
                float(center[1]),
                float(center[2]) + float(right[2]) * local_x + float(back[2]) * local_z,
            )
            if any(_inside_horizontal(point, root["obb"]) for root in roots):
                covered += 1
    return covered / total


def _srgb_channel(value: int) -> float:
    channel = value / 255
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def _rgb_to_lab(rgb: Iterable[int]) -> tuple[float, float, float]:
    r, g, b = (_srgb_channel(int(value)) for value in rgb)
    x = (r * 0.4124564 + g * 0.3575761 + b * 0.1804375) / 0.95047
    y = (r * 0.2126729 + g * 0.7151522 + b * 0.0721750) / 1.0
    z = (r * 0.0193339 + g * 0.1191920 + b * 0.9503041) / 1.08883

    def pivot(value: float) -> float:
        delta = 6 / 29
        return value ** (1 / 3) if value > delta ** 3 else value / (3 * delta ** 2) + 4 / 29

    fx, fy, fz = pivot(x), pivot(y), pivot(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def _delta_e_2000(first: tuple[float, float, float], second: tuple[float, float, float]) -> float:
    """CIEDE2000, kL=kC=kH=1 (Sharma/Wu/Dalal reference equations)."""

    l1, a1, b1 = first
    l2, a2, b2 = second
    c1 = math.hypot(a1, b1)
    c2 = math.hypot(a2, b2)
    c_bar = (c1 + c2) / 2
    g = 0.5 * (1 - math.sqrt(c_bar ** 7 / (c_bar ** 7 + 25 ** 7)))
    ap1, ap2 = (1 + g) * a1, (1 + g) * a2
    cp1, cp2 = math.hypot(ap1, b1), math.hypot(ap2, b2)

    def hue(a: float, b: float) -> float:
        angle = math.degrees(math.atan2(b, a))
        return angle + 360 if angle < 0 else angle

    hp1, hp2 = hue(ap1, b1), hue(ap2, b2)
    dl = l2 - l1
    dc = cp2 - cp1
    if cp1 * cp2 == 0:
        dh_degrees = 0.0
    elif abs(hp2 - hp1) <= 180:
        dh_degrees = hp2 - hp1
    elif hp2 <= hp1:
        dh_degrees = hp2 - hp1 + 360
    else:
        dh_degrees = hp2 - hp1 - 360
    dh = 2 * math.sqrt(cp1 * cp2) * math.sin(math.radians(dh_degrees / 2))
    l_bar = (l1 + l2) / 2
    cp_bar = (cp1 + cp2) / 2
    if cp1 * cp2 == 0:
        hp_bar = hp1 + hp2
    elif abs(hp1 - hp2) <= 180:
        hp_bar = (hp1 + hp2) / 2
    elif hp1 + hp2 < 360:
        hp_bar = (hp1 + hp2 + 360) / 2
    else:
        hp_bar = (hp1 + hp2 - 360) / 2
    t = (
        1
        - 0.17 * math.cos(math.radians(hp_bar - 30))
        + 0.24 * math.cos(math.radians(2 * hp_bar))
        + 0.32 * math.cos(math.radians(3 * hp_bar + 6))
        - 0.20 * math.cos(math.radians(4 * hp_bar - 63))
    )
    delta_theta = 30 * math.exp(-((hp_bar - 275) / 25) ** 2)
    rc = 2 * math.sqrt(cp_bar ** 7 / (cp_bar ** 7 + 25 ** 7))
    sl = 1 + 0.015 * (l_bar - 50) ** 2 / math.sqrt(20 + (l_bar - 50) ** 2)
    sc = 1 + 0.045 * cp_bar
    sh = 1 + 0.015 * cp_bar * t
    rt = -math.sin(math.radians(2 * delta_theta)) * rc
    return math.sqrt((dl / sl) ** 2 + (dc / sc) ** 2 + (dh / sh) ** 2 + rt * (dc / sc) * (dh / sh))


def _relative_mad(values: list[float]) -> float:
    middle = median(values)
    if middle <= 0:
        return math.inf
    return median(abs(value - middle) for value in values) / middle


def _entropy(values: list[str]) -> float:
    if not values:
        return 0.0
    counts = Counter(values)
    total = len(values)
    return -sum((count / total) * math.log2(count / total) for count in counts.values())


def _max_run(values: list[str]) -> int:
    longest = current = 0
    previous: str | None = None
    for value in values:
        current = current + 1 if value == previous else 1
        longest = max(longest, current)
        previous = value
    return longest


def _evidence(
    probe: str,
    passed: bool,
    details: dict[str, Any],
    *,
    run_id: str,
    build_hash: str,
    observed_at: str,
    severity: str = "major",
    conclusive: bool = True,
    truncated: bool = False,
) -> Evidence:
    return Evidence(
        id=f"quality.{probe}",
        probe=probe,
        category="visual",
        status="PASS" if passed else "FAIL",
        severity=severity,
        message=f"{probe} {'met' if passed else 'did not meet'} the visual quality contract",
        source=SOURCE,
        validation_level=LEVEL,
        details=details,
        observed_at=observed_at,
        run_id=run_id,
        build_hash=build_hash,
        coverage=1.0 if conclusive and not truncated else 0.0,
        conclusive=conclusive,
        truncated=truncated,
    )


def evaluate_quality_snapshot(
    project: Project,
    spec: VisualQualitySpec,
    snapshot: dict[str, Any],
    *,
    run_id: str,
    build_hash: str,
    observed_at: str | None = None,
) -> list[Evidence]:
    """Evaluate every deterministic rule represented by a Studio snapshot."""

    schema = read_json(project.root / "schemas/quality-snapshot.v1.schema.json")
    shape_issues = validate_schema_instance(snapshot, schema)
    timestamp = observed_at or datetime.now(timezone.utc).isoformat()
    if shape_issues:
        return [_evidence(
            "visual.classification.coverage",
            False,
            {"schemaIssues": [str(issue) for issue in shape_issues]},
            run_id=run_id,
            build_hash=build_hash,
            observed_at=timestamp,
            severity="critical",
            conclusive=False,
        )]

    snapshot_hash = sha256_json(snapshot)
    truncated = bool(snapshot["truncated"])
    conclusive = not truncated
    roots = snapshot["roots"]
    regions = snapshot["regions"]
    output: list[Evidence] = []
    common = {
        "run_id": run_id,
        "build_hash": build_hash,
        "observed_at": timestamp,
        "conclusive": conclusive,
        "truncated": truncated,
    }

    classification = snapshot["classification"]
    eligible = classification["eligible"]
    classified = classification["classified"]
    fraction = classified / eligible if eligible else 0.0
    threshold = spec.data["classification"]["minimumClassifiedFraction"]
    output.append(_evidence(
        "visual.classification.coverage",
        eligible > 0 and classified <= eligible and fraction >= threshold,
        {"eligible": eligible, "classified": classified, "fraction": fraction, "minimum": threshold, "snapshotHash": snapshot_hash},
        severity="critical",
        **common,
    ))

    palette = spec.data["palette"]
    swatches = [(item["id"], _rgb_to_lab(item["rgb"])) for item in palette["swatches"]]
    off_weight = total_weight = 0.0
    distances: list[dict[str, Any]] = []
    for root in roots:
        for entry in root["colors"]:
            weight = float(entry["surfaceArea"])
            nearest_id, distance = min(
                ((identifier, _delta_e_2000(_rgb_to_lab(entry["rgb"]), lab)) for identifier, lab in swatches),
                key=lambda item: item[1],
            )
            total_weight += weight
            if distance > palette["maximumDeltaE"]:
                off_weight += weight
            distances.append({"rgb": entry["rgb"], "nearest": nearest_id, "deltaE": round(distance, 4), "surfaceArea": weight})
    off_fraction = off_weight / total_weight if total_weight else 1.0
    output.append(_evidence(
        "visual.palette.conformance",
        total_weight > 0 and off_fraction <= palette["maximumOffPaletteFraction"],
        {"offPaletteFraction": off_fraction, "maximum": palette["maximumOffPaletteFraction"], "samples": distances, "snapshotHash": snapshot_hash},
        **common,
    ))

    for type_id, definition in spec.data["objectTypes"].items():
        selected = [root for root in roots if root["type"] == type_id]
        minimum = definition["minimumInstances"]
        maximum = definition.get("maximumInstances")
        cardinality_pass = len(selected) >= minimum and (maximum is None or len(selected) <= maximum)
        output.append(_evidence(
            f"visual.object.{type_id}.cardinality",
            cardinality_pass,
            {"count": len(selected), "minimum": minimum, "maximum": maximum, "refs": [item["ref"] for item in selected], "snapshotHash": snapshot_hash},
            **common,
        ))

        scale = definition["scale"]
        violations: list[dict[str, Any]] = []
        for root in selected:
            for axis, value, low, high in zip("XYZ", root["obb"]["size"], scale["minimumSize"], scale["maximumSize"]):
                if value < low or value > high:
                    violations.append({"ref": root["ref"], "axis": axis, "value": value, "minimum": low, "maximum": high})
        groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for root in selected:
            groups[root["variant"]].append(root)
        evaluated_groups = {key: value for key, value in groups.items() if len(value) >= 3}
        if not evaluated_groups and selected:
            evaluated_groups = {"__all__": selected}
        mad_results: list[dict[str, Any]] = []
        for group_id, members in evaluated_groups.items():
            for index, axis in enumerate("XYZ"):
                relative = _relative_mad([float(item["obb"]["size"][index]) for item in members])
                mad_results.append({"group": group_id, "axis": axis, "relativeMad": relative, "count": len(members)})
        mad_ok = all(item["relativeMad"] <= scale["maximumRelativeMad"] for item in mad_results)
        output.append(_evidence(
            f"visual.object.{type_id}.scale",
            bool(selected) and not violations and mad_ok,
            {"boundsMethod": "oriented-box", "violations": violations, "relativeMad": mad_results, "maximumRelativeMad": scale["maximumRelativeMad"], "snapshotHash": snapshot_hash},
            **common,
        ))

    for set_id, region_set in spec.data["regionSets"].items():
        selected_regions = [region for region in regions if region["profile"] == region_set["profile"]]
        cardinality_ok = region_set["minimumRegions"] <= len(selected_regions) <= region_set["maximumRegions"]
        output.append(_evidence(
            f"visual.region.{set_id}.cardinality",
            cardinality_ok,
            {"count": len(selected_regions), "minimum": region_set["minimumRegions"], "maximum": region_set["maximumRegions"], "refs": [item["ref"] for item in selected_regions], "snapshotHash": snapshot_hash},
            **common,
        ))
        profile = spec.data["regionProfiles"][region_set["profile"]]
        density_rows: list[dict[str, Any]] = []
        height_rows: list[dict[str, Any]] = []
        material_rows: list[dict[str, Any]] = []
        repetition_rows: list[dict[str, Any]] = []
        for region in selected_regions:
            members = _region_roots(region, roots)
            size = region["obb"]["size"]
            area = float(size[0]) * float(size[2])
            density = len(members) * 1000 / area if area else math.inf
            footprint = _footprint_coverage(region, members)
            density_rows.append({"regionRef": region["ref"], "roots": len(members), "area": area, "rootsPer1000": density, "footprintCoverage": footprint, "samplingGrid": [32, 32]})

            tops = [float(item["obb"]["center"][1]) + float(item["obb"]["size"][1]) / 2 for item in members]
            spread = _percentile(tops, 0.9) - _percentile(tops, 0.1) if tops else 0.0
            height_rows.append({"regionRef": region["ref"], "p90MinusP10": spread, "samples": len(tops)})

            material_weights: Counter[str] = Counter()
            for item in members:
                for material in item["materials"]:
                    material_weights[material["name"]] += float(material["surfaceArea"])
            total_material = sum(material_weights.values())
            dominant = max(material_weights.values(), default=0) / total_material if total_material else 1.0
            material_rows.append({"regionRef": region["ref"], "distinct": len(material_weights), "dominantFraction": dominant, "surfaceAreaByMaterial": dict(material_weights)})

            obb = region["obb"]
            ordered = sorted(
                members,
                key=lambda item: (
                    round(_dot(_sub(item["obb"]["center"], obb["center"]), obb["back"]), 4),
                    round(_dot(_sub(item["obb"]["center"], obb["center"]), obb["right"]), 4),
                    item["ref"],
                ),
            )
            variants = [item["variant"] for item in ordered]
            repetition_rows.append({"regionRef": region["ref"], "maximumIdenticalVariantRun": _max_run(variants), "variantEntropy": _entropy(variants), "orderedRefs": [item["ref"] for item in ordered]})

        density_policy = profile["density"]
        density_ok = bool(density_rows) and all(
            density_policy["minimumRootsPer1000SquareStuds"] <= row["rootsPer1000"] <= density_policy["maximumRootsPer1000SquareStuds"]
            and row["footprintCoverage"] >= density_policy["minimumFootprintCoverage"]
            for row in density_rows
        )
        output.append(_evidence(f"visual.region.{set_id}.density", density_ok, {"regions": density_rows, "policy": density_policy, "snapshotHash": snapshot_hash}, **common))

        height_policy = profile["heightVariation"]
        height_ok = bool(height_rows) and all(height_policy["minimumP90MinusP10"] <= row["p90MinusP10"] <= height_policy["maximumP90MinusP10"] for row in height_rows)
        output.append(_evidence(f"visual.region.{set_id}.height-variation", height_ok, {"regions": height_rows, "policy": height_policy, "snapshotHash": snapshot_hash}, **common))

        material_policy = profile["materialVariety"]
        material_ok = bool(material_rows) and all(row["distinct"] >= material_policy["minimumDistinctMaterials"] and row["dominantFraction"] <= material_policy["maximumDominantFraction"] for row in material_rows)
        output.append(_evidence(f"visual.region.{set_id}.material-variety", material_ok, {"regions": material_rows, "policy": material_policy, "snapshotHash": snapshot_hash}, **common))

        repetition_policy = profile["repetition"]
        repetition_ok = bool(repetition_rows) and all(row["maximumIdenticalVariantRun"] <= repetition_policy["maximumIdenticalVariantRun"] and row["variantEntropy"] >= repetition_policy["minimumVariantEntropy"] for row in repetition_rows)
        output.append(_evidence(f"visual.region.{set_id}.repetition", repetition_ok, {"regions": repetition_rows, "policy": repetition_policy, "snapshotHash": snapshot_hash}, **common))

    for landmark_id, policy in spec.data["landmarks"].items():
        rows = [item for item in snapshot["visibility"] if item["landmarkId"] == landmark_id]
        acceptable = [
            item for item in rows
            if item["conclusive"]
            and item["visibleFraction"] >= policy["minimumVisibleAnchorFraction"]
            and item["maximumBlindSpotDegrees"] <= policy["maximumBlindSpotDegrees"]
        ]
        passed = len(acceptable) >= policy["minimumRegionsVisibleFrom"]
        output.append(_evidence(
            f"visual.landmark.{landmark_id}.visibility",
            passed,
            {"regionsMeasured": rows, "acceptableRegions": len(acceptable), "minimumRegions": policy["minimumRegionsVisibleFrom"], "snapshotHash": snapshot_hash},
            **common,
        ))
    return output

