"""World authoring: the agent describes a world, the engine composes the Luau.

WorldKit already implements blockout and dressing, and `sdk_run` already
executes Luau headlessly -- so the capability was reachable before this module
existed. It was reachable the wrong way. An agent had to *write Luau* to use it,
which is precisely what the MetaWorldModel document rules out:

    A IA fala em semântica de mundo, não: crie Part em X=143.53.

So the input here is a declarative spec -- regions with roles and footprints,
circulation between them, landmarks and the sightlines that must reach them --
and this module composes the WorldKit calls. The agent never writes a line of
Luau, and every rejection comes back as a sentence about the world rather than a
stack trace about a table.

**Planning is separate from building, and cheaper.** `plan` runs the spec
through `Blockout.validate` and the reachability walk in the headless harness:
no Studio, no place file, nothing built. A world whose spawn cannot reach half
its regions is knowable before a single Part exists, and finding that out after
building is how an hour gets spent on a layout that was never going to work.

**Nothing is invented.** The token set supplies the minimum room dimension, the
path widths and the scale grammar; this module passes the spec through and
reports what WorldKit says. A world authored against limits made up here would
look correct alone and wrong beside the rest of the game.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


class WorldSpecError(ValueError):
    """The world spec is not usable, and says which part."""


#: Region roles the dressing plan can address. Free-form in WorldKit, enumerated
#: here so a typo is caught while it is still a word rather than becoming an
#: undressed region nobody notices until the renders.
KNOWN_KINDS = (
    "plot", "plaza", "street", "shop", "landmark", "field",
    "interior", "arena", "corridor", "spawn", "decorative",
)


@dataclass(frozen=True)
class Region:
    id: str
    kind: str
    centre: tuple[float, float, float]
    size: tuple[float, float]
    spawn: bool = False
    elevation: float = 0.0

    def to_luau(self) -> str:
        return (
            "{{ id = {id}, kind = {kind}, centre = Vector3.new({cx}, {cy}, {cz}), "
            "size = Vector2.new({sx}, {sy}), spawn = {spawn}, elevation = {elev} }}"
        ).format(
            id=_lua_string(self.id), kind=_lua_string(self.kind),
            cx=self.centre[0], cy=self.centre[1], cz=self.centre[2],
            sx=self.size[0], sy=self.size[1],
            spawn="true" if self.spawn else "false", elev=self.elevation,
        )


@dataclass(frozen=True)
class Route:
    from_id: str
    to_id: str
    width: float | None = None

    def to_luau(self) -> str:
        width = f", width = {self.width}" if self.width is not None else ""
        return "{{ from = {a}, to = {b}{w} }}".format(
            a=_lua_string(self.from_id), b=_lua_string(self.to_id), w=width
        )


@dataclass(frozen=True)
class Landmark:
    id: str
    at: tuple[float, float, float]
    height: float
    visible_from: tuple[str, ...] = ()

    def to_luau(self) -> str:
        return (
            "{{ id = {id}, at = Vector3.new({x}, {y}, {z}), height = {h}, "
            "visibleFrom = {{{seen}}} }}"
        ).format(
            id=_lua_string(self.id), x=self.at[0], y=self.at[1], z=self.at[2],
            h=self.height, seen=", ".join(_lua_string(r) for r in self.visible_from),
        )


@dataclass
class WorldSpec:
    """What an agent says about a world, before anything is built."""

    id: str
    regions: tuple[Region, ...]
    circulation: tuple[Route, ...] = ()
    landmarks: tuple[Landmark, ...] = ()
    sightlines: tuple[tuple[str, str], ...] = ()

    def __post_init__(self) -> None:
        if not self.id:
            raise WorldSpecError("a world spec needs an id")
        if not self.regions:
            raise WorldSpecError("a world with no regions is not a world")

        seen: set[str] = set()
        for region in self.regions:
            if region.id in seen:
                raise WorldSpecError(f"region id {region.id!r} is declared twice")
            seen.add(region.id)
            if region.kind not in KNOWN_KINDS:
                raise WorldSpecError(
                    f"region {region.id!r} has kind {region.kind!r}; known kinds are "
                    + ", ".join(KNOWN_KINDS)
                    + ". A kind no dressing plan addresses becomes a region nobody dresses"
                )

        spawns = [r.id for r in self.regions if r.spawn]
        if len(spawns) != 1:
            # WorldKit says this too, but saying it here saves composing and
            # running Luau to be told something already visible in the spec.
            raise WorldSpecError(
                f"exactly one region must be the spawn; {len(spawns)} are marked"
                + (f" ({', '.join(spawns)})" if spawns else "")
            )

        for route in self.circulation:
            for end in (route.from_id, route.to_id):
                if end not in seen:
                    raise WorldSpecError(
                        f"circulation names region {end!r}, which the spec does not declare"
                    )
        for landmark in self.landmarks:
            for region in landmark.visible_from:
                if region not in seen:
                    raise WorldSpecError(
                        f"landmark {landmark.id!r} must be visible from {region!r}, "
                        "which the spec does not declare"
                    )
        for first, second in self.sightlines:
            for end in (first, second):
                if end not in seen:
                    raise WorldSpecError(f"sightline names unknown region {end!r}")

    # -- reachability, before anything is built ---------------------------

    def reachable_from_spawn(self) -> tuple[set[str], set[str]]:
        """Which regions circulation can actually get to, and which it cannot.

        Computed here rather than after building, because a region the player
        cannot reach is a defect of the *layout*, and building it first only
        makes the same defect more expensive to find.
        """

        adjacency: dict[str, set[str]] = {region.id: set() for region in self.regions}
        for route in self.circulation:
            adjacency[route.from_id].add(route.to_id)
            adjacency[route.to_id].add(route.from_id)

        spawn = next(region.id for region in self.regions if region.spawn)
        seen = {spawn}
        queue = [spawn]
        while queue:
            for neighbour in adjacency[queue.pop()]:
                if neighbour not in seen:
                    seen.add(neighbour)
                    queue.append(neighbour)
        return seen, {region.id for region in self.regions} - seen

    def footprint_area(self) -> float:
        return sum(region.size[0] * region.size[1] for region in self.regions)

    def to_luau_table(self) -> str:
        return (
            "{{\n  id = {id},\n  regions = {{{regions}}},\n"
            "  circulation = {{{routes}}},\n  landmarks = {{{landmarks}}},\n"
            "  sightlines = {{{sightlines}}},\n}}"
        ).format(
            id=_lua_string(self.id),
            regions=", ".join(region.to_luau() for region in self.regions),
            routes=", ".join(route.to_luau() for route in self.circulation),
            landmarks=", ".join(mark.to_luau() for mark in self.landmarks),
            sightlines=", ".join(
                "{{ from = {a}, to = {b} }}".format(a=_lua_string(a), b=_lua_string(b))
                for a, b in self.sightlines
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "regions": [
                {
                    "id": r.id, "kind": r.kind, "centre": list(r.centre),
                    "size": list(r.size), "spawn": r.spawn, "elevation": r.elevation,
                }
                for r in self.regions
            ],
            "circulation": [
                {"from": r.from_id, "to": r.to_id, **({"width": r.width} if r.width else {})}
                for r in self.circulation
            ],
            "landmarks": [
                {"id": m.id, "at": list(m.at), "height": m.height,
                 "visibleFrom": list(m.visible_from)}
                for m in self.landmarks
            ],
            "sightlines": [{"from": a, "to": b} for a, b in self.sightlines],
        }


def load_spec(document: dict[str, Any]) -> WorldSpec:
    """Build a spec from the shape an agent sends over the wire."""

    if not isinstance(document, dict):
        raise WorldSpecError("a world spec must be an object")

    def vector3(value: Any, label: str) -> tuple[float, float, float]:
        if not isinstance(value, (list, tuple)) or len(value) != 3:
            raise WorldSpecError(f"{label} must be three numbers")
        return tuple(float(v) for v in value)  # type: ignore[return-value]

    try:
        regions = tuple(
            Region(
                id=str(entry["id"]),
                kind=str(entry["kind"]),
                centre=vector3(entry.get("centre", [0, 0, 0]), f"region {entry.get('id')} centre"),
                size=(float(entry["size"][0]), float(entry["size"][1])),
                spawn=bool(entry.get("spawn", False)),
                elevation=float(entry.get("elevation", 0.0)),
            )
            for entry in document.get("regions", [])
        )
    except (KeyError, TypeError, IndexError) as exc:
        raise WorldSpecError(f"a region is malformed: {exc}") from exc

    routes = tuple(
        Route(str(entry["from"]), str(entry["to"]),
              float(entry["width"]) if entry.get("width") is not None else None)
        for entry in document.get("circulation", [])
    )
    landmarks = tuple(
        Landmark(
            id=str(entry["id"]),
            at=vector3(entry.get("at", [0, 0, 0]), f"landmark {entry.get('id')} at"),
            height=float(entry.get("height", 10.0)),
            visible_from=tuple(str(r) for r in entry.get("visibleFrom", [])),
        )
        for entry in document.get("landmarks", [])
    )
    sightlines = tuple(
        (str(entry["from"]), str(entry["to"])) for entry in document.get("sightlines", [])
    )
    return WorldSpec(
        id=str(document.get("id", "")),
        regions=regions,
        circulation=routes,
        landmarks=landmarks,
        sightlines=sightlines,
    )


def _lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


# ------------------------------------------------------------- composition


def plan_program(spec: WorldSpec, tokens_relative: str) -> str:
    """Luau that validates the spec and reports what WorldKit measures.

    Composed rather than handed to the agent to write. The point of the whole
    module is that describing a world and implementing one are different jobs.
    """

    # The token set arrives as harness data rather than being read from disk
    # inside Luau: one loader, in Python, that validates against the schema. A
    # second reader in Luau is a second set of rules to drift.
    return f"""
