"""Modelling programs by gameplay role.

The asset director asks for meshes and nothing builds them. It plans a
`kit-plot` machine at 20,000 triangles and an `objective` hero at 20,000, both
routed to Blender, and the chain stops there: the plan is data, the geometry
pipeline needs a *program*, and no stage writes one. So every game the factory
makes ships with its 3D assets permanently "still to build".

This closes it with one program per role rather than one per asset. A role is
what the director already reasons in -- hero, machine, structure, prop -- and it
is the right grain: two machines in the same game should look like siblings, and
a hero should not look like a scaled-up prop.

The programs are parameterised by the brief, not templated from it. Dimensions,
triangle budget and material count come from the brief the director produced, so
a 20,000-triangle hero and a 2,000-triangle prop run the same code and arrive at
different meshes. What stays fixed is the *grammar*: a hero has a base, a body,
a crown and radial detail; a machine has a chassis, a working part and vents.
That is what makes a set read as one art direction rather than as five
generators.

None of this replaces authoring. A program written for a specific asset will
beat these every time, and the visual critic will say so -- these exist because
"a generated placeholder nobody built" and "a mesh the pipeline actually made,
scored, and can revise" are different states, and only the second one improves.
"""

from __future__ import annotations

from typing import Any


class ProgramError(ValueError):
    """No program could be written for this brief."""


#: Palette entries by role, as the modelling program's material slots.
#: Deliberately three: a dark, a light and an accent is the minimum that reads
#: as separated at distance, and the material validator predicts the critic's
#: luminance spread from exactly this.
def _slots(materials: tuple[str, ...]) -> list[dict[str, Any]]:
    names = list(materials) + ["dark", "light", "accent"]
    return [
        {"name": names[0], "baseColor": [58, 62, 72], "roughness": 0.85},
        {"name": names[1], "baseColor": [198, 194, 186], "roughness": 0.45, "metallic": 0.3},
        {"name": names[2], "baseColor": [232, 176, 72], "roughness": 0.25,
         "emissive": [255, 208, 120], "emissiveStrength": 2.5},
    ]


def _material(target: str, slot: int, materials: tuple[str, ...]) -> dict[str, Any]:
    return {"op": "material", "target": target, "assign": slot, "slots": _slots(materials)}


def hero(brief: Any) -> dict[str, Any]:
    """A landmark: base, tapering body, crown, and radial buttresses.

    Radial rather than rectilinear because a hero is looked at from every side.
    A shape with a front is a shape with three backs, and a landmark placed in
    the middle of a plaza shows all of them.
    """

    width, height, depth = brief.dimensions
    radius = min(width, depth) / 2
    steps = []

    steps.append({"op": "cylinder", "name": "base", "radius": radius,
                  "depth": height * 0.16, "location": [0, 0, height * 0.08]})
    steps.append({"op": "bevel", "target": "base", "width": radius * 0.06, "segments": 3})

    steps.append({"op": "cylinder", "name": "body", "radius": radius * 0.62,
                  "depth": height * 0.6, "location": [0, 0, height * 0.46]})
    steps.append({"op": "bevel", "target": "body", "width": radius * 0.04, "segments": 2})

    steps.append({"op": "cylinder", "name": "crown", "radius": radius * 0.82,
                  "depth": height * 0.1, "location": [0, 0, height * 0.81]})
    steps.append({"op": "bevel", "target": "crown", "width": radius * 0.05, "segments": 3})

    steps.append({"op": "sphere", "name": "finial", "radius": radius * 0.34,
                  "location": [0, 0, height * 0.95]})

    # Buttresses: the silhouette detail. A smooth cylinder reads as a pipe at
    # any size; six vertical breaks read as built.
    steps.append({"op": "box", "name": "buttress",
                  "size": [radius * 0.14, radius * 0.3, height * 0.55],
                  "location": [radius * 0.55, 0, height * 0.42]})
    steps.append({"op": "bevel", "target": "buttress", "width": radius * 0.02, "segments": 2})
    steps.append({"op": "array_radial", "target": "buttress", "count": 6, "axis": "Z"})

    materials = tuple(brief.materials)
    steps.append(_material("base", 0, materials))
    steps.append(_material("body", 1, materials))
    steps.append(_material("crown", 0, materials))
    steps.append(_material("finial", 2, materials))
    steps.append(_material("buttress", 0, materials))

    steps.append({"op": "join", "name": "asset",
                  "targets": ["base", "body", "crown", "finial", "buttress"]})
    steps.append({"op": "uv_unwrap", "target": "asset"})
    steps.append({"op": "decimate", "target": "asset", "triangleBudget": brief.triangle_budget})
    return {"schemaVersion": 1, "id": brief.id, "units": "studs",
            "result": "asset", "steps": steps}


