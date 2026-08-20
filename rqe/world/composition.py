"""Scene composition: place, scatter, align, replace, vary, optimise.

The MetaWorldModel document asks for a `scene.*` family, and the reason it is a
family rather than a loop over `instance.create` is that placement is the part
worth being deterministic about. The same seed must put the same lantern in the
same square metre on every run, in Luau and in Python alike -- otherwise two
builds of "the same" world differ, a visual comparison between them reports
noise, and nothing downstream can tell a regression from a reshuffle.

So `seed_for` here is a transcription of `Kit.seedFor` in
`roblox/lib/WorldKit/Kit.lua`, down to the FNV constants and the spatial hash
multipliers, and a test asserts the two agree on real cells. A second placement
algorithm that merely *looked* deterministic would be worse than none: it would
be stable within itself and disagree with the SDK that ships in the game.

Everything here produces a **plan** -- data describing what should exist and
where -- and nothing here writes the DataModel. Applying is `instance.create`
over the bridge, and keeping the two apart means a plan can be diffed, reviewed
and re-applied, and that a failure to write is never confused with a failure to
decide.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence


class CompositionError(ValueError):
    """The composition could not be computed, and says why."""


#: 32-bit FNV-1a, and the spatial hash multipliers from `Kit.seedFor`. Held as
#: named constants rather than inline literals so the correspondence with the
#: Luau side is legible when either is edited.
FNV_OFFSET = 2166136261
FNV_PRIME = 16777619
WORD = 4294967296
HASH_X, HASH_Y, HASH_Z = 73856093, 19349663, 83492791


def seed_for(kit_id: str, module_id: str, cell: tuple[float, float, float]) -> int:
    """The same seed `Kit.seedFor` produces for the same inputs.

    Transcribed, not reinvented. `tests/test_composition.py` runs both sides on
    the same cells and asserts they agree; if the Luau changes and this does
    not, that test fails rather than the worlds quietly diverging.
    """

    seed = FNV_OFFSET

    def mix(value: int) -> None:
        nonlocal seed
        seed ^= value % WORD
        seed = (seed * FNV_PRIME) % WORD

    for character in kit_id:
        mix(ord(character))
    for character in module_id:
        mix(ord(character))
    mix(math.floor(cell[0]) * HASH_X)
    mix(math.floor(cell[1]) * HASH_Y)
    mix(math.floor(cell[2]) * HASH_Z)
    return seed


def _unit(seed: int, salt: int = 0) -> float:
    """A stable 0..1 draw from a seed, without touching global RNG state.

    `random.seed()` would work and would also reach outside this function; two
    callers interleaving would then produce placements that depend on call
    order, which is exactly the non-determinism this module exists to avoid.
    """

    value = (seed ^ (salt * 0x9E3779B1)) % WORD
    value = (value * 1103515245 + 12345) % 0x7FFFFFFF
    return value / 0x7FFFFFFF


@dataclass(frozen=True)
class Placement:
    """One thing to exist somewhere. Data, not an Instance."""

    module_id: str
    position: tuple[float, float, float]
    rotation_y: float = 0.0
    scale: float = 1.0
    variant: str = ""
    cell: tuple[int, int, int] = (0, 0, 0)
    region: str = ""

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "moduleId": self.module_id,
            "position": [round(v, 4) for v in self.position],
            "rotationY": round(self.rotation_y, 3),
            "scale": round(self.scale, 4),
            "cell": list(self.cell),
        }
        if self.variant:
            payload["variant"] = self.variant
        if self.region:
            payload["region"] = self.region
        return payload


@dataclass
class Plan:
    """A composition, with enough provenance to reproduce it exactly."""

    kit_id: str
    placements: list[Placement] = field(default_factory=list)
    seed: int = 0
    operations: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "kitId": self.kit_id,
            "seed": self.seed,
            "count": len(self.placements),
            "operations": list(self.operations),
            "modules": sorted({p.module_id for p in self.placements}),
            "placements": [p.to_dict() for p in self.placements],
            "note": (
                "a plan, not a world: nothing here has written the DataModel. Apply "
                "with instance.create, so the decision can be reviewed and re-applied "
                "separately from the write"
            ),
        }

    def to_instance_batch(self, parent: str) -> list[dict[str, Any]]:
        """The plan as `instance.create` arguments for the bridge."""

        return [
            {
                "className": "Model",
                "parent": parent,
                "name": f"{p.module_id}{'_' + p.variant if p.variant else ''}",
                "attributes": {
                    "kitId": self.kit_id,
                    "moduleId": p.module_id,
                    "variant": p.variant,
                    "cellX": p.cell[0], "cellY": p.cell[1], "cellZ": p.cell[2],
                },
                "properties": {
                    "WorldPivot": {
                        "position": list(p.position),
                        "rotationY": p.rotation_y,
                    },
                },
            }
            for p in self.placements
        ]


# ---------------------------------------------------------------- scene.place


def place(
    kit_id: str,
    module_id: str,
    at: Sequence[float],
    *,
    rotation_y: float = 0.0,
    scale: float = 1.0,
    region: str = "",
) -> Plan:
    """One module, at one point. The degenerate case, kept explicit."""

    if len(at) != 3:
        raise CompositionError("a position is three numbers")
    cell = (math.floor(at[0]), math.floor(at[1]), math.floor(at[2]))
    return Plan(
        kit_id=kit_id,
        placements=[Placement(
            module_id=module_id, position=tuple(float(v) for v in at),  # type: ignore[arg-type]
            rotation_y=rotation_y, scale=scale, cell=cell, region=region,
        )],
        seed=seed_for(kit_id, module_id, tuple(at)),  # type: ignore[arg-type]
        operations=["place"],
    )


# -------------------------------------------------------------- scene.scatter


def scatter(
    kit_id: str,
    module_id: str,
    *,
    centre: Sequence[float],
    size: Sequence[float],
    density: float,
    region: str = "",
    jitter: float = 0.35,
    rotate: bool = True,
    scale_range: tuple[float, float] = (1.0, 1.0),
    exclude: Iterable[Sequence[float]] = (),
    exclusion_radius: float = 0.0,
) -> Plan:
    """Fill a footprint with one module, deterministically.

    A grid with per-cell jitter rather than uniform random points. Pure random
    scattering clumps and leaves holes -- it looks like a bug rather than like
    nature -- and it cannot be regenerated identically after an edit because
    every point depends on every draw before it. Jittering a grid cell by its
    own seed means each placement depends only on its own coordinates, so
    changing the region size moves the boundary without reshuffling the middle.
    """

    if not 0 < density <= 4:
        raise CompositionError(
            "density is placements per square stud and must be in (0, 4]; "
            f"got {density}"
        )
    if len(centre) != 3 or len(size) != 2:
        raise CompositionError("centre is three numbers and size is two")
    if size[0] <= 0 or size[1] <= 0:
        raise CompositionError("a region with no area cannot be scattered into")

    spacing = 1.0 / math.sqrt(density)
    columns = max(int(size[0] / spacing), 1)
    rows = max(int(size[1] / spacing), 1)

    exclusions = [tuple(float(v) for v in point) for point in exclude]
    placements: list[Placement] = []
    skipped = 0

    for row in range(rows):
        for column in range(columns):
            x = centre[0] - size[0] / 2 + (column + 0.5) * (size[0] / columns)
            z = centre[2] - size[1] / 2 + (row + 0.5) * (size[1] / rows)
            cell = (math.floor(x), math.floor(centre[1]), math.floor(z))
            seed = seed_for(kit_id, module_id, cell)

            x += (_unit(seed, 1) - 0.5) * spacing * jitter * 2.0
            z += (_unit(seed, 2) - 0.5) * spacing * jitter * 2.0

            if exclusion_radius > 0 and any(
                math.dist((x, z), (point[0], point[2])) < exclusion_radius
                for point in exclusions
            ):
                skipped += 1
                continue

            low, high = scale_range
            placements.append(Placement(
                module_id=module_id,
                position=(x, float(centre[1]), z),
                rotation_y=(_unit(seed, 3) * 360.0) if rotate else 0.0,
                scale=low + _unit(seed, 4) * (high - low),
                cell=cell,
                region=region,
            ))

    plan = Plan(
        kit_id=kit_id, placements=placements,
        seed=seed_for(kit_id, module_id, tuple(centre)),  # type: ignore[arg-type]
        operations=[f"scatter({module_id}, density={density})"],
    )
    if skipped:
        plan.operations.append(f"excluded {skipped} placements inside a keep-clear radius")
    return plan


# ---------------------------------------------------------------- scene.align


def align(plan: Plan, *, axis: str = "y", grid: float = 1.0) -> Plan:
    """Snap placements to a grid on one axis.

    Modular kits butt against each other; a fractional offset leaves a seam that
    is invisible in the editor and a bright line in a render.
    """

    if axis not in ("x", "y", "z"):
        raise CompositionError("axis must be x, y or z")
    if grid <= 0:
        raise CompositionError("grid must be positive")

    index = {"x": 0, "y": 1, "z": 2}[axis]
    snapped: list[Placement] = []
    for placement in plan.placements:
        position = list(placement.position)
        position[index] = round(position[index] / grid) * grid
        snapped.append(Placement(
            module_id=placement.module_id, position=tuple(position),  # type: ignore[arg-type]
            rotation_y=placement.rotation_y, scale=placement.scale,
            variant=placement.variant, cell=placement.cell, region=placement.region,
        ))
    return Plan(
        kit_id=plan.kit_id, placements=snapped, seed=plan.seed,
        operations=plan.operations + [f"align({axis}, grid={grid})"],
    )


# -------------------------------------------------------------- scene.replace


def replace(plan: Plan, *, module_id: str, with_module: str, region: str | None = None) -> Plan:
    """Swap one module for another, optionally only inside one region.

    Refuses a swap that matches nothing. A replace that silently did nothing is
    indistinguishable from one that worked, right up until the renders.
    """

    matched = 0
    out: list[Placement] = []
    for placement in plan.placements:
        if placement.module_id == module_id and (region is None or placement.region == region):
            matched += 1
            out.append(Placement(
                module_id=with_module, position=placement.position,
                rotation_y=placement.rotation_y, scale=placement.scale,
                variant=placement.variant, cell=placement.cell, region=placement.region,
            ))
        else:
            out.append(placement)

    if matched == 0:
        present = sorted({p.module_id for p in plan.placements})
        raise CompositionError(
            f"nothing to replace: no placement uses {module_id!r}"
            + (f" in region {region!r}" if region else "")
            + f". The plan places: {', '.join(present) if present else 'nothing'}"
        )

    return Plan(
        kit_id=plan.kit_id, placements=out, seed=plan.seed,
        operations=plan.operations + [f"replace({module_id} -> {with_module}, {matched} matched)"],
    )


# -------------------------------------------------------------- scene.variant


def variant(plan: Plan, *, variants: Sequence[str], weights: Sequence[float] | None = None) -> Plan:
    """Assign a variant to every placement, deterministically by cell.

    Repetition is what makes a modular kit read as modular. The assignment is
    driven by each placement's own seed so it survives regeneration: adding a
    region does not reshuffle the variants in the regions beside it.
    """

    if not variants:
        raise CompositionError("a variant set needs at least one variant")
    if weights is not None:
        if len(weights) != len(variants):
            raise CompositionError("weights must match variants one for one")
        if any(w < 0 for w in weights) or sum(weights) <= 0:
            raise CompositionError("weights must be non-negative and sum above zero")
        total = sum(weights)
        cumulative = []
        running = 0.0
        for weight in weights:
            running += weight / total
            cumulative.append(running)
    else:
        cumulative = [(i + 1) / len(variants) for i in range(len(variants))]

    out: list[Placement] = []
    for placement in plan.placements:
        draw = _unit(seed_for(plan.kit_id, placement.module_id, placement.cell), 7)
        chosen = variants[-1]
        for name, threshold in zip(variants, cumulative):
            if draw <= threshold:
                chosen = name
                break
        out.append(Placement(
            module_id=placement.module_id, position=placement.position,
            rotation_y=placement.rotation_y, scale=placement.scale,
            variant=chosen, cell=placement.cell, region=placement.region,
        ))

    return Plan(
        kit_id=plan.kit_id, placements=out, seed=plan.seed,
        operations=plan.operations + [f"variant({len(variants)} variants)"],
    )


def variant_spread(plan: Plan) -> dict[str, int]:
    """How the variants actually landed.

    A weighted set that produces one variant 95% of the time is repetition with
    extra steps, and the only way to know is to count.
    """

    spread: dict[str, int] = {}
    for placement in plan.placements:
        key = placement.variant or "(none)"
        spread[key] = spread.get(key, 0) + 1
    return spread


# ------------------------------------------------- scene.optimize / world.optimize


#: Placements closer together than this are treated as the same point for
#: instancing purposes. Below a tenth of a stud nothing is distinguishable in a
#: render, so two such placements are duplicate work rather than composition.
COINCIDENT_DISTANCE = 0.1


def optimize(plan: Plan, *, instance_threshold: int = 4) -> dict[str, Any]:
    """What this composition costs, and what would make it cheaper.

    Roblox reuses a mesh's render geometry when the same asset id appears many
    times, so the lever that matters is *how many distinct modules* a scene
    uses, not how many objects it places. Reported rather than applied: dropping
    placements changes what the world looks like, and that is a decision for
    whoever authored it.
    """

    counts: dict[str, int] = {}
    for placement in plan.placements:
        counts[placement.module_id] = counts.get(placement.module_id, 0) + 1

    coincident: list[dict[str, Any]] = []
    seen: list[Placement] = []
    for placement in plan.placements:
        for other in seen:
            if (other.module_id == placement.module_id
                    and math.dist(placement.position, other.position) < COINCIDENT_DISTANCE):
                coincident.append({
                    "moduleId": placement.module_id,
                    "at": [round(v, 3) for v in placement.position],
                })
                break
        else:
            seen.append(placement)

    instanceable = {module: count for module, count in counts.items() if count >= instance_threshold}
    findings: list[str] = []
    if coincident:
        findings.append(
            f"{len(coincident)} placements sit on top of another of the same module; "
            "they cost draw calls and cannot be seen"
        )
    if len(counts) > 24:
        findings.append(
            f"{len(counts)} distinct modules: each one is its own asset to load. A kit "
            "reads as coherent below roughly two dozen"
        )
    if not instanceable and len(plan.placements) > 20:
        findings.append(
            "no module repeats often enough to instance; a scene built from unique "
            "objects pays full cost for every one of them"
        )

    return {
        "schemaVersion": 1,
        "placements": len(plan.placements),
        "distinctModules": len(counts),
        "byModule": dict(sorted(counts.items(), key=lambda item: -item[1])),
        "instanceable": dict(sorted(instanceable.items(), key=lambda item: -item[1])),
        "instanceableePlacements": sum(instanceable.values()),
        "coincident": coincident,
        "findings": findings,
        "note": (
            "reported, not applied: removing a placement changes what the world looks "
            "like, and that is the author's call rather than an optimiser's"
        ),
    }


def merge(*plans: Plan) -> Plan:
    """Combine plans that share a kit."""

    if not plans:
        raise CompositionError("nothing to merge")
    kits = {plan.kit_id for plan in plans}
    if len(kits) > 1:
        raise CompositionError(
            "cannot merge plans from different kits: " + ", ".join(sorted(kits))
            + ". Modules from two kits are not built to the same grammar and will not "
            "align at their edges"
        )
    placements: list[Placement] = []
    operations: list[str] = []
    for plan in plans:
        placements.extend(plan.placements)
        operations.extend(plan.operations)
    return Plan(
        kit_id=plans[0].kit_id, placements=placements,
        seed=plans[0].seed, operations=operations,
    )
