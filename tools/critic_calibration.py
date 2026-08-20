"""Rebuild the reference ladder the visual critic is calibrated against.

The thresholds in `rqe/geometry/critic.py` claim to come from references whose
quality was known before anything was measured, rather than from any asset the
critic judges. This script is what makes that claim checkable: it rebuilds the
four rungs and reports what they measure now, so a drift in Blender, in the
render settings or in the metrics shows up as a ladder that no longer orders
rather than as a critic that quietly stopped discriminating.

The ladder is ordered worst to best *by construction*, before measurement:

    l0  a bare cube                  no silhouette, no detail, one flat material
    l1  the same volume articulated  silhouette only
    l2  l1 with three materials      isolates material separation exactly
    l3  a detailed machine           ribs, vents, a rear panel, pipes

A bare cube is definitionally an unmodelled asset. If a metric cannot separate
it from the machine, the metric is wrong -- not the asset.

    python tools/critic_calibration.py

Needs Blender. Takes a couple of minutes.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from rqe.geometry.brief import AssetBrief
from rqe.geometry.critic import CALIBRATION, critique_package
from rqe.geometry.pipeline import GeometryPipeline

OUT = ROOT / ".tmp" / "geometry" / "calibration"

DARK = {"name": "dark", "baseColor": [30, 32, 38], "roughness": 0.9}
LIGHT = {"name": "light", "baseColor": [205, 200, 190], "roughness": 0.4, "metallic": 0.3}
GLOW = {"name": "glow", "baseColor": [70, 150, 240], "roughness": 0.2,
        "emissive": [90, 180, 255], "emissiveStrength": 4.0}
GREY = {"name": "grey", "baseColor": [140, 143, 148], "roughness": 0.6}


def mat(target, slot):
    return {"op": "material", "target": target, "slots": [slot]}


def program(steps, result):
    return {"schemaVersion": 1, "id": "cal", "units": "studs", "result": result, "steps": steps}


#: The ladder. Ordered worst to best *by construction*, before any measurement.
LADDER = {
    # A cube. No silhouette interest, no detail, one flat material. If this
    # scores well the metric is measuring nothing.
    "l0_bare_box": program([
        {"op": "box", "name": "body", "size": [4.0, 4.0, 4.0], "location": [0, 0, 2.0]},
        mat("body", GREY),
        {"op": "uv_unwrap", "target": "body"},
    ], "body"),

    # Still one material, but the outline is no longer a rectangle. Isolates
    # silhouette shape from everything else.
    "l1_beveled_stack": program([
        {"op": "box", "name": "body", "size": [4.0, 4.0, 1.2], "location": [0, 0, 0.6]},
        {"op": "box", "name": "mid", "size": [2.6, 2.6, 2.0], "location": [0, 0, 2.2]},
        {"op": "cylinder", "name": "top", "radius": 0.8, "depth": 1.6, "location": [0, 0, 4.0]},
        {"op": "bevel", "target": "body", "width": 0.06, "segments": 2},
        {"op": "bevel", "target": "mid", "width": 0.06, "segments": 2},
        mat("body", GREY), mat("mid", GREY), mat("top", GREY),
        {"op": "join", "name": "asset", "targets": ["body", "mid", "top"]},
        {"op": "uv_unwrap", "target": "asset"},
    ], "asset"),

    # Same silhouette as l1, three materials with real value contrast, assigned
    # per part before the join. Isolates material separation: any difference
    # from l1 on that axis is the materials and nothing else.
    "l2_materials": program([
        {"op": "box", "name": "body", "size": [4.0, 4.0, 1.2], "location": [0, 0, 0.6]},
        {"op": "box", "name": "mid", "size": [2.6, 2.6, 2.0], "location": [0, 0, 2.2]},
        {"op": "cylinder", "name": "top", "radius": 0.8, "depth": 1.6, "location": [0, 0, 4.0]},
        {"op": "bevel", "target": "body", "width": 0.06, "segments": 2},
        {"op": "bevel", "target": "mid", "width": 0.06, "segments": 2},
        mat("body", DARK), mat("mid", LIGHT), mat("top", GLOW),
        {"op": "join", "name": "asset", "targets": ["body", "mid", "top"]},
        {"op": "uv_unwrap", "target": "asset"},
    ], "asset"),

    # Surface detail on every side: ribs, vents, a rear panel, pipes.
    # Definitionally a modelled asset. The floors must sit below this.
    "l3_detailed": program([
        {"op": "box", "name": "body", "size": [4.0, 3.0, 1.4], "location": [0, 0, 0.7]},
        {"op": "bevel", "target": "body", "width": 0.06, "segments": 2},
        {"op": "box", "name": "mid", "size": [2.4, 2.2, 2.2], "location": [0, 0, 2.4]},
        {"op": "bevel", "target": "mid", "width": 0.05, "segments": 2},
        {"op": "cylinder", "name": "core", "radius": 0.75, "depth": 2.0, "location": [0, 0, 4.4]},
        {"op": "box", "name": "rib", "size": [0.16, 3.1, 0.45], "location": [-0.9, 0, 1.5]},
        {"op": "array_linear", "target": "rib", "count": 5, "offset": [0.45, 0, 0]},
        {"op": "box", "name": "vent", "size": [0.18, 0.14, 0.85], "location": [-0.85, -1.16, 2.4]},
        {"op": "array_linear", "target": "vent", "count": 6, "offset": [0.34, 0, 0]},
        {"op": "box", "name": "rear", "size": [1.6, 0.16, 1.2], "location": [0, 1.16, 2.4]},
        {"op": "bevel", "target": "rear", "width": 0.03, "segments": 1},
        {"op": "box", "name": "rearvent", "size": [1.3, 0.1, 0.12], "location": [0, 1.26, 1.9]},
        {"op": "array_linear", "target": "rearvent", "count": 3, "offset": [0, 0, 0.3]},
        {"op": "cylinder", "name": "pipe", "radius": 0.13, "depth": 2.4, "location": [1.35, 0.7, 1.7]},
        {"op": "cylinder", "name": "pipe2", "radius": 0.13, "depth": 2.4, "location": [-1.35, 0.7, 1.7]},
        mat("body", DARK), mat("mid", LIGHT), mat("core", GLOW), mat("rib", DARK),
        mat("vent", DARK), mat("rear", LIGHT), mat("rearvent", DARK),
        mat("pipe", LIGHT), mat("pipe2", LIGHT),
        {"op": "join", "name": "asset",
         "targets": ["body", "mid", "core", "rib", "vent", "rear", "rearvent", "pipe", "pipe2"]},
        {"op": "uv_unwrap", "target": "asset"},
    ], "asset"),
}

BRIEFS = {
    "l0_bare_box": ("a plain cube", ("grey",)),
    "l1_beveled_stack": ("a stepped stack narrowing upward", ("grey",)),
    "l2_materials": ("a stepped stack narrowing upward", ("dark", "light", "glow")),
    "l3_detailed": ("wide base with vertical core, ribbed flanks", ("dark", "light", "glow")),
}


#: Each rung's true extents, so a dimension check does not block a build whose
#: geometry is exactly what this script intended.
DIMENSIONS = {
    "l0_bare_box": (4.0, 4.0, 4.0),
    "l1_beveled_stack": (4.0, 4.8, 4.0),
    "l2_materials": (4.0, 4.8, 4.0),
    "l3_detailed": (4.0, 5.4, 3.1),
}

#: What each metric must do across the ladder for the critic to mean anything.
ORDERING = ("silhouetteShape", "luminanceSpread", "focalContrast", "edgeDensity")


def main() -> int:
    pipeline = GeometryPipeline(workspace=OUT)
    results = {}
    measured: dict[str, dict[str, float]] = {}

    for name, document in LADDER.items():
        silhouette, materials = BRIEFS[name]
        brief = AssetBrief(
            id=name,
            dimensions=DIMENSIONS[name],
            style="stylized sci-fi",
            silhouette=silhouette,
            materials=materials,
            triangle_budget=16000,
            gameplay_role="machine",
        )
        print("--- building " + name, flush=True)
        outcome = pipeline.build(brief, dict(document, id=name))
        print("    " + outcome.status, flush=True)
        for blocker in (outcome.blockers or []):
            print("    blocker: " + blocker, flush=True)
        results[name] = outcome.to_dict()

        if outcome.package is not None and outcome.package.previews():
            report = critique_package(outcome.package)
            views = [v for v in report.measurements if not v.startswith("_")]
            measured[name] = {
                key: sum(report.measurements[v][key] for v in views) / len(views)
                for key in ORDERING
            }
            measured[name]["overall"] = report.overall

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "ladder.json").write_text(json.dumps(results, indent=2), encoding="utf-8")

    if len(measured) < len(LADDER):
        print("")
        print("NOT ALL RUNGS BUILT -- the ladder cannot be checked.")
        return 1

    order = list(LADDER)
    print("")
    print(f"{'metric':<18}" + "".join(f"{n[:12]:>13}" for n in order) + "     recorded")
    ok = True
    for metric in ORDERING:
        row = [measured[name][metric] for name in order]
        holds = row[-1] > row[0]
        ok = ok and holds
        mark = "" if holds else "   <-- NO LONGER ORDERS"
        print(f"{metric:<18}" + "".join(f"{v:>13.4f}" for v in row)
              + "     " + " ".join(str(v) for v in CALIBRATION[metric]) + mark)
    print(f"{'overall':<18}" + "".join(f"{measured[n]['overall']:>13.1f}" for n in order))

    # The ladder is the critic's whole authority. If it stops ordering, the
    # thresholds are measuring something other than what they claim, and that
    # should fail loudly here rather than be discovered as a run of assets that
    # all scored 90.
    print("")
    print("ladder orders: " + ("yes" if ok else "NO"))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