def machine(brief: Any) -> dict[str, Any]:
    """A working object: chassis, a moving part, vents and pipes.

    Asymmetric on purpose. A machine that reads the same from front and back has
    no front, and a player cannot tell which side to walk up to.
    """

    width, height, depth = brief.dimensions
    steps = []

    steps.append({"op": "box", "name": "chassis", "size": [width, depth, height * 0.42],
                  "location": [0, 0, height * 0.21]})
    steps.append({"op": "bevel", "target": "chassis", "width": min(width, depth) * 0.03,
                  "segments": 2})

    steps.append({"op": "cylinder", "name": "drum", "radius": min(width, depth) * 0.3,
                  "depth": height * 0.58, "location": [0, 0, height * 0.71]})
    steps.append({"op": "bevel", "target": "drum", "width": 0.05, "segments": 2})

    # Vents on one face only: the asymmetry that gives the object a front.
    steps.append({"op": "box", "name": "vent",
                  "size": [width * 0.1, depth * 0.06, height * 0.2],
                  "location": [-width * 0.3, -depth * 0.5, height * 0.24]})
    steps.append({"op": "array_linear", "target": "vent", "count": 5,
                  "offset": [width * 0.15, 0, 0]})

    steps.append({"op": "cylinder", "name": "pipe", "radius": min(width, depth) * 0.07,
                  "depth": height * 0.5, "location": [width * 0.38, depth * 0.3, height * 0.4]})

    steps.append({"op": "box", "name": "panel",
                  "size": [width * 0.42, depth * 0.05, height * 0.18],
                  "location": [0, depth * 0.5, height * 0.28]})
    steps.append({"op": "bevel", "target": "panel", "width": 0.03, "segments": 1})

    materials = tuple(brief.materials)
    steps.append(_material("chassis", 0, materials))
    steps.append(_material("drum", 1, materials))
    steps.append(_material("vent", 0, materials))
    steps.append(_material("pipe", 1, materials))
    steps.append(_material("panel", 2, materials))

    steps.append({"op": "join", "name": "asset",
                  "targets": ["chassis", "drum", "vent", "pipe", "panel"]})
    steps.append({"op": "uv_unwrap", "target": "asset"})
    steps.append({"op": "decimate", "target": "asset", "triangleBudget": brief.triangle_budget})
    return {"schemaVersion": 1, "id": brief.id, "units": "studs",
            "result": "asset", "steps": steps}


def prop(brief: Any) -> dict[str, Any]:
    """A small object: body, rim, foot. Three masses, because two is a box."""

    width, height, depth = brief.dimensions
    steps = [
        {"op": "box", "name": "body", "size": [width, depth, height * 0.7],
         "location": [0, 0, height * 0.35]},
        {"op": "bevel", "target": "body", "width": min(width, depth) * 0.06, "segments": 2},
        {"op": "box", "name": "rim", "size": [width * 1.08, depth * 1.08, height * 0.1],
         "location": [0, 0, height * 0.72]},
        {"op": "box", "name": "foot", "size": [width * 0.9, depth * 0.9, height * 0.08],
         "location": [0, 0, height * 0.04]},
    ]
    materials = tuple(brief.materials)
    steps.append(_material("body", 1, materials))
    steps.append(_material("rim", 0, materials))
    steps.append(_material("foot", 0, materials))
    steps.append({"op": "join", "name": "asset", "targets": ["body", "rim", "foot"]})
    steps.append({"op": "uv_unwrap", "target": "asset"})
    steps.append({"op": "decimate", "target": "asset", "triangleBudget": brief.triangle_budget})
    return {"schemaVersion": 1, "id": brief.id, "units": "studs",
            "result": "asset", "steps": steps}


#: Which program a role gets. `structure` routes to WorldKit rather than here,
#: so it is absent on purpose: a modular building kit assembled from parts is
#: not a mesh, and giving it one would produce a single 20,000-triangle blob
#: where a kit should be.
#: The structural kit lives in its own module: it is a different grammar --
#: modular pieces that must meet on a grid, rather than one-off objects -- and
#: mixing the two here would hide that.
from .structural import BY_ROLE as _STRUCTURAL

BY_ROLE = {
    "hero": hero,
    "machine": machine,
    "prop": prop,
    "collectible": prop,
    "vegetation": prop,
    **_STRUCTURAL,
}


def program_for(brief: Any) -> dict[str, Any]:
    """The modelling program this brief's role implies."""

    builder = BY_ROLE.get(brief.gameplay_role)
    if builder is None:
        raise ProgramError(
            f"no program for role {brief.gameplay_role!r}; roles with one: "
            + ", ".join(sorted(BY_ROLE))
            + ". A role routed to a mesh backend with no program is an asset the "
            "plan promises and nothing builds"
        )
    return builder(brief)
