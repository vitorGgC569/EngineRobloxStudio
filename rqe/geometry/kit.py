"""A coherent kit of authored meshes, and the rule for what earns one.

The complaint this answers: Blender works and is not used at anything like the
scale needed to stop the world looking like primitives. That was not a Blender
problem. It was that a `.glb` cannot be loaded at runtime, so every asset the
director planned arrived permanently "pending" and every object fell back to the
Part it could always have been.

With `WorldKit.Mesh` that chain is gone, and the question becomes the one the
Asset Director should have been answering all along: *which* things deserve
authored geometry.

**The rule, and it is about repetition and silhouette, not about importance
alone.** A thing earns a mesh when its outline is what identifies it and a
player will look straight at it. A thing keeps its Parts when it is modular,
repeated at many scales, or read as a surface rather than a shape:

  mesh        tree, rock, crate, barrel, lamp head, banner finial, objective
              -- outlines a player reads at a glance, each placed hundreds of
              times from one cached mesh
  WorldKit    walls, buildings, towers, terraces -- modular, sized per region,
              and a single 20,000-triangle blob where a kit belongs
  Parts       ground, paving, panels -- surfaces, not shapes

**Budget is the constraint that shapes the kit.** Runtime meshes ship as source
in the place file and are rebuilt on every client, so this is a low-poly kit by
necessity -- 300 to 1,600 triangles each. That is not a compromise for a
stylised Roblox game; it is roughly what a shipped one uses, and it is far more
silhouette than the 8-part tree it replaces.

Nothing here names siegehold. The kit is keyed by the same role vocabulary the
world grammar already uses, so a farm gets the same crate and a space station
gets the same lamp with a different palette on it.
"""

from __future__ import annotations

from typing import Any, Iterable


class KitError(ValueError):
    """A kit entry could not be planned."""


#: Which backend a role gets, and why. Read as the Asset Director's decision
#: table -- the thing that was previously implicit in whichever code path ran.
BACKEND_BY_ROLE: dict[str, str] = {
    "vegetation": "blender",
    "rock": "blender",
    "prop": "blender",
    "collectible": "blender",
    "objective": "blender",
    "machine": "blender",
    "hero": "blender",
    # Modular by nature. A building is a kit of parts sized to its plot, and a
    # mesh of one is a mesh of exactly one building.
    "structure": "worldkit",
    "wall": "worldkit",
    "tower": "worldkit",
    "terrace": "worldkit",
    # Surfaces. A mesh would be a very expensive way to draw a floor.
    "ground": "parts",
    "paving": "parts",
}


def backend_for(role: str, *, available: Iterable[str] = ()) -> str:
    """Which backend builds this role, after asking whether it must be built.

    Two questions used to be answered in two places. This one asked "Blender,
    WorldKit or Parts"; `rqe.sourcing.decide` asked "reuse, adapt or generate".
    Both are the Asset Director's job and a factory whose two halves can
    disagree about the same asset will eventually ship whichever answered last.

    Sourcing runs first because it can remove the question. A tree that a CC0
    library already publishes does not need a modelling program, a triangle
    budget or a debugging cycle -- and the one this factory authored took all
    three and then shipped invisible, which is the argument in a sentence.

    `available` is what a connector reported it can actually supply. Empty means
    nothing was found or nothing was asked, and the answer falls through to the
    backends below -- never to a refusal, because a factory that stops when a
    download fails is worse than one that builds its own barrel.
    """

    from ..sourcing import decide

    verdict = decide(role, role=role, kind="geometry", available=available)
    if verdict.action in ("reuse", "adapt"):
        return "sourced:" + verdict.source
    return BACKEND_BY_ROLE.get(role, "parts")


def _slots(dark: list[int], light: list[int], accent: list[int]) -> list[dict[str, Any]]:
    return [
        {"name": "dark", "baseColor": dark, "roughness": 0.9},
        {"name": "light", "baseColor": light, "roughness": 0.55},
        {"name": "accent", "baseColor": accent, "roughness": 0.35},
    ]


def _finish(name: str, targets: list[str], budget: int) -> list[dict[str, Any]]:
    return [
        {"op": "join", "name": "asset", "targets": targets},
        {"op": "uv_unwrap", "target": "asset"},
        {"op": "decimate", "target": "asset", "triangleBudget": budget},
    ]


