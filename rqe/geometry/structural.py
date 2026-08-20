"""The modular kit: walls, floors, members and roofs.

The parts manifest counts fifty pieces worth authoring and the engine had five
programs, none of them structural. That is the wrong five: props can be bought
under CC0 from Kenney and Quaternius, and a bought wall is useless because it
does not land on this project's grid. A kit whose pieces do not meet is not a
kit -- it is a pile of props.

**One program per role, variants by silhouette.** `programs.py` already argues
for role-grain rather than asset-grain, and that holds here: every wall in a
game should read as the same wall with a hole in it. So `wall` handles solid,
doorway, window and parapet, and the four share a profile, a thickness and a
bevel. Change the grammar once and the whole set moves together.

**Everything snaps.** Dimensions are rounded to the module before anything is
built, because the entire value of a kit is that two pieces meet with no gap. A
wall 12.3 studs wide is not slightly wrong, it is unusable -- the error repeats
at every join and accumulates along a corridor.

**Openings are cut, not implied.** A doorway is a boolean difference against a
real solid, which is what `fab_aperture` already proves at runtime. A dark
rectangle painted on a wall is the single clearest tell that a place is a
greybox, and it survives every later fix because nothing downstream can tell it
is not a hole.
"""

from __future__ import annotations

from typing import Any

from .programs import ProgramError, _material, _slots


#: The grid everything lands on, in studs.
#:
#: Four is Roblox's terrain voxel and a common building module, which means a
#: wall built to it meets terrain sculpted to it. Picking a different number
#: here would make the two families disagree at every boundary.
MODULE = 4.0


def _snap(value: float, module: float = MODULE, minimum: float = 1.0) -> float:
    """Round to the module, never to zero."""

    snapped = round(value / module) * module
    return max(snapped, minimum)


def _finish(steps: list[dict[str, Any]], brief: Any, parts: list[str]) -> dict[str, Any]:
    """Unwrap, decimate, and hand back a program.

    Every program ends the same way on purpose: the differences between a wall
    and a column belong in the grammar above, not in how they are packaged.

    **A single part is not joined.** The program validator refuses
    `join` with one target -- correctly, since joining one object does nothing
    and almost always means a part was named wrong. A solid wall genuinely is
    one object, so it becomes the result directly rather than being wrapped.
    """

    if len(parts) > 1:
        result = "asset"
        steps.append({"op": "join", "name": result, "targets": parts})
    else:
        result = parts[0]

    steps.append({"op": "uv_unwrap", "target": result})
    steps.append({"op": "decimate", "target": result,
                  "triangleBudget": brief.triangle_budget})
    return {"schemaVersion": 1, "id": brief.id, "units": "studs",
            "result": result, "steps": steps}


def _cut(steps: list[dict[str, Any]], target: str, name: str,
         size: list[float], location: list[float]) -> None:
    """Subtract a box from `target`. The tool is consumed."""

    steps.append({"op": "box", "name": name, "size": size, "location": location})
    steps.append({"op": "boolean", "target": target, "tool": name,
                  "operation": "difference"})


def wall(brief: Any) -> dict[str, Any]:
    """A wall panel: solid, with a doorway, with a window, or waist height.

    The four are one shape with one subtraction, which is why they belong in a
    single program. A game whose door-walls and solid walls came from different
    generators has two thicknesses and two bevels, and the seam shows at every
    corner.
    """

    width, height, depth = brief.dimensions
    width = _snap(width, minimum=MODULE)
    height = _snap(height, minimum=MODULE)
    # Thickness is *not* snapped: it is a material property, not a module. A
    # wall snapped to 4 studs thick is a bunker.
    depth = max(min(depth, 2.0), 0.5)

    silhouette = (brief.silhouette or "solid").lower()
    steps: list[dict[str, Any]] = [
        {"op": "box", "name": "panel", "size": [width, depth, height],
         "location": [0, 0, height * 0.5]},
    ]

    if silhouette in ("doorway", "door"):
        opening_w = min(_snap(width * 0.4, module=1.0, minimum=3.0), width - MODULE)
        opening_h = min(height * 0.72, height - 1.0)
        # Cut deeper than the wall on both faces, or the boolean leaves a skin
        # a fraction of a stud thick that renders as a shimmering film.
        _cut(steps, "panel", "gap",
             [opening_w, depth * 3, opening_h], [0, 0, opening_h * 0.5])
    elif silhouette == "window":
        opening_w = min(_snap(width * 0.34, module=1.0, minimum=2.0), width - MODULE)
        opening_h = height * 0.36
        _cut(steps, "panel", "gap",
             [opening_w, depth * 3, opening_h], [0, 0, height * 0.58])
        steps.append({"op": "box", "name": "sill",
                      "size": [opening_w + 0.8, depth * 1.6, 0.35],
                      "location": [0, 0, height * 0.58 - opening_h * 0.5]})
        steps.append({"op": "bevel", "target": "sill", "width": 0.06, "segments": 2})
    elif silhouette == "parapet":
        steps[0]["size"] = [width, depth, height * 0.45]
        steps[0]["location"] = [0, 0, height * 0.225]
        steps.append({"op": "box", "name": "cap",
                      "size": [width, depth * 1.5, 0.4],
                      "location": [0, 0, height * 0.45]})
        steps.append({"op": "bevel", "target": "cap", "width": 0.08, "segments": 3})


    steps.append({"op": "bevel", "target": "panel", "width": 0.05, "segments": 2})

    parts = ["panel"]
    if silhouette == "window":
        parts.append("sill")
    elif silhouette == "parapet":
        parts.append("cap")

    for index, part in enumerate(parts):
        steps.append(_material(part, 0 if index == 0 else 1, brief.materials))
    return _finish(steps, brief, parts)


