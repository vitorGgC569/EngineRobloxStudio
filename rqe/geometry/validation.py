"""Roblox's mesh rules, applied to a measured topology report.

Policy lives here and measurement lives in `blender/analyse.py`, for the same
reason the visual quality thresholds are split that way: a validator that
carries its own limits into the tool that produces the artefact ends up grading
itself.

Every rule below exists because Roblox's importer or renderer cares, and because
the failure is invisible until it is expensive. A non-manifold mesh is rejected
at upload after the modelling time is already spent. A degenerate triangle
produces shading artefacts nobody can trace to a cause. A flipped normal makes a
wall vanish from one side. A missing UV makes every texture unusable, which is
discovered when the first texture is applied and not before.

Severities are deliberate:

  ``blocking``  Roblox will reject it, or the asset is unusable in a game.
  ``major``     It will import and it is wrong. Someone will file a bug later.
  ``minor``     Worth fixing, will not stop anything.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable


#: Roblox's documented ceiling for triangles in a single mesh.
TRIANGLE_LIMIT = 20_000

#: Above this, a mesh is expensive enough that it should be a kit of reusable
#: pieces instead. Roblox's own guidance is to instance one mesh many times
#: rather than import large unique geometry.
TRIANGLE_ADVISORY = 10_000

#: Roblox skins and renders per material slot; each one is a draw call.
MATERIAL_SLOT_LIMIT = 8

#: A mesh larger than this in any axis is almost always a map exported as one
#: object, which is the specific mistake the architecture is arranged to avoid.
MAX_DIMENSION_STUDS = 2048.0

#: Below this, the mesh will be sub-pixel at any sane camera distance.
MIN_DIMENSION_STUDS = 0.05

#: How far the origin may sit from the geometry centre, as a fraction of the
#: largest dimension. An asset whose pivot is outside itself rotates around
#: empty space when a game places it.
MAX_ORIGIN_OFFSET_RATIO = 0.75


@dataclass(frozen=True)
class Finding:
    rule: str
    severity: str
    message: str
    measured: Any = None
    limit: Any = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "rule": self.rule,
            "severity": self.severity,
            "message": self.message,
            "measured": self.measured,
            "limit": self.limit,
        }


@dataclass
class MeshValidation:
    findings: list[Finding] = field(default_factory=list)
    measured: dict[str, Any] = field(default_factory=dict)

    @property
    def blocking(self) -> list[Finding]:
        return [item for item in self.findings if item.severity == "blocking"]

    @property
    def major(self) -> list[Finding]:
        return [item for item in self.findings if item.severity == "major"]

    @property
    def approved(self) -> bool:
        """Blocking findings only. A major finding is a defect, not a veto."""

        return not self.blocking

    @property
    def clean(self) -> bool:
        return not self.findings

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "approved": self.approved,
            "clean": self.clean,
            "blocking": len(self.blocking),
            "major": len(self.major),
            "minor": len(self.findings) - len(self.blocking) - len(self.major),
            "findings": [item.to_dict() for item in self.findings],
            "measured": self.measured,
        }

    def summary(self) -> str:
        if self.clean:
            return "mesh passes every Roblox rule"
        lines = []
        for severity in ("blocking", "major", "minor"):
            for finding in self.findings:
                if finding.severity == severity:
                    lines.append(f"[{severity}] {finding.rule}: {finding.message}")
        verdict = "APPROVED_FOR_IMPORT" if self.approved else "BLOCKED"
        return verdict + "\n" + "\n".join(lines)


@dataclass(frozen=True)
class Budget:
    """Per-asset limits, which a brief may tighten but never loosen."""

    triangles: int = TRIANGLE_LIMIT
    material_slots: int = MATERIAL_SLOT_LIMIT
    require_uv: bool = True
    require_watertight: bool = False
    max_dimension: float = MAX_DIMENSION_STUDS
    min_dimension: float = MIN_DIMENSION_STUDS

    def __post_init__(self) -> None:
        if self.triangles > TRIANGLE_LIMIT:
            raise ValueError(
                f"a budget may not exceed Roblox's {TRIANGLE_LIMIT}-triangle ceiling"
            )
        if self.material_slots > MATERIAL_SLOT_LIMIT:
            raise ValueError(
                f"a budget may not exceed {MATERIAL_SLOT_LIMIT} material slots"
            )


def validate(report: dict[str, Any], budget: Budget | None = None) -> MeshValidation:
    """Apply Roblox's rules to one object's analysis report."""

    budget = budget or Budget()
    findings: list[Finding] = []

    def add(rule: str, severity: str, message: str, measured: Any = None, limit: Any = None) -> None:
        findings.append(Finding(rule, severity, message, measured, limit))

    # -- arithmetic sanity, before anything is derived from positions ----
    non_finite = int(report.get("nonFiniteVertices", 0))
    if non_finite:
        add(
            "finite-coordinates", "blocking",
            f"{non_finite} vertices have NaN or infinite coordinates; every measurement "
            "derived from this mesh is meaningless",
            non_finite, 0,
        )

    # -- budget -----------------------------------------------------------
    triangles = int(report.get("triangles", 0))
    if triangles == 0:
        add("has-geometry", "blocking", "the mesh has no triangles", 0, 1)
    elif triangles > budget.triangles:
        add(
            "triangle-budget", "blocking",
            f"{triangles} triangles exceeds the budget of {budget.triangles}",
            triangles, budget.triangles,
        )
    elif triangles > TRIANGLE_ADVISORY:
        add(
            "triangle-advisory", "minor",
            f"{triangles} triangles is above {TRIANGLE_ADVISORY}; consider a reusable kit "
            "of smaller meshes rather than one large unique asset",
            triangles, TRIANGLE_ADVISORY,
        )

    # -- topology ---------------------------------------------------------
    degenerate = int(report.get("degenerateFaces", 0))
    if degenerate:
        add(
            "degenerate-faces", "blocking",
            f"{degenerate} faces have zero area; Roblox reports these as degenerate and "
            "they produce shading artefacts with no traceable cause",
            degenerate, 0,
        )

    non_manifold_edges = int(report.get("nonManifoldEdges", 0))
    if non_manifold_edges:
        add(
            "manifold", "blocking",
            f"{non_manifold_edges} edges are non-manifold; the importer rejects geometry "
            "where an edge joins zero or more than two faces",
            non_manifold_edges, 0,
        )

    ngons = int(report.get("ngons", 0))
    if ngons:
        add(
            "no-ngons", "major",
            f"{ngons} faces have more than four vertices; Roblox triangulates them "
            "unpredictably, so the shipped silhouette is not the authored one",
            ngons, 0,
        )

    boundary = int(report.get("boundaryEdges", 0))
    if budget.require_watertight and boundary:
        add(
            "watertight", "blocking",
            f"{boundary} boundary edges leave the mesh open, and this asset requires a "
            "closed volume",
            boundary, 0,
        )
    elif boundary:
        add(
            "open-mesh", "minor",
            f"{boundary} boundary edges; the mesh is a surface rather than a solid",
            boundary, 0,
        )

    zero_edges = int(report.get("zeroLengthEdges", 0))
    if zero_edges:
        add("zero-length-edges", "major", f"{zero_edges} edges have zero length", zero_edges, 0)

    loose_vertices = int(report.get("looseVertices", 0))
    loose_edges = int(report.get("looseEdges", 0))
    if loose_vertices or loose_edges:
        add(
            "loose-geometry", "major",
            f"{loose_vertices} vertices and {loose_edges} edges belong to no face; they "
            "survive export and count against the asset for nothing",
            {"vertices": loose_vertices, "edges": loose_edges}, 0,
        )

    duplicate_vertices = int(report.get("duplicateVertices", 0))
    if duplicate_vertices:
        add(
            "duplicate-vertices", "major",
            f"{duplicate_vertices} vertices sit on top of another; they double the vertex "
            "count and split shading along seams that are not visible in the viewport",
            duplicate_vertices, 0,
        )

    duplicate_faces = int(report.get("duplicateFaces", 0))
    if duplicate_faces:
        add(
            "duplicate-faces", "blocking",
            f"{duplicate_faces} faces are coincident with another; this z-fights in game",
            duplicate_faces, 0,
        )

    # -- normals ----------------------------------------------------------
    inconsistent = int(report.get("inconsistentNormalEdges", 0))
    if inconsistent:
        add(
            "consistent-normals", "blocking",
            f"{inconsistent} edges join faces whose winding disagrees; the surface will "
            "have holes when viewed from one side",
            inconsistent, 0,
        )

    flipped = int(report.get("flippedFaces", 0))
    if flipped:
        add(
            "outward-normals", "major",
            "the mesh is closed but inside out; it will render as a hole",
            flipped, 0,
        )

    # -- surface ----------------------------------------------------------
    if budget.require_uv and not report.get("hasUv"):
        add(
            "uv-present", "blocking",
            "the mesh has no UV layer, so no texture can ever be applied to it",
            False, True,
        )

    outside = int(report.get("uvOutsideUnitSquare", 0))
    if outside:
        add(
            "uv-range", "minor",
            f"{outside} UV coordinates fall outside 0..1; legitimate for tiling, but the "
            "asset cannot be atlased",
            outside, 0,
        )

    materials = int(report.get("materialCount", 0))
    if materials == 0:
        add("material-present", "major", "the mesh has no material slot", 0, 1)
    elif materials > budget.material_slots:
        add(
            "material-budget", "major",
            f"{materials} material slots exceeds {budget.material_slots}; each one is a "
            "separate draw call",
            materials, budget.material_slots,
        )

    # A slot no polygon points at is invisible. Left unreported, the manifest
    # claims a three-material asset and the render shows one flat colour, and
    # the discrepancy is invisible precisely where it matters -- in the receipt
    # somebody trusts instead of looking.
    unused = list(report.get("unusedMaterials") or [])
    if unused:
        used = int(report.get("materialSlotsUsed", 0))
        add(
            "material-unused", "major",
            f"{len(unused)} material slot(s) reach no faces ({', '.join(unused)}); the mesh "
            f"renders in {used} material(s) while declaring {materials}. Assign the slot with "
            "material.assign, or apply materials per part before joining",
            used, materials,
        )

    # -- placement --------------------------------------------------------
    dimensions = report.get("dimensions") or [0, 0, 0]
    largest = max(float(value) for value in dimensions) if dimensions else 0.0
    smallest = min(float(value) for value in dimensions) if dimensions else 0.0
    if largest > budget.max_dimension:
        add(
            "max-dimension", "blocking",
            f"the mesh is {largest:.1f} studs across; an asset this large is a map "
            "exported as one object, which defeats mesh reuse entirely",
            largest, budget.max_dimension,
        )
    if 0 < largest < budget.min_dimension:
        add(
            "min-dimension", "major",
            f"the mesh is only {largest:.3f} studs across and will be sub-pixel in game",
            largest, budget.min_dimension,
        )

    scale = report.get("scale") or [1, 1, 1]
    if any(abs(float(value) - 1.0) > 1e-4 for value in scale):
        add(
            "applied-scale", "major",
            f"object scale {scale} was not applied; a non-uniform scale exports as a "
            "transform and wrecks normals",
            scale, [1, 1, 1],
        )

    offset_ratio = float(report.get("originOffsetRatio", 0.0))
    if offset_ratio > MAX_ORIGIN_OFFSET_RATIO:
        add(
            "origin-placement", "major",
            f"the origin sits {offset_ratio:.2f} of the mesh's own size away from its "
            "centre; it will rotate around empty space when placed",
            round(offset_ratio, 3), MAX_ORIGIN_OFFSET_RATIO,
        )

    measured = {
        "triangles": triangles,
        # Both conventions carried forward. Anything comparing against a brief
        # must use the Y-up figures, because that is the convention a brief is
        # written in and the one the exported glTF uses.
        "dimensionsYUp": report.get("dimensionsYUp") or dimensions,
        "vertices": int(report.get("vertices", 0)),
        "materials": materials,
        "watertight": bool(report.get("watertight")),
        "hasUv": bool(report.get("hasUv")),
        "dimensions": dimensions,
        "largestDimension": largest,
        "smallestDimension": smallest,
    }
    return MeshValidation(findings=findings, measured=measured)


def validate_analysis(analysis: dict[str, Any], budget: Budget | None = None) -> MeshValidation:
    """Validate a whole analysis payload, including the one-object rule."""

    objects = analysis.get("objects") or {}
    if not objects:
        return MeshValidation(findings=[
            Finding("has-geometry", "blocking", "the analysis contains no mesh objects", 0, 1)
        ])

    primary = analysis.get("primary") or next(iter(objects))
    result = validate(objects[primary], budget)

    count = int(analysis.get("objectCount", len(objects)))
    if count > 1:
        # One asset is one mesh. More than one means the export carried
        # scaffolding, or a join never happened, and both ship geometry nobody
        # meant to ship.
        result.findings.insert(0, Finding(
            "single-object", "blocking",
            f"the export contains {count} mesh objects; an asset must be exactly one, "
            "or the extras ship with it",
            count, 1,
        ))
    return result