def tree(entry: dict[str, Any]) -> list[dict[str, Any]]:
    """A trunk that tapers and a crown built from three offset masses.

    The Part version is a stack of cylinders and spheres, and it reads as a
    stack of cylinders and spheres. What a mesh buys here is a silhouette with
    no repeated horizontal seam in it -- the single most visible tell in a
    generated forest, because a forest is where repetition is most obvious.
    """

    height = entry.get("height", 22.0)
    spread = entry.get("spread", 9.0)
    steps: list[dict[str, Any]] = [
        # A cone with a flat top, not a cylinder with a taper op: the
        # interpreter has no taper, and `radiusTop` is the same shape with one
        # primitive instead of two operations.
        {"op": "cone", "name": "trunk", "radius": spread * 0.13,
         "radiusTop": spread * 0.075, "depth": height * 0.62, "vertices": 8,
         "location": [0, 0, height * 0.31]},
        {"op": "bevel", "target": "trunk", "width": spread * 0.012, "segments": 2},
        {"op": "sphere", "name": "crownA", "radius": spread * 0.5,
         "location": [0, 0, height * 0.74]},
        {"op": "sphere", "name": "crownB", "radius": spread * 0.36,
         "location": [spread * 0.22, spread * 0.13, height * 0.62]},
        {"op": "sphere", "name": "crownC", "radius": spread * 0.31,
         "location": [-spread * 0.2, -spread * 0.15, height * 0.86]},
        {"op": "box", "name": "bough",
         "size": [spread * 0.55, spread * 0.06, spread * 0.06],
         "location": [spread * 0.2, 0, height * 0.56]},
        {"op": "material", "target": "trunk", "assign": 0,
         "slots": _slots([58, 44, 34], [96, 132, 68], [138, 170, 86])},
        {"op": "material", "target": "crownA", "assign": 1,
         "slots": _slots([58, 44, 34], [96, 132, 68], [138, 170, 86])},
        {"op": "material", "target": "crownB", "assign": 2,
         "slots": _slots([58, 44, 34], [96, 132, 68], [138, 170, 86])},
        {"op": "material", "target": "crownC", "assign": 1,
         "slots": _slots([58, 44, 34], [96, 132, 68], [138, 170, 86])},
        {"op": "material", "target": "bough", "assign": 0,
         "slots": _slots([58, 44, 34], [96, 132, 68], [138, 170, 86])},
    ]
    return steps + _finish("tree", ["trunk", "crownA", "crownB", "crownC", "bough"],
                           entry.get("triangleBudget", 900))


def rock(entry: dict[str, Any]) -> list[dict[str, Any]]:
    """Three intersecting masses, bevelled hard.

    Rocks are where a Part world gives itself away most cheaply: a rock is a
    shape with no right angles, and every Part has twelve.
    """

    size = entry.get("size", 6.0)
    steps: list[dict[str, Any]] = [
        {"op": "sphere", "name": "massA", "radius": size * 0.5, "location": [0, 0, size * 0.32]},
        {"op": "sphere", "name": "massB", "radius": size * 0.34,
         "location": [size * 0.28, size * 0.16, size * 0.2]},
        {"op": "sphere", "name": "massC", "radius": size * 0.26,
         "location": [-size * 0.24, -size * 0.2, size * 0.42]},
        {"op": "bevel", "target": "massA", "width": size * 0.05, "segments": 1},
        {"op": "material", "target": "massA", "assign": 0,
         "slots": _slots([72, 76, 84], [126, 130, 138], [158, 162, 170])},
        {"op": "material", "target": "massB", "assign": 1,
         "slots": _slots([72, 76, 84], [126, 130, 138], [158, 162, 170])},
        {"op": "material", "target": "massC", "assign": 0,
         "slots": _slots([72, 76, 84], [126, 130, 138], [158, 162, 170])},
    ]
    return steps + _finish("rock", ["massA", "massB", "massC"],
                           entry.get("triangleBudget", 420))


def crate(entry: dict[str, Any]) -> list[dict[str, Any]]:
    """A box with a frame around it, which is the whole point.

    A crate as a Part is a cube and reads as a placeholder. A crate with corner
    bracing and a lid lip reads as an object somebody made, and it costs 300
    triangles.
    """

    side = entry.get("side", 4.0)
    steps: list[dict[str, Any]] = [
        {"op": "box", "name": "body", "size": [side, side, side * 0.92],
         "location": [0, 0, side * 0.46]},
        {"op": "bevel", "target": "body", "width": side * 0.03, "segments": 2},
        {"op": "box", "name": "lip", "size": [side * 1.06, side * 1.06, side * 0.1],
         "location": [0, 0, side * 0.9]},
        {"op": "box", "name": "brace", "size": [side * 0.1, side * 1.04, side * 0.1],
         "location": [side * 0.45, 0, side * 0.46]},
        {"op": "array_radial", "target": "brace", "count": 4, "axis": "Z"},
        {"op": "material", "target": "body", "assign": 1,
         "slots": _slots([64, 48, 32], [148, 112, 72], [214, 176, 96])},
        {"op": "material", "target": "lip", "assign": 0,
         "slots": _slots([64, 48, 32], [148, 112, 72], [214, 176, 96])},
        {"op": "material", "target": "brace", "assign": 0,
         "slots": _slots([64, 48, 32], [148, 112, 72], [214, 176, 96])},
    ]
    return steps + _finish("crate", ["body", "lip", "brace"],
                           entry.get("triangleBudget", 520))