def floor(brief: Any) -> dict[str, Any]:
    """Ground the player walks on: a tile, paving, or a plaza slab.

    The largest surface in every screenshot and the one most often left flat.
    Paving is an array of smaller stones with gaps, which is what makes ground
    read as built rather than painted -- and it costs nothing but an array.
    """

    width, thickness, depth = brief.dimensions
    width = _snap(width, minimum=MODULE)
    depth = _snap(depth, minimum=MODULE)
    thickness = max(min(thickness, 1.5), 0.3)

    silhouette = (brief.silhouette or "tile").lower()
    steps: list[dict[str, Any]] = []
    parts: list[str] = []

    if silhouette == "tile":
        steps.append({"op": "box", "name": "slab",
                      "size": [width, depth, thickness], "location": [0, 0, 0]})
        steps.append({"op": "inset", "target": "slab", "thickness": 0.25})
        steps.append({"op": "bevel", "target": "slab", "width": 0.06, "segments": 2})
        parts = ["slab"]
    elif silhouette in ("paving", "cobble"):
        stone = MODULE * 0.5
        gap = 0.12
        across = max(int(width / (stone + gap)), 2)
        along = max(int(depth / (stone + gap)), 2)
        steps.append({"op": "box", "name": "stone",
                      "size": [stone - gap, stone - gap, thickness],
                      "location": [-(width - stone) * 0.5,
                                   -(depth - stone) * 0.5, 0]})
        steps.append({"op": "bevel", "target": "stone", "width": 0.07, "segments": 2})
        steps.append({"op": "array_linear", "target": "stone", "count": across,
                      "offset": [stone + gap, 0, 0]})
        steps.append({"op": "array_linear", "target": "stone", "count": along,
                      "offset": [0, stone + gap, 0]})
        parts = ["stone"]
    elif silhouette == "plaza":
        steps.append({"op": "box", "name": "slab",
                      "size": [width, depth, thickness], "location": [0, 0, 0]})
        steps.append({"op": "bevel", "target": "slab", "width": 0.1, "segments": 3})
        # A border reads the edge of a space, which is what a plaza is for.
        steps.append({"op": "box", "name": "border",
                      "size": [width * 0.86, depth * 0.86, thickness * 1.4],
                      "location": [0, 0, thickness * 0.1]})
        steps.append({"op": "boolean", "target": "slab", "tool": "border",
                      "operation": "difference"})
        steps.append({"op": "box", "name": "inner",
                      "size": [width * 0.86, depth * 0.86, thickness * 0.8],
                      "location": [0, 0, -thickness * 0.1]})
        steps.append({"op": "bevel", "target": "inner", "width": 0.06, "segments": 2})
        parts = ["slab", "inner"]
    else:
        raise ProgramError(f"{silhouette} is not a floor")

    for index, part in enumerate(parts):
        steps.append(_material(part, index % 2, brief.materials))
    return _finish(steps, brief, parts)


