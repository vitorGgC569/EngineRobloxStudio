"""The art director: which assets, how many, unique or reused, and at what cost.

The Blender worker solved *how* to produce geometry. `choose_backend` solved
*which tool* to produce one asset with. Neither decides what a world actually
needs, and that decision is where a game's budget is won or lost.

The failure this prevents is not subtle and does not announce itself. A world
authored asset-by-asset accumulates forty unique meshes at twenty thousand
triangles each, every one of them approved individually by a validator that was
only ever shown one at a time. Nothing rejects it. The place opens, the phone
build stutters, and the cause is distributed across forty decisions that were
each defensible.

So the director allocates from a **total** and refuses a plan that exceeds it:

    budget -> plan -> allocate by visual weight -> route -> problems

Three principles do the work.

**Reuse is the default; uniqueness is spent.** Roblox reuses render geometry
when one asset id appears many times, so twenty instances of one lantern cost
close to one lantern. A plan that makes every placement unique has spent its
whole budget on things nobody looks at twice.

**Budget follows the eye, not the count.** A landmark seen from across the map
earns a large share; a prop seen at two metres for one second earns almost none.
Allocating evenly is how a hero asset ends up with the same triangle count as a
crate.

**Nothing here generates.** The plan says what to look for, what to build, and
what each may cost. Searching, generating and reviewing are the asset pipeline's
job, and keeping the decision separate is what lets a plan be argued with before
an hour of Blender time is spent on it.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping, Sequence

from ..geometry.brief import BACKEND_BY_ROLE, TRIANGLE_LIMIT


class DirectorError(ValueError):
    """The asset plan could not be made, and the message says why."""


#: Relative visual weight per role: how much of the triangle budget a thing
#: earns, before counting how many there are.
#:
#: These are ratios rather than measurements, and they are the one judgement in
#: this module. Stated as a table so a director can disagree with them, which is
#: better than the same judgement being spread across forty asset briefs.
VISUAL_WEIGHT = {
    "hero": 10.0,          # seen from across the map, defines the silhouette
    "character": 8.0,      # always on screen, always close
    "structure": 4.0,      # the world's bulk; read at middle distance
    "machine": 3.0,        # interacted with, so looked at deliberately
    "terrain-feature": 2.0,
    "vegetation": 1.0,     # scattered in hundreds; instanced hard
    "prop": 1.0,
    "collectible": 1.5,    # small but held at arm's length
    #: Store presence: icon, thumbnail, storefront art. Images, not geometry --
    #: they draw no triangles at all, and allocating them a share of a mesh
    #: budget was the first thing this table got wrong.
    "interface": 0.0,
    # Interaction cues consume no geometry and are deliberately sourceable.
    # Music/voice/brand audio are not this role and keep the authored default.
    "feedback": 0.0,
}

#: Roles that are inherently one-of-a-kind and cost no geometry. Exempt from the
#: reuse complaint: an experience has exactly one icon, and reporting that as
#: "modelled for a single placement" is a complaint about the platform.
INTERFACE_ROLES = ("interface",)
MEDIA_ROLE_KIND = {
    "interface": "icon",
    "feedback": "audio",
}

#: Region kinds the world grammar produces, and the asset role each implies.
KIND_TO_ROLE = {
    "landmark": "hero",
    "plaza": "structure",
    "street": "structure",
    "corridor": "structure",
    "shop": "structure",
    "interior": "structure",
    "arena": "structure",
    "plot": "machine",
    "field": "vegetation",
    "decorative": "prop",
    "spawn": "structure",
}

#: Above this a scene stops being a kit and becomes a collection. Every distinct
#: asset is its own load, its own moderation wait and its own thing to keep
#: consistent, and coherence falls off well before performance does.
MAX_DISTINCT_ASSETS = 24

#: Instances at or above this justify the asset existing at all. Below it, the
#: thing was modelled for one placement, which is the most expensive way to fill
#: a world.
INSTANCE_FLOOR = 3

#: Triangle floor. Below this an asset cannot carry a silhouette, and the visual
#: critic will score it as unmodelled -- so a budget that allocates less has
#: allocated nothing.
MIN_TRIANGLES = 150


@dataclass(frozen=True)
class Budget:
    """What the whole scene may cost."""

    #: Total triangles across every *distinct* asset, not every placement.
    #: Instances are close to free; uniqueness is what is being rationed.
    triangles: int = 120_000
    max_distinct: int = MAX_DISTINCT_ASSETS
    #: How much of the budget hero assets may take between them. Without a
    #: ceiling a single landmark eats a world.
    hero_share_ceiling: float = 0.45

    def __post_init__(self) -> None:
        if self.triangles < MIN_TRIANGLES * 2:
            raise DirectorError(
                f"a scene budget below {MIN_TRIANGLES * 2} triangles cannot hold two "
                "assets that carry a silhouette"
            )
        if self.max_distinct < 1:
            raise DirectorError("a scene needs at least one distinct asset")
        if not 0 < self.hero_share_ceiling <= 1.0:
            raise DirectorError("the hero share must be a fraction above zero")


@dataclass(frozen=True)
class AssetEntry:
    """One asset the world needs, and what it may cost."""

    id: str
    role: str
    #: How many placements use it. The lever that makes a world affordable.
    instances: int
    triangles: int
    backend: str
    strategy: str
    reason: str = ""
    kind: str = "geometry"
    source: str = "internal"
    licence: str = "CC0"
    attribution_required: bool = False

    @property
    def instanced(self) -> bool:
        return self.instances >= INSTANCE_FLOOR

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id, "role": self.role, "instances": self.instances,
            "kind": self.kind,
            "triangleAllowance": self.triangles, "backend": self.backend,
            "strategy": self.strategy, "instanced": self.instanced,
            "source": self.source, "licence": self.licence,
            "attributionRequired": self.attribution_required,
            "reason": self.reason,
        }


@dataclass
class AssetPlan:
    """Everything a world needs, allocated from one budget."""

    world_id: str
    budget: Budget
    entries: list[AssetEntry] = field(default_factory=list)

    @property
    def distinct(self) -> int:
        return len(self.entries)

    @property
    def geometry_distinct(self) -> int:
        """Distinct render geometry; media must not dilute the mesh budget."""

        return sum(entry.kind == "geometry" for entry in self.entries)

    @property
    def media_distinct(self) -> int:
        return self.distinct - self.geometry_distinct

    @property
    def placements(self) -> int:
        return sum(entry.instances for entry in self.entries)

    @property
    def geometry_placements(self) -> int:
        return sum(entry.instances for entry in self.entries if entry.kind == "geometry")

    @property
    def allocated(self) -> int:
        return sum(entry.triangles for entry in self.entries)

    @property
    def reuse_ratio(self) -> float:
        """Placements per distinct asset. The number that decides affordability."""

        return self.placements / self.distinct if self.distinct else 0.0

    def blocking_problems(self) -> list[str]:
        """Objective budget/engine violations that make the plan unusable."""

        found: list[str] = []
        if self.allocated > self.budget.triangles:
            found.append(
                f"the plan allocates {self.allocated:,} triangles against a "
                f"{self.budget.triangles:,} budget; every asset would pass its own "
                "validator and the scene would still not run"
            )
        if self.geometry_distinct > self.budget.max_distinct:
            found.append(
                f"{self.geometry_distinct} distinct geometry assets exceeds "
                f"{self.budget.max_distinct}; "
                "past that a scene stops being a kit and becomes a collection, and "
                "coherence falls off well before performance does"
            )
        for entry in self.entries:
            if entry.role in MEDIA_ROLE_KIND:
                continue
            if entry.triangles < MIN_TRIANGLES:
                found.append(
                    f"{entry.id} is allocated {entry.triangles} triangles, below the "
                    f"{MIN_TRIANGLES} needed to carry a silhouette; the visual critic "
                    "will score it as unmodelled"
                )
            if entry.triangles > TRIANGLE_LIMIT:
                found.append(
                    f"{entry.id} is allocated {entry.triangles:,} triangles, above "
                    f"Roblox's {TRIANGLE_LIMIT:,} ceiling for a single mesh"
                )

        # Measured against what the plan allocates, not against the nominal
        # budget. With budget to spare every asset clamps to Roblox's per-mesh
        # ceiling and the share against the budget can never rise -- but "heroes
        # are half this scene" is a fact about the composition, not about how
        # much budget happened to be available.
        heroes = sum(e.triangles for e in self.entries if e.role == "hero")
        if self.allocated and heroes / self.allocated > self.budget.hero_share_ceiling:
            found.append(
                f"hero assets take {heroes / self.allocated:.0%} of the scene's geometry, "
                f"above the {self.budget.hero_share_ceiling:.0%} ceiling; one landmark "
                "would eat the world around it"
            )
        return found

    def warnings(self) -> list[str]:
        """Quality/cost advice that must stay visible but cannot abort a build.

        A compact arena legitimately has one objective, one staging kit and two
        build wings.  Low reuse is worth challenging, but unlike a triangle
        overrun it does not make the asset plan impossible.  Treating the two
        alike prevented every deliberately small game from reaching Studio.
        """

        found: list[str] = []
        singles = [
            entry for entry in self.entries
            if not entry.instanced
            and entry.role != "hero"
            and entry.role not in MEDIA_ROLE_KIND
        ]
        if self.geometry_distinct and len(singles) > self.geometry_distinct / 2:
            found.append(
                f"{len(singles)} of {self.geometry_distinct} geometry assets are used fewer than "
                f"{INSTANCE_FLOOR} times; modelling for one placement is the most "
                "expensive way to fill a world"
            )
        return found

    def problems(self) -> list[str]:
        """All findings, preserving the existing diagnostic surface."""

        return self.blocking_problems() + self.warnings()

    @property
    def ok(self) -> bool:
        return not self.blocking_problems()

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "worldId": self.world_id,
            "ok": self.ok,
            "budget": {
                "triangles": self.budget.triangles,
                "maxDistinct": self.budget.max_distinct,
                "heroShareCeiling": self.budget.hero_share_ceiling,
            },
            "distinct": self.distinct,
            "geometryDistinct": self.geometry_distinct,
            "mediaDistinct": self.media_distinct,
            "placements": self.placements,
            "geometryPlacements": self.geometry_placements,
            "allocated": self.allocated,
            "reuseRatio": round(self.reuse_ratio, 2),
            "entries": [entry.to_dict() for entry in self.entries],
            "blockers": self.blocking_problems(),
            "warnings": self.warnings(),
            "problems": self.problems(),
            "note": (
                "a plan, not publication proof: source offers may come from a "
                "connector, but this plan alone does not prove download, Roblox "
                "moderation or exact-build integration"
            ),
        }

    def summary(self) -> str:
        lines = [
            f"{'OK' if self.ok else 'PROBLEMS'}  {self.world_id}: {self.distinct} assets "
            f"across {self.placements} placements ({self.reuse_ratio:.1f}x reuse), "
            f"{self.allocated:,}/{self.budget.triangles:,} triangles"
        ]
        for entry in sorted(self.entries, key=lambda e: -e.triangles):
            lines.append(
                f"  {entry.role:<16} {entry.id:<28} x{entry.instances:<4} "
                f"{entry.triangles:>6,} tri  {entry.strategy:<8} {entry.backend}"
            )
        for problem in self.problems():
            lines.append(f"  problem: {problem}")
        return "\n".join(lines)


#: Roles that must be unique per placement rather than shared as a kit.
#:
#: This is the "which need to be unique?" question the document asks, answered
#: once instead of per asset. A landmark exists to make its region recognisable
#: from across the map -- two zones sharing one are one zone as far as a player
#: navigating can tell. Everything else is a kit: twenty corridors want one
#: corridor used twenty times.
UNIQUE_ROLES = ("hero", "character")


def _needs_from_world(world_spec: Any) -> dict[str, tuple[str, int]]:
    """Which assets a world implies.

    One kit per region *kind* for shared roles, and one asset per *region* for
    the roles that have to be unique. A director that emitted a brief per region
    everywhere would produce twenty corridors nobody can tell apart at twenty
    times the cost; one that shared everything would give every zone the same
    landmark.
    """

    counts: dict[str, int] = {}
    needs: dict[str, tuple[str, int]] = {}

    for region in world_spec.regions:
        role = KIND_TO_ROLE.get(region.kind, "prop")
        if role in UNIQUE_ROLES:
            needs[region.id] = (role, 1)
        else:
            counts[region.kind] = counts.get(region.kind, 0) + 1

    for kind, count in sorted(counts.items()):
        needs[f"kit-{kind}"] = (KIND_TO_ROLE.get(kind, "prop"), count)
    return needs


def plan(
    world_id: str,
    *,
    world_spec: Any = None,
    budget: Budget | None = None,
    extra: Sequence[tuple[str, str, int]] = (),
    existing: Iterable[str] = (),
    source_offers: Mapping[str, Iterable[str]] | None = None,
) -> AssetPlan:
    """Allocate a whole scene's assets from one budget.

    `extra` is `(id, role, instances)` for assets the world spec cannot imply --
    a shop's storefront art, a game's icon. `existing` names assets already
    available, which are routed to DISCOVER instead of CREATE.
    """

    budget = budget or Budget()
    needs: dict[str, tuple[str, int]] = {}
    if world_spec is not None:
        needs.update(_needs_from_world(world_spec))
    for asset_id, role, instances in extra:
        if role not in VISUAL_WEIGHT:
            raise DirectorError(
                f"unknown role {role!r} for {asset_id}; known roles: "
                + ", ".join(sorted(VISUAL_WEIGHT))
            )
        needs[asset_id] = (role, int(instances))

    if not needs:
        raise DirectorError(
            "nothing to plan: pass a world spec, extra assets, or both"
        )

    available = set(existing)
    offers = source_offers or {}

    # Weight by what the eye earns, damped by how many there are. A role seen
    # once earns its full weight; a prop placed forty times earns its weight
    # once and is then reused -- so the count raises the weight sub-linearly
    # rather than proportionally, which is what stops scattered vegetation from
    # out-bidding a landmark.
    weights: dict[str, float] = {}
    for asset_id, (role, instances) in needs.items():
        weights[asset_id] = VISUAL_WEIGHT[role] * (1.0 + math.log10(max(instances, 1)))
    # Interface assets weigh nothing, so they must not divide the budget either.

    total_weight = sum(weights.values()) or 1.0
    entries: list[AssetEntry] = []
    for asset_id, (role, instances) in sorted(needs.items()):
        share = weights[asset_id] / total_weight
        if role in MEDIA_ROLE_KIND:
            # An image has no triangles. Giving it a share of a mesh budget takes
            # it from the geometry that needs it.
            allowance = 0
        else:
            allowance = int(budget.triangles * share)
            # Clamped to what Roblox accepts and to what carries a silhouette. A
            # plan that allocated 40 triangles has allocated nothing.
            allowance = max(MIN_TRIANGLES, min(allowance, TRIANGLE_LIMIT))

        from ..sourcing import decide

        kind = MEDIA_ROLE_KIND.get(role, "geometry")
        available_sources = set(offers.get(asset_id, ()))
        if asset_id in available:
            available_sources.add("internal")
        decision = decide(
            asset_id,
            role=role,
            kind=kind,
            available=available_sources,
        )
        sourced = decision.action in {"reuse", "adapt"}
        if sourced:
            backend = f"sourced:{decision.source}"
            strategy = "DISCOVER" if decision.action == "reuse" else "ADAPT"
            reason = decision.reason
        else:
            backend = (
                "image" if role in INTERFACE_ROLES
                else "audio-authoring" if role == "feedback"
                else BACKEND_BY_ROLE.get(role, "blender")
            )
            strategy = "CREATE"
            reason = (
                f"{instances} placement(s) at {VISUAL_WEIGHT[role]:.0f}x visual weight; "
                f"{decision.reason}"
            )
        entries.append(AssetEntry(
            id=asset_id,
            role=role,
            instances=instances,
            triangles=allowance,
            # Interface assets are images: the image pipeline makes them, not a
            # mesh backend. Falling through to Blender would route an icon to a
            # modeller.
            backend=backend,
            strategy=strategy,
            reason=reason,
            kind=kind,
            source=decision.source,
            licence=decision.licence,
            attribution_required=decision.attribution_required,
        ))

    return AssetPlan(world_id=world_id, budget=budget, entries=entries)


def plan_for_model(
    model: Any,
    *,
    world_spec: Any = None,
    budget: Budget | None = None,
    existing: Iterable[str] = (),
    source_offers: Mapping[str, Iterable[str]] | None = None,
) -> AssetPlan:
    """The asset plan a game model implies, including what the world does not.

    Icon and thumbnail always: every shipped experience has a store presence,
    and an asset plan that omits it is a plan that ends with a release blocked
    on something nobody scheduled.
    """

    extra: list[tuple[str, str, int]] = [
        ("experience-icon", "interface", 1),
        ("experience-thumbnail", "interface", 1),
        ("feedback-ui-confirm", "feedback", 1),
        ("feedback-ui-denied", "feedback", 1),
    ]
    systems = set(getattr(model, "systems", ()) or ())
    if getattr(model, "monetization", ()) or "shop" in systems or "economy" in systems:
        extra.append(("storefront-art", "interface", 1))
        extra.append(("feedback-purchase-success", "feedback", 1))
    if "progression" in systems or "quests" in systems:
        extra.append(("feedback-reward", "feedback", 1))
    if world_spec is None:
        # Only when there is no world to read them from. With a spec, the
        # landmark regions are already unique assets, and adding them here again
        # would plan the same landmarks twice -- which is what the first version
        # did, and it showed up as five landmark assets for three landmarks.
        for zone in getattr(model, "zones", ()):
            extra.append((f"landmark-{zone.id}", "hero", 1))

    return plan(model.id, world_spec=world_spec, budget=budget,
                extra=extra, existing=existing, source_offers=source_offers)