def barrel(entry: dict[str, Any]) -> list[dict[str, Any]]:
    """A bulged cylinder with hoops. The bulge is what a Part cannot do."""

    height = entry.get("height", 5.0)
    radius = entry.get("radius", 1.7)
    steps: list[dict[str, Any]] = [
        # The bulge is a sphere squashed along its axis. A cylinder cannot
        # have one, and the bulge is the entire reason a barrel is not a can.
        {"op": "sphere", "name": "body", "radius": radius * 1.18,
         "rings": 10, "segments": 14, "location": [0, 0, height * 0.5]},
        {"op": "scale", "target": "body", "factor": [1.0, 1.0, height / (radius * 2.36)]},
        {"op": "bevel", "target": "body", "width": radius * 0.06, "segments": 2},
        {"op": "torus", "name": "hoop", "majorRadius": radius * 1.04,
         "minorRadius": radius * 0.07, "majorSegments": 14, "minorSegments": 6,
         "location": [0, 0, height * 0.26]},
        {"op": "array_linear", "target": "hoop", "count": 3,
         "offset": [0, 0, height * 0.24]},
        {"op": "material", "target": "body", "assign": 1,
         "slots": _slots([48, 38, 30], [136, 100, 64], [176, 150, 96])},
        {"op": "material", "target": "hoop", "assign": 0,
         "slots": _slots([48, 38, 30], [136, 100, 64], [176, 150, 96])},
    ]
    return steps + _finish("barrel", ["body", "hoop"], entry.get("triangleBudget", 640))


def objective(entry: dict[str, Any]) -> list[dict[str, Any]]:
    """The thing the game is about, whatever the genre calls it.

    A crystal to defend, a core to power, a prize to reach. Faceted rather than
    smooth so it catches the key light from every angle, on a plinth so it sits
    in the world instead of hovering over it.
    """

    height = entry.get("height", 14.0)
    radius = entry.get("radius", 3.4)
    steps: list[dict[str, Any]] = [
        {"op": "cylinder", "name": "plinth", "radius": radius * 1.5,
         "depth": height * 0.16, "location": [0, 0, height * 0.08]},
        {"op": "bevel", "target": "plinth", "width": radius * 0.1, "segments": 3},
        # Six sides, not smooth: a faceted shard catches the key light as
        # distinct planes, which is what makes it read as crystal rather than
        # as a traffic cone.
        {"op": "cone", "name": "shard", "radius": radius, "radiusTop": radius * 0.42,
         "depth": height * 0.5, "vertices": 6, "location": [0, 0, height * 0.42]},
        {"op": "cone", "name": "cap", "radius": radius * 0.42, "depth": height * 0.34,
         "vertices": 6, "location": [0, 0, height * 0.84]},
        {"op": "box", "name": "buttress", "size": [radius * 0.22, radius * 0.5, height * 0.3],
         "location": [radius * 1.1, 0, height * 0.2]},
        {"op": "array_radial", "target": "buttress", "count": 3, "axis": "Z"},
        {"op": "material", "target": "plinth", "assign": 0,
         "slots": _slots([60, 64, 74], [150, 156, 166], [236, 196, 96])},
        {"op": "material", "target": "shard", "assign": 2,
         "slots": _slots([60, 64, 74], [150, 156, 166], [236, 196, 96])},
        {"op": "material", "target": "cap", "assign": 2,
         "slots": _slots([60, 64, 74], [150, 156, 166], [236, 196, 96])},
        {"op": "material", "target": "buttress", "assign": 0,
         "slots": _slots([60, 64, 74], [150, 156, 166], [236, 196, 96])},
    ]
    return steps + _finish("objective", ["plinth", "shard", "cap", "buttress"],
                           entry.get("triangleBudget", 1200))


#: The kit. One entry per thing a world places many of, plus the objective.
#:
#: Keyed by the same names `WorldKit.Props.build` already accepts, so the world
#: template asks for "tree" and gets a mesh where one exists and the Part
#: version where it does not -- no branch in the caller, and no game named here.
BUILDERS = {
    "tree": tree,
    "rock": rock,
    "crate": crate,
    "barrel": barrel,
    "objective": objective,
}

#: What a game gets by default. A kit, not a hero: five assets that between them
#: cover most of what a player looks at in any genre.
DEFAULT_KIT = ("tree", "rock", "crate", "barrel", "objective")


def program(name: str, **entry: Any) -> dict[str, Any]:
    """The modelling program for one kit entry."""

    builder = BUILDERS.get(name)
    if builder is None:
        raise KitError(
            f"no kit entry named {name!r}; the kit is "
            + ", ".join(sorted(BUILDERS))
        )
    return {
        "schemaVersion": 1,
        "id": name,
        "units": "studs",
        "result": "asset",
        "steps": builder(entry),
    }


def plan(names: tuple[str, ...] = DEFAULT_KIT) -> list[dict[str, Any]]:
    """Every program in the kit, in build order."""

    return [program(name) for name in names]