def _members(brief: Any) -> dict[str, Any]:
    """Linear members: column, beam, railing, arch, stair, ramp.

    Vertical rhythm is what turns a room into architecture, and all six are the
    same idea -- a profile repeated along an axis. That is why they share a
    program: the repetition interval has to agree across the set or a colonnade
    stops reading as one.
    """

    width, height, depth = brief.dimensions
    silhouette = (brief.silhouette or "column").lower()
    steps: list[dict[str, Any]] = []
    parts: list[str] = []

    if silhouette in ("column", "pillar"):
        radius = max(min(width, depth) * 0.5, 0.4)
        height = _snap(height, minimum=MODULE)
        steps.append({"op": "cylinder", "name": "shaft", "radius": radius * 0.78,
                      "depth": height * 0.84, "location": [0, 0, height * 0.5]})
        steps.append({"op": "box", "name": "base",
                      "size": [radius * 2.2, radius * 2.2, height * 0.08],
                      "location": [0, 0, height * 0.04]})
        steps.append({"op": "box", "name": "capital",
                      "size": [radius * 2.4, radius * 2.4, height * 0.08],
                      "location": [0, 0, height * 0.96]})
        for part in ("base", "capital"):
            steps.append({"op": "bevel", "target": part, "width": radius * 0.08,
                          "segments": 3})
        # Flutes: the detail that separates a column from a pipe, and pure
        # radial array work.
        steps.append({"op": "box", "name": "flute",
                      "size": [radius * 0.18, radius * 0.18, height * 0.7],
                      "location": [radius * 0.74, 0, height * 0.5]})
        steps.append({"op": "array_radial", "target": "flute", "count": 8,
                      "axis": "Z", "centre": [0, 0, height * 0.5]})
        steps.append({"op": "boolean", "target": "shaft", "tool": "flute",
                      "operation": "difference"})
        parts = ["shaft", "base", "capital"]

    elif silhouette in ("beam", "truss"):
        width = _snap(width, minimum=MODULE)
        thickness = max(min(height, depth), 0.4)
        steps.append({"op": "box", "name": "chord",
                      "size": [width, thickness, thickness * 0.4],
                      "location": [0, 0, thickness * 0.8]})
        steps.append({"op": "duplicate", "source": "chord", "name": "lower",
                      "location": [0, 0, -thickness * 0.8]})
        steps.append({"op": "box", "name": "web",
                      "size": [thickness * 0.3, thickness * 0.3, thickness * 1.6],
                      "location": [-(width * 0.5) + thickness, 0, 0]})
        steps.append({"op": "array_linear", "target": "web",
                      "count": max(int(width / (thickness * 2)), 2),
                      "offset": [thickness * 2, 0, 0]})
        for part in ("chord", "lower"):
            steps.append({"op": "bevel", "target": part, "width": 0.05, "segments": 2})
        parts = ["chord", "lower", "web"]

    elif silhouette == "railing":
        width = _snap(width, minimum=MODULE)
        height = max(height, 2.0)
        # Rotation belongs on the primitive: `box` and `cylinder` both take it,
        # and a separate `rotate` step turns one call into two for no gain.
        steps.append({"op": "cylinder", "name": "rail", "radius": 0.14,
                      "depth": width, "location": [0, 0, height],
                      "rotation": [0, 90, 0]})
        steps.append({"op": "cylinder", "name": "post", "radius": 0.1,
                      "depth": height, "location": [-(width * 0.5) + 0.5, 0, height * 0.5]})
        steps.append({"op": "array_linear", "target": "post",
                      "count": max(int(width / 1.6), 2), "offset": [1.6, 0, 0]})
        parts = ["rail", "post"]

    elif silhouette == "arch":
        width = _snap(width, minimum=MODULE * 2)
        height = _snap(height, minimum=MODULE)
        depth = max(depth, 1.0)
        steps.append({"op": "box", "name": "span",
                      "size": [width, depth, height],
                      "location": [0, 0, height * 0.5]})
        # Cut the opening with a cylinder so the head is a real curve. Without
        # a lathe op this is the only round arch available, and it is enough.
        steps.append({"op": "cylinder", "name": "bore", "radius": width * 0.34,
                      "depth": depth * 3, "location": [0, 0, height * 0.6],
                      "rotation": [90, 0, 0]})
        steps.append({"op": "boolean", "target": "span", "tool": "bore",
                      "operation": "difference"})
        _cut(steps, "span", "jamb",
             [width * 0.68, depth * 3, height * 0.6], [0, 0, height * 0.3])
        steps.append({"op": "bevel", "target": "span", "width": 0.06, "segments": 2})
        parts = ["span"]

    elif silhouette in ("stair", "steps"):
        width = _snap(width, minimum=MODULE)
        height = _snap(height, minimum=MODULE)
        rise = 1.0
        count = max(int(height / rise), 2)
        run = max(depth / count, 0.8)
        steps.append({"op": "box", "name": "tread",
                      "size": [width, run, rise],
                      "location": [0, -(depth * 0.5) + run * 0.5, rise * 0.5]})
        steps.append({"op": "bevel", "target": "tread", "width": 0.05, "segments": 2})
        steps.append({"op": "array_linear", "target": "tread", "count": count,
                      "offset": [0, run, rise]})
        parts = ["tread"]

    elif silhouette == "ramp":
        width = _snap(width, minimum=MODULE)
        steps.append({"op": "box", "name": "slope",
                      "size": [width, depth, height],
                      "location": [0, 0, height * 0.5]})
        # Cut the wedge with an oversized rotated box: no wedge primitive, and
        # a boolean against a rotated cutter is exact.
        tilt = -max(min(height / max(depth, 0.1) * 45, 60), 10)
        steps.append({"op": "box", "name": "cutter",
                      "size": [width * 1.4, depth * 2.2, height * 2.2],
                      "location": [0, depth * 0.35, height * 1.35],
                      "rotation": [tilt, 0, 0]})
        steps.append({"op": "boolean", "target": "slope", "tool": "cutter",
                      "operation": "difference"})
        steps.append({"op": "bevel", "target": "slope", "width": 0.05, "segments": 2})
        parts = ["slope"]

    else:
        raise ProgramError(f"{silhouette} is not a member")

    for index, part in enumerate(parts):
        steps.append(_material(part, index % 2, brief.materials))
    return _finish(steps, brief, parts)


