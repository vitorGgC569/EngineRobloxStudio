"""The asset brief: what an agent asks for, before any geometry exists.

A brief is the thing a modeller would be handed: dimensions, style, silhouette,
materials, a triangle budget, what the object does in the game, and how it
collides. It is not a program -- it does not say "bevel by 0.08" -- and it is not
a mesh.

Keeping it separate from the program matters for the revision loop. The brief is
the intent and stays fixed; the program is the attempt and changes between
revisions. When the visual critic says the base reads too heavy, what changes is
the program, and the brief is what the result is still measured against.

The budget carried here is the one `validation` enforces, so a brief that asks
for more triangles than Roblox allows is refused at authoring time rather than
after Blender has spent two minutes producing it.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from typing import Any, Sequence

from .validation import Budget, MATERIAL_SLOT_LIMIT, TRIANGLE_LIMIT


class BriefError(ValueError):
    """The brief cannot be executed."""


#: What the asset is for. Drives backend selection and the collision hint, and
#: keeps a brief from being an untyped bag of adjectives.
GAMEPLAY_ROLES = frozenset({
    "prop",             # set dressing, no interaction
    "structure",        # walls, roofs, modular building pieces
    "machine",          # tycoon machinery, conveyors, dispensers
    "hero",             # the one object a region is built around
    "vegetation",
    "terrain-feature",  # rocks, cliffs, outcrops
    "collectible",
    "character",
})

#: How the asset should collide once it is in a place. A hero asset with precise
#: collision is a frame-rate problem; a wall with a box hull is a wall a player
#: walks through.
COLLISION_MODES = frozenset({"none", "box", "hull", "precise"})


@dataclass(frozen=True)
class Reference:
    """An image the brief is modelled against, bound by content hash."""

    id: str
    sha256: str
    note: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "sha256": self.sha256, "note": self.note}


@dataclass(frozen=True)
class AssetBrief:
    id: str
    #: Studs, as (width, height, depth). The single most important field: an
    #: asset authored at the wrong scale is wrong everywhere it is placed and
    #: the mistake survives every later fix.
    dimensions: tuple[float, float, float]
    style: str
    silhouette: str
    materials: tuple[str, ...]
    triangle_budget: int
    gameplay_role: str
    collision: str = "hull"
    references: tuple[Reference, ...] = ()
    require_watertight: bool = False
    notes: str = ""

    def __post_init__(self) -> None:
        if not self.id or not self.id.replace("_", "").replace("-", "").isalnum():
            raise BriefError("brief id must be an alphanumeric name")
        if len(self.dimensions) != 3 or any(value <= 0 for value in self.dimensions):
            raise BriefError("dimensions must be three positive numbers, in studs")
        if not self.style:
            raise BriefError("a brief must state a style")
        if not self.silhouette:
            raise BriefError(
                "a brief must state a silhouette; it is what the visual critic scores and "
                "what a revision is measured against"
            )
        if not self.materials:
            raise BriefError("a brief must name at least one material")
        if len(self.materials) > MATERIAL_SLOT_LIMIT:
            raise BriefError(
                f"a brief may name at most {MATERIAL_SLOT_LIMIT} materials; each one is a draw call"
            )
        if not isinstance(self.triangle_budget, int) or self.triangle_budget < 4:
            raise BriefError("triangle_budget must be an integer of at least 4")
        if self.triangle_budget > TRIANGLE_LIMIT:
            raise BriefError(
                f"triangle_budget {self.triangle_budget} exceeds Roblox's {TRIANGLE_LIMIT} "
                "ceiling for a single mesh"
            )
        if self.gameplay_role not in GAMEPLAY_ROLES:
            raise BriefError(f"gameplay_role must be one of {sorted(GAMEPLAY_ROLES)}")
        if self.collision not in COLLISION_MODES:
            raise BriefError(f"collision must be one of {sorted(COLLISION_MODES)}")

    @property
    def budget(self) -> Budget:
        return Budget(
            triangles=self.triangle_budget,
            material_slots=max(len(self.materials), 1),
            require_uv=True,
            require_watertight=self.require_watertight,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "id": self.id,
            "dimensions": list(self.dimensions),
            "style": self.style,
            "silhouette": self.silhouette,
            "materials": list(self.materials),
            "triangleBudget": self.triangle_budget,
            "gameplayRole": self.gameplay_role,
            "collision": self.collision,
            "requireWatertight": self.require_watertight,
            "references": [item.to_dict() for item in self.references],
            "notes": self.notes,
        }

    @property
    def sha256(self) -> str:
        """Identity of the intent, so a revision can prove it did not drift."""

        payload = json.dumps(self.to_dict(), sort_keys=True, ensure_ascii=False)
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def dimension_findings(self, measured: Sequence[float], tolerance: float = 0.12) -> list[str]:
        """How far the built mesh drifted from the dimensions that were asked for.

        Checked as a ratio rather than an absolute, because a 10% error on a
        60-stud landmark and on a 0.5-stud collectible are different mistakes.
        """

        problems: list[str] = []
        if len(measured) != 3:
            return ["the analysis did not report three dimensions"]
        for axis, (wanted, got) in enumerate(zip(self.dimensions, measured)):
            if wanted <= 0:
                continue
            drift = abs(float(got) - wanted) / wanted
            if drift > tolerance:
                problems.append(
                    f"axis {'XYZ'[axis]} is {float(got):.2f} studs but the brief asked for "
                    f"{wanted:.2f} ({drift * 100:.0f}% off)"
                )
        return problems


def load_brief(document: dict[str, Any]) -> AssetBrief:
    if not isinstance(document, dict):
        raise BriefError("a brief must be an object")
    references = tuple(
        Reference(
            id=str(item.get("id", "")),
            sha256=str(item.get("sha256", "")),
            note=str(item.get("note", "")),
        )
        for item in document.get("references", [])
        if isinstance(item, dict)
    )
    for reference in references:
        if len(reference.sha256) != 64:
            raise BriefError(
                f"reference {reference.id!r} has no content hash; a citation nobody can "
                "check is decoration"
            )
    dimensions = document.get("dimensions")
    if isinstance(dimensions, dict):
        dimensions = [dimensions.get("width"), dimensions.get("height"), dimensions.get("depth")]
    if not isinstance(dimensions, (list, tuple)) or len(dimensions) != 3:
        raise BriefError("dimensions must be three numbers or a {width, height, depth} object")

    return AssetBrief(
        id=str(document.get("id", "")),
        dimensions=(float(dimensions[0]), float(dimensions[1]), float(dimensions[2])),
        style=str(document.get("style", "")),
        silhouette=str(document.get("silhouette", "")),
        materials=tuple(str(item) for item in document.get("materials", [])),
        triangle_budget=int(document.get("triangleBudget", 8000)),
        gameplay_role=str(document.get("gameplayRole", "prop")),
        collision=str(document.get("collision", "hull")),
        references=references,
        require_watertight=bool(document.get("requireWatertight", False)),
        notes=str(document.get("notes", "")),
    )


#: Which backend suits which kind of asset.
#:
#: From the architecture: a simple crate is a procedural model, a modular
#: building is WorldKit, a rock is an editable mesh, a stylised machine or a
#: statue is Blender. Using the wrong tool for a problem is the failure this
#: mapping exists to prevent.
BACKEND_BY_ROLE = {
    "prop": "procedural_model",
    "structure": "worldkit",
    "machine": "blender",
    "hero": "blender",
    "vegetation": "procedural_model",
    "terrain-feature": "roblox_editable",
    "collectible": "procedural_model",
    "character": "blender",
}


def choose_backend(brief: AssetBrief, *, override: str | None = None) -> dict[str, Any]:
    """Pick the modelling backend, and say why."""

    if override:
        # The caller wins, always. The mapping below is a recommendation about
        # which tool suits a problem, and a recommendation that cannot be
        # ignored is a rule wearing a friendlier word.
        return {"backend": override, "reason": "explicitly requested by the caller", "overridden": True}

    backend = BACKEND_BY_ROLE.get(brief.gameplay_role, "blender")

    # A budget this small cannot carry a modelled asset, whatever its role: the
    # triangles go on the silhouette and there is nothing left for detail.
    if brief.triangle_budget < 400 and backend == "blender":
        backend = "procedural_model"
        reason = (
            f"a {brief.triangle_budget}-triangle budget cannot carry a modelled asset; "
            "primitives will read better at this cost"
        )
    else:
        reason = f"gameplay role {brief.gameplay_role!r} is best served by {backend}"

    return {"backend": backend, "reason": reason, "overridden": False}