local Blockout = Require("Blockout")
local Tokens = Require("Tokens")

local tokens = Tokens.define(TOKENS)
local spec = {spec.to_luau_table()}

local problems = Blockout.validate(spec, tokens)
local quoted = {{}}
for index, problem in ipairs(problems) do
    quoted[index] = string.format("%q", problem)
end
print(string.format(
    '{{"kind":"plan","problems":[%s],"walkableArea":%s,"regions":%d,"routes":%d}}',
    table.concat(quoted, ","),
    tostring(Blockout.walkableArea(spec)),
    #spec.regions,
    #spec.circulation
))
"""


@dataclass
class PlanResult:
    """What is knowable about a world before anything is built."""

    spec: WorldSpec
    problems: list[str] = field(default_factory=list)
    unreachable: list[str] = field(default_factory=list)
    walkable_area: float = 0.0
    footprint_area: float = 0.0
    harness: dict[str, Any] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return not self.problems and not self.unreachable

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "id": self.spec.id,
            "ok": self.ok,
            "problems": list(self.problems),
            # Kept separate from `problems`: an unreachable region is a defect of
            # the layout's graph, not of any single region's declaration, and the
            # fix is a route rather than an edit.
            "unreachableFromSpawn": list(self.unreachable),
            "walkableArea": round(self.walkable_area, 2),
            "footprintArea": round(self.footprint_area, 2),
            "regions": len(self.spec.regions),
            "routes": len(self.spec.circulation),
            "landmarks": len(self.spec.landmarks),
            "spec": self.spec.to_dict(),
            "harness": self.harness,
            "note": (
                "planned headlessly: no Studio, no place file, nothing built. A layout "
                "whose spawn cannot reach half its regions is knowable before a single "
                "Part exists"
            ),
        }

    def summary(self) -> str:
        lines = [
            f"{'OK' if self.ok else 'PROBLEMS'}  {self.spec.id}: "
            f"{len(self.spec.regions)} regions, {len(self.spec.circulation)} routes, "
            f"{self.walkable_area:.0f} walkable"
        ]
        for problem in self.problems:
            lines.append(f"  problem:     {problem}")
        for region in self.unreachable:
            lines.append(f"  unreachable: {region} cannot be walked to from the spawn")
        return "\n".join(lines)


def plan(root: Path, spec: WorldSpec, *, tokens: str = "tokens/brickfarm.json",
         timeout: float = 60.0) -> PlanResult:
    """Validate a world spec against WorldKit and the token set, headlessly."""

    from ..luau_harness import HarnessError, run
    from ..tokens import TokenError, load_token_set

    _, unreachable = spec.reachable_from_spawn()

    try:
        token_set = load_token_set(root, tokens)
    except TokenError as exc:
        raise WorldSpecError(f"{tokens}: {exc}") from exc

    try:
        result = run(
            root,
            libraries=["roblox/lib/WorldKit"],
            body=plan_program(spec, tokens),
            data={"TOKENS": token_set.data},
            timeout=timeout,
        )
    except HarnessError as exc:
        raise WorldSpecError(f"the planner could not run: {exc}") from exc

    payload: dict[str, Any] = {}
    for line in result.json_lines():
        if isinstance(line, dict) and line.get("kind") == "plan":
            payload = line
            break

    if not result.ok and not payload:
        # The whole stderr, not its last line: a Luau traceback puts the useful
        # sentence in the middle and the file offset at the end.
        raise WorldSpecError(
            "WorldKit rejected the spec before it could report:\n"
            + (result.stderr.strip() or result.stdout.strip() or "no output")
        )

    return PlanResult(
        spec=spec,
        problems=list(payload.get("problems") or []),
        unreachable=sorted(unreachable),
        walkable_area=float(payload.get("walkableArea") or 0.0),
        footprint_area=spec.footprint_area(),
        harness={"exitCode": result.exit_code, "ok": result.ok},
    )