def building(brief: Any) -> dict[str, Any]:
    """A roof panel: flat, pitched, or a corner.

    The piece that closes a building, and the one most often missing -- which is
    why so many generated places are open boxes seen from above.
    """

    width, height, depth = brief.dimensions
    width = _snap(width, minimum=MODULE)
    depth = _snap(depth, minimum=MODULE)
    silhouette = (brief.silhouette or "pitched").lower()

    steps: list[dict[str, Any]] = []
    if silhouette == "flat":
        steps.append({"op": "box", "name": "deck",
                      "size": [width, depth, 0.5], "location": [0, 0, 0]})
        steps.append({"op": "box", "name": "kerb",
                      "size": [width, depth, 0.9], "location": [0, 0, 0.3]})
        steps.append({"op": "box", "name": "well",
                      "size": [width - 1.2, depth - 1.2, 1.4], "location": [0, 0, 0.5]})
        steps.append({"op": "boolean", "target": "kerb", "tool": "well",
                      "operation": "difference"})
        steps.append({"op": "bevel", "target": "kerb", "width": 0.06, "segments": 2})
        parts = ["deck", "kerb"]
    elif silhouette in ("pitched", "gable"):
        pitch = max(height, 2.0)
        steps.append({"op": "box", "name": "slope",
                      "size": [width * 0.56, depth, 0.5],
                      "location": [-width * 0.24, 0, pitch * 0.5],
                      "rotation": [0, -32, 0]})
        # Mirrored about the ridge, so both slopes are the same object with the
        # same bevel and meet exactly. `centre` is not optional -- mirroring
        # about the origin when the ridge is elsewhere splits the roof.
        steps.append({"op": "mirror", "target": "slope", "axis": "X",
                      "centre": [0, 0, pitch * 0.5]})
        steps.append({"op": "box", "name": "ridge",
                      "size": [0.6, depth, 0.4], "location": [0, 0, pitch]})
        steps.append({"op": "bevel", "target": "ridge", "width": 0.08, "segments": 3})
        parts = ["slope", "ridge"]
    else:
        raise ProgramError(f"{silhouette} is not a roof")

    for index, part in enumerate(parts):
        steps.append(_material(part, index % 2, brief.materials))
    return _finish(steps, brief, parts)


#: Every structural silhouette, and which grammar builds it.
#:
#: `structure` is one gameplay role, not seven. The brief's role vocabulary
#: describes what a thing *does* in a game -- hero, machine, prop, structure --
#: and a wall, a floor and a column all do the same thing: they are the built
#: world. Widening that set to `wall` and `floor` would conflate a gameplay role
#: with a kind of geometry, and the two are not the same axis.
#:
#: So the role picks the family and the silhouette picks the piece, which is
#: also what makes a set read as one kit.
SILHOUETTES: dict[str, str] = {
    "solid": "wall", "doorway": "wall", "window": "wall", "parapet": "wall",
    "tile": "floor", "paving": "floor", "plaza": "floor",
    "column": "member", "beam": "member", "railing": "member",
    "arch": "member", "stair": "member", "ramp": "member",
    "flat": "roof", "pitched": "roof",
}

_FAMILIES = {"wall": wall, "floor": floor, "member": _members, "roof": building}


def structure(brief: Any) -> dict[str, Any]:
    """Anything the built world is made of, chosen by silhouette."""

    silhouette = (brief.silhouette or "solid").lower()
    family = SILHOUETTES.get(silhouette)
    if family is None:
        raise ProgramError(
            f"no structural silhouette {brief.silhouette!r}; have "
            + ", ".join(sorted(SILHOUETTES))
        )
    return _FAMILIES[family](brief)


BY_ROLE = {
    "structure": structure,
    # Ground is a floor with a different name for it.
    "terrain-feature": structure,
}
