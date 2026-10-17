"""L0 design tokens, read from the same file the Luau builder reads.

The quality engine used to carry its own copy of every art-direction number.
That is how a spec ends up describing the build it grades: whoever wrote the
threshold was looking at the candidate.  Here the numbers have exactly one home
-- ``tokens/<id>.json`` -- and both sides project from it.  A threshold the
builder does not also obey cannot exist, and a threshold nobody authored cannot
appear.

``derive_visual_thresholds`` is the projection.  It is deliberately total: every
number a visual rule may use is computed here, so a rule cannot smuggle in a
literal.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from .provenance import sha256_file
from .schema_validation import SchemaDefinitionError, validate_schema_instance
from .security import SecurityBoundaryError, resolve_inside


TOKENS_SCHEMA_VERSION = 1

#: A token set may never claim to have been derived from the thing it governs.
#: The schema enum is the primary gate; this constant keeps the prohibition
#: greppable and catches token sets built in memory rather than loaded from disk.
FORBIDDEN_DERIVATIONS = frozenset({"measured-from-candidate", "candidate", "self"})

VALID_TIERS = ("dominant", "supporting", "accent")


class TokenError(ValueError):
    """The token set cannot be used to build or to grade."""


@dataclass(frozen=True)
class PaletteRole:
    id: str
    srgb: tuple[int, int, int]
    material: str
    tier: str
    usage: str
    minimum_surface_coverage: float | None = None
    maximum_surface_coverage: float | None = None
    reflectance: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "srgb": list(self.srgb),
            "material": self.material,
            "tier": self.tier,
            "usage": self.usage,
            "minimumSurfaceCoverage": self.minimum_surface_coverage,
            "maximumSurfaceCoverage": self.maximum_surface_coverage,
            "reflectance": self.reflectance,
        }


@dataclass(frozen=True)
class TokenSet:
    path: Path
    schema_path: Path
    sha256: str
    data: dict[str, Any]
    roles: dict[str, PaletteRole]

    @property
    def id(self) -> str:
        return str(self.data["tokenSetId"])

    @property
    def revision(self) -> int:
        return int(self.data["revision"])

    # -- accessors -------------------------------------------------------
    # Each one refuses to invent a default.  A missing token is an authoring
    # bug, and returning zero for it would produce a world that builds and a
    # rule that passes, both of them wrong.

    def _demand(self, mapping: dict[str, Any], key: str, what: str) -> Any:
        if key not in mapping:
            available = ", ".join(sorted(mapping))
            raise TokenError(f"unknown {what} {key!r}; available: {available}")
        return mapping[key]

    def role(self, role_id: str) -> PaletteRole:
        if role_id not in self.roles:
            available = ", ".join(sorted(self.roles))
            raise TokenError(f"unknown palette role {role_id!r}; available: {available}")
        return self.roles[role_id]

    def roles_by_tier(self, tier: str) -> tuple[PaletteRole, ...]:
        if tier not in VALID_TIERS:
            raise TokenError(f"unknown palette tier {tier!r}")
        return tuple(sorted(
            (role for role in self.roles.values() if role.tier == tier),
            key=lambda item: item.id,
        ))

    def grammar(self, metric: str) -> float:
        return float(self._demand(self.data["scale"]["grammar"], metric, "scale.grammar metric"))

    def character(self, metric: str) -> float:
        return float(self._demand(self.data["scale"]["character"], metric, "scale.character metric"))

    def legibility(self, metric: str) -> float:
        return float(self._demand(self.data["scale"]["legibility"], metric, "scale.legibility metric"))

    def spacing(self, step: str) -> float:
        return float(self._demand(self.data["spacing"]["steps"], step, "spacing step"))

    def text(self, step: str) -> float:
        return float(self._demand(self.data["typography"]["steps"], step, "typography step"))

    def duration(self, name: str) -> float:
        return float(self._demand(self.data["motion"]["durations"], name, "motion duration"))

    def mood(self, mood_id: str) -> dict[str, Any]:
        return dict(self._demand(self.data["moods"], mood_id, "mood"))

    def mood_ids(self) -> tuple[str, ...]:
        return tuple(sorted(self.data["moods"]))

    def camera(self, camera_id: str) -> dict[str, Any]:
        return dict(self._demand(self.data["cameras"], camera_id, "camera profile"))

    def camera_ids(self) -> tuple[str, ...]:
        return tuple(sorted(self.data["cameras"]))

    @property
    def harmony(self) -> dict[str, Any]:
        return dict(self.data["palette"]["harmony"])

    @property
    def provenance(self) -> dict[str, Any]:
        return dict(self.data["provenance"])

    def reference_hashes(self) -> tuple[str, ...]:
        refs = self.provenance.get("references", [])
        return tuple(str(item["sha256"]) for item in refs if isinstance(item, dict) and item.get("sha256"))

    def to_plan_metadata(self, root: Path) -> dict[str, Any]:
        return {
            "path": self.path.relative_to(root).as_posix(),
            "schemaPath": self.schema_path.relative_to(root).as_posix(),
            "tokenSetId": self.id,
            "revision": self.revision,
            "sha256": self.sha256,
            "derivation": self.provenance.get("derivation"),
            "referenceCount": len(self.reference_hashes()),
            "roleCount": len(self.roles),
        }


# ---------------------------------------------------------------- colour


def _srgb_to_linear(channel: float) -> float:
    channel /= 255.0
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def relative_luminance(srgb: Iterable[int]) -> float:
    """WCAG relative luminance, used for the palette's lightness spread."""

    red, green, blue = (_srgb_to_linear(float(value)) for value in srgb)
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue


def hue_degrees(srgb: Iterable[int]) -> float:
    """Hue in degrees, for counting how many colour families a palette uses."""

    red, green, blue = (float(value) / 255.0 for value in srgb)
    high, low = max(red, green, blue), min(red, green, blue)
    span = high - low
    if span == 0:
        return 0.0
    if high == red:
        hue = ((green - blue) / span) % 6
    elif high == green:
        hue = (blue - red) / span + 2
    else:
        hue = (red - green) / span + 4
    return (hue * 60.0) % 360.0


def hue_family(srgb: Iterable[int], families: int = 8) -> int:
    """Bucket a colour into one of `families` hue sectors.

    Eight sectors, not twelve: 45 degrees is roughly the width of a named hue
    family (red, orange, yellow, green, cyan, blue, purple, magenta), while 30
    degrees splits perceptual greens across two buckets and reports a
    disciplined palette as undisciplined. Measured on this repository's own
    token set, which uses grass at 100 degrees and a success accent at 129 --
    the same green to any viewer, two families to a 30-degree bucket.

    Near-greys are their own family: two desaturated colours with wildly
    different nominal hues read as the same neutral, and counting them as two
    families would wrongly accuse a disciplined palette.
    """

    values = [float(item) / 255.0 for item in srgb]
    span = max(values) - min(values)
    if span < 0.08:
        return -1
    sector = 360.0 / families
    return int(hue_degrees(srgb) // sector)


# ------------------------------------------------------------------ load


def _resolve_inside(root: Path, base: Path, relative: Any, label: str) -> Path:
    if not isinstance(relative, str) or not relative:
        raise TokenError(f"{label} must be a non-empty relative path")
    root = root.resolve()
    try:
        base_relative = base.resolve().relative_to(root)
        return resolve_inside(
            root,
            base_relative / relative,
            label=label,
            must_exist=True,
            file_only=True,
            suffixes=(".json",),
        )
    except (SecurityBoundaryError, ValueError) as exc:
        raise TokenError(str(exc)) from exc


def _semantic_issues(data: dict[str, Any]) -> list[str]:
    """Checks the schema cannot express, all of them load-bearing."""

    issues: list[str] = []

    derivation = str(data.get("provenance", {}).get("derivation", ""))
    if derivation in FORBIDDEN_DERIVATIONS:
        issues.append(
            f"provenance.derivation {derivation!r} would make every threshold a tautology"
        )
    if derivation == "external-reference" and not data.get("provenance", {}).get("references"):
        issues.append("provenance.derivation is external-reference but no references are cited")

    scale = data["scale"]
    character, grammar = scale["character"], scale["grammar"]
    if grammar["stairRise"] > character["maxStepUp"]:
        issues.append(
            f"scale.grammar.stairRise ({grammar['stairRise']}) exceeds "
            f"scale.character.maxStepUp ({character['maxStepUp']}); those stairs are unclimbable"
        )
    if grammar["doorHeight"] <= character["height"]:
        issues.append("scale.grammar.doorHeight must exceed scale.character.height")
    if grammar["doorWidth"] <= character["width"]:
        issues.append("scale.grammar.doorWidth must exceed scale.character.width")
    if grammar["ceilingHeight"] < grammar["doorHeight"]:
        issues.append("scale.grammar.ceilingHeight must be at least doorHeight")
    if grammar["corridorWidth"] < character["width"] * 2:
        issues.append("scale.grammar.corridorWidth must fit two characters abreast")

    legibility = scale["legibility"]
    if legibility["labelReadDistance"] >= legibility["signageReadDistance"]:
        issues.append("scale.legibility.labelReadDistance must be shorter than signageReadDistance")
    if legibility["signageReadDistance"] >= legibility["landmarkReadDistance"]:
        issues.append("scale.legibility.signageReadDistance must be shorter than landmarkReadDistance")

    roles = data["palette"]["roles"]
    harmony = data["palette"]["harmony"]

    accent_total = 0.0
    for role_id, role in roles.items():
        minimum = role.get("minSurfaceCoverage")
        maximum = role.get("maxSurfaceCoverage")
        if minimum is not None and maximum is not None and minimum > maximum:
            issues.append(f"palette.roles.{role_id} minimum coverage exceeds maximum")
        if role["tier"] == "accent":
            if maximum is None:
                issues.append(f"palette.roles.{role_id} is an accent and must declare maxSurfaceCoverage")
            else:
                accent_total += float(maximum)
    budget = float(harmony["accentTotalMaxCoverage"])
    if accent_total > budget + 1e-9:
        issues.append(
            f"declared accent coverage {accent_total:.3f} exceeds "
            f"palette.harmony.accentTotalMaxCoverage {budget:.3f}"
        )

    if not any(role["tier"] == "dominant" for role in roles.values()):
        issues.append("palette.roles must contain at least one dominant role")

    families = {hue_family(role["srgb"]) for role in roles.values()}
    families.discard(-1)
    if len(families) > int(harmony["maxHueFamilies"]):
        issues.append(
            f"palette uses {len(families)} hue families, above "
            f"palette.harmony.maxHueFamilies {harmony['maxHueFamilies']}"
        )

    luminances = [relative_luminance(role["srgb"]) for role in roles.values()]
    spread = max(luminances) - min(luminances)
    if spread < float(harmony["minLightnessSpread"]):
        issues.append(
            f"palette lightness spread {spread:.3f} is below "
            f"palette.harmony.minLightnessSpread {harmony['minLightnessSpread']}; "
            "a palette this flat has no silhouette contrast"
        )

    forbidden = set(harmony.get("forbiddenMaterials", []))
    for role_id, role in roles.items():
        if role["material"] in forbidden:
            issues.append(f"palette.roles.{role_id} uses forbidden material {role['material']}")

    for mood_id, mood in data["moods"].items():
        lighting = mood["lighting"]
        if lighting["technology"] != "Future" and lighting.get("shadowSoftness") is not None:
            issues.append(f"moods.{mood_id} sets shadowSoftness but does not use Future lighting")
        bloom = mood["post"]["bloom"]
        if bloom["intensity"] > 0 and bloom["threshold"] <= 0:
            issues.append(f"moods.{mood_id} bloom threshold 0 blooms the entire frame")

    return issues


def load_token_set(root: Path, relative: str, *, schema_root: Path | None = None) -> TokenSet:
    """Load, validate and hash a token set."""

    root = Path(root).resolve()
    path = _resolve_inside(root, root, relative, "token set")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise TokenError("token set must be a JSON object")

    schema_path = _resolve_inside(
        root, (schema_root or path.parent), data.get("$schema"), "token set $schema"
    )
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    try:
        issues = [str(issue) for issue in validate_schema_instance(data, schema)]
    except SchemaDefinitionError as exc:
        raise TokenError(f"invalid token schema definition: {exc}") from exc
    # Semantic checks index into the document freely, so they only run once the
    # shape is known good. Reporting "stairRise is missing" twice helps nobody.
    if not issues:
        issues.extend(_semantic_issues(data))
    if issues:
        raise TokenError("token set is invalid:\n- " + "\n- ".join(issues))

    roles = {
        role_id: PaletteRole(
            id=role_id,
            srgb=(int(raw["srgb"][0]), int(raw["srgb"][1]), int(raw["srgb"][2])),
            material=str(raw["material"]),
            tier=str(raw["tier"]),
            usage=str(raw["usage"]),
            minimum_surface_coverage=raw.get("minSurfaceCoverage"),
            maximum_surface_coverage=raw.get("maxSurfaceCoverage"),
            reflectance=float(raw.get("reflectance", 0.0)),
        )
        for role_id, raw in data["palette"]["roles"].items()
    }

    return TokenSet(
        path=path,
        schema_path=schema_path,
        sha256=sha256_file(path),
        data=data,
        roles=roles,
    )


# ------------------------------------------------------------ projection


@dataclass(frozen=True)
class VisualThresholds:
    """Every number a visual rule is allowed to use, projected from tokens.

    A rule that needs a value not present here is a rule whose threshold has no
    author.  That is the condition this type exists to make impossible.
    """

    token_set_id: str
    token_sha256: str
    allowed_colors: tuple[tuple[int, int, int], ...]
    allowed_materials: tuple[str, ...]
    forbidden_materials: tuple[str, ...]
    max_delta_e_to_nearest_role: float
    max_hue_families: int
    min_lightness_spread: float
    accent_total_max_coverage: float
    role_coverage: dict[str, dict[str, float | None]]
    object_scale: dict[str, dict[str, float]]
    legibility: dict[str, float]
    grammar: dict[str, float]

    def to_dict(self) -> dict[str, Any]:
        return {
            "tokenSetId": self.token_set_id,
            "tokenSha256": self.token_sha256,
            "allowedColors": [list(color) for color in self.allowed_colors],
            "allowedMaterials": list(self.allowed_materials),
            "forbiddenMaterials": list(self.forbidden_materials),
            "maxDeltaEToNearestRole": self.max_delta_e_to_nearest_role,
            "maxHueFamilies": self.max_hue_families,
            "minLightnessSpread": self.min_lightness_spread,
            "accentTotalMaxCoverage": self.accent_total_max_coverage,
            "roleCoverage": self.role_coverage,
            "objectScale": self.object_scale,
            "legibility": self.legibility,
            "grammar": self.grammar,
        }


def derive_visual_thresholds(tokens: TokenSet) -> VisualThresholds:
    """Project a token set into the thresholds a visual spec may assert."""

    harmony = tokens.harmony
    grammar = {key: float(value) for key, value in tokens.data["scale"]["grammar"].items()}
    legibility = {key: float(value) for key, value in tokens.data["scale"]["legibility"].items()}

    building_footprint = grammar["buildingMinFootprint"]
    building_height = grammar["buildingMinHeight"]
    landmark_height = grammar["landmarkMinHeight"]
    plot = grammar["plotMinDimension"]

    # Object-scale envelopes are derived, not chosen.  A building may not be
    # smaller than the grammar says a building is, and may not be so large it
    # swallows a plot -- which is the failure that produced "a house lost in the
    # middle of nowhere" the first time round.
    object_scale = {
        "building": {
            "minX": building_footprint,
            "minY": building_height,
            "minZ": building_footprint,
            "maxX": plot,
            "maxY": landmark_height * 4.0,
            "maxZ": plot,
        },
        "interactive": {
            "minX": tokens.character("width") * 0.4,
            "minY": tokens.character("width") * 0.4,
            "minZ": tokens.character("width") * 0.4,
            "maxX": grammar["corridorWidth"] * 2.0,
            "maxY": grammar["ceilingHeight"] * 1.5,
            "maxZ": grammar["corridorWidth"] * 2.0,
        },
        "vegetation": {
            "minX": tokens.character("width") * 0.5,
            "minY": tokens.character("height") * 0.5,
            "minZ": tokens.character("width") * 0.5,
            "maxX": building_footprint * 1.5,
            "maxY": landmark_height * 2.0,
            "maxZ": building_footprint * 1.5,
        },
        "landmark": {
            "minX": building_footprint,
            "minY": landmark_height,
            "minZ": building_footprint,
            "maxX": plot * 2.0,
            "maxY": landmark_height * 6.0,
            "maxZ": plot * 2.0,
        },
    }

    role_coverage = {
        role.id: {
            "minimum": role.minimum_surface_coverage,
            "maximum": role.maximum_surface_coverage,
            "tier": role.tier,
        }
        for role in sorted(tokens.roles.values(), key=lambda item: item.id)
    }

    materials = sorted({role.material for role in tokens.roles.values()})

    return VisualThresholds(
        token_set_id=tokens.id,
        token_sha256=tokens.sha256,
        allowed_colors=tuple(
            role.srgb for role in sorted(tokens.roles.values(), key=lambda item: item.id)
        ),
        allowed_materials=tuple(materials),
        forbidden_materials=tuple(harmony.get("forbiddenMaterials", [])),
        max_delta_e_to_nearest_role=float(harmony["maxDeltaEToNearestRole"]),
        max_hue_families=int(harmony["maxHueFamilies"]),
        min_lightness_spread=float(harmony["minLightnessSpread"]),
        accent_total_max_coverage=float(harmony["accentTotalMaxCoverage"]),
        role_coverage=role_coverage,  # type: ignore[arg-type]
        object_scale=object_scale,
        legibility=legibility,
        grammar=grammar,
    )


def external_reference_issues(tokens: TokenSet, candidate_roots: Iterable[Path]) -> list[str]:
    """Prove the cited references are not the candidate wearing a hash.

    Declaring ``derivation: external-reference`` is cheap; a screenshot of our
    own build satisfies the schema perfectly well. This walks the candidate
    trees and rejects any reference whose content is already in them, which is
    the only mechanical way to tell an outside standard from a mirror.
    """

    import hashlib

    cited = set(tokens.reference_hashes())
    if not cited:
        return []

    issues: list[str] = []
    for root in candidate_roots:
        root = Path(root)
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest in cited:
                issues.append(
                    f"reference {digest[:12]} is also present in the candidate tree at "
                    f"{path}; a token set may not calibrate against its own build"
                )
    return sorted(set(issues))


def calibration_receipt(tokens: TokenSet, thresholds: VisualThresholds) -> dict[str, Any]:
    """Prove where every threshold came from, in a form the gate can check."""

    return {
        "schemaVersion": 1,
        "tokenSetId": tokens.id,
        "tokenRevision": tokens.revision,
        "tokenSha256": tokens.sha256,
        "derivation": tokens.provenance.get("derivation"),
        "authoredBy": tokens.provenance.get("authoredBy"),
        "authoredAt": tokens.provenance.get("authoredAt"),
        "referenceHashes": list(tokens.reference_hashes()),
        "thresholds": thresholds.to_dict(),
    }
