"""Prove a visual spec's numbers were derived from tokens, not authored.

This closes the last of the three architectural problems raised against the
release gate. The first -- certifying the wrong product -- is handled by product
truth. The second was threshold provenance: `building >= 4`, `vegetation >= 12`,
`minimumSize [8, 6, 8]` all read as floors measured off the candidate, and a
spec derived from the artifact it grades passes by construction.

The structural fix is that art-direction numbers have exactly one home
(``tokens/<id>.json``) and both the builder and the grader project from it. This
module is the check that the projection actually happened: every threshold the
visual spec asserts is compared against the one `derive_visual_thresholds`
computes, and any number the tokens cannot account for is reported as
unattributed.

A spec that disagrees is not silently corrected. Correcting it would hide the
disagreement, and the disagreement is the finding.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .tokens import TokenSet, VisualThresholds, derive_visual_thresholds


#: Studs. Floating-point projection through JSON does not survive exact
#: equality, and a spec that rounds 24.0 to 24 is not smuggling anything.
DIMENSION_TOLERANCE = 0.01

#: sRGB channels. Zero, deliberately: a palette entry is either the token colour
#: or it is a different colour, and "close enough" is how a second palette grows
#: inside the first one.
COLOUR_TOLERANCE = 0


@dataclass
class ConformanceReport:
    """Which spec numbers trace to tokens and which do not."""

    token_set_id: str
    token_sha256: str
    spec_id: str
    spec_revision: int
    checked: int = 0
    matched: int = 0
    issues: list[str] = field(default_factory=list)

    @property
    def conforms(self) -> bool:
        return not self.issues

    @property
    def coverage(self) -> float:
        return round(self.matched / self.checked, 4) if self.checked else 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "tokenSetId": self.token_set_id,
            "tokenSha256": self.token_sha256,
            "specId": self.spec_id,
            "specRevision": self.spec_revision,
            "checked": self.checked,
            "matched": self.matched,
            "coverage": self.coverage,
            "conforms": self.conforms,
            "issues": list(self.issues),
        }


def _close(left: Any, right: Any, tolerance: float) -> bool:
    try:
        return abs(float(left) - float(right)) <= tolerance
    except (TypeError, ValueError):
        return False


def check(spec_data: dict[str, Any], tokens: TokenSet) -> ConformanceReport:
    """Compare every threshold in a visual spec against the token projection."""

    thresholds: VisualThresholds = derive_visual_thresholds(tokens)
    report = ConformanceReport(
        token_set_id=tokens.id,
        token_sha256=tokens.sha256,
        spec_id=str(spec_data.get("specId", "")),
        spec_revision=int(spec_data.get("revision", 0)),
    )

    _check_palette(spec_data, thresholds, report)
    _check_object_scale(spec_data, thresholds, report)
    _check_landmark_distances(spec_data, thresholds, report)
    return report


def _check_palette(spec_data: dict[str, Any], thresholds: VisualThresholds, report: ConformanceReport) -> None:
    swatches = spec_data.get("palette", {}).get("swatches", [])
    allowed = {tuple(colour) for colour in thresholds.allowed_colors}

    for swatch in swatches:
        if not isinstance(swatch, dict):
            continue
        report.checked += 1
        rgb = swatch.get("rgb")
        if not isinstance(rgb, list) or len(rgb) != 3:
            report.issues.append(f"palette swatch {swatch.get('id')!r} has no usable rgb")
            continue
        candidate = (int(rgb[0]), int(rgb[1]), int(rgb[2]))
        if candidate in allowed:
            report.matched += 1
            continue
        nearest = min(
            allowed,
            key=lambda colour: sum((a - b) ** 2 for a, b in zip(colour, candidate)),
            default=None,
        )
        report.issues.append(
            f"palette swatch {swatch.get('id')!r} rgb {list(candidate)} is not a token role "
            f"(nearest token colour {list(nearest) if nearest else 'none'})"
        )

    # A role the tokens declare but the spec never grades is a hole in the other
    # direction: the builder may paint with it and nothing checks the result.
    spec_colours = {
        (int(item["rgb"][0]), int(item["rgb"][1]), int(item["rgb"][2]))
        for item in swatches
        if isinstance(item, dict) and isinstance(item.get("rgb"), list) and len(item["rgb"]) == 3
    }
    ungraded = sorted(allowed - spec_colours)
    if ungraded:
        report.issues.append(
            f"{len(ungraded)} token palette role(s) have no swatch in the visual spec, "
            "so anything painted with them is ungraded"
        )


def _check_object_scale(spec_data: dict[str, Any], thresholds: VisualThresholds, report: ConformanceReport) -> None:
    for type_id, definition in spec_data.get("objectTypes", {}).items():
        if not isinstance(definition, dict):
            continue
        envelope = thresholds.object_scale.get(type_id)
        scale = definition.get("scale", {})
        minimum = scale.get("minimumSize")
        maximum = scale.get("maximumSize")

        if envelope is None:
            report.checked += 1
            report.issues.append(
                f"objectTypes.{type_id} has no token-derived envelope; its scale thresholds "
                "have no author"
            )
            continue

        for label, values, keys in (
            ("minimumSize", minimum, ("minX", "minY", "minZ")),
            ("maximumSize", maximum, ("maxX", "maxY", "maxZ")),
        ):
            report.checked += 1
            if not isinstance(values, list) or len(values) != 3:
                report.issues.append(f"objectTypes.{type_id}.scale.{label} is missing or malformed")
                continue
            expected = [envelope[key] for key in keys]
            if all(_close(a, b, DIMENSION_TOLERANCE) for a, b in zip(values, expected)):
                report.matched += 1
            else:
                report.issues.append(
                    f"objectTypes.{type_id}.scale.{label} is {values}, but the token grammar "
                    f"derives {[round(item, 2) for item in expected]}"
                )


def _check_landmark_distances(spec_data: dict[str, Any], thresholds: VisualThresholds, report: ConformanceReport) -> None:
    expected = thresholds.legibility.get("landmarkReadDistance")
    if expected is None:
        return
    for landmark_id, definition in spec_data.get("landmarks", {}).items():
        if not isinstance(definition, dict):
            continue
        report.checked += 1
        distance = definition.get("maximumDistance")
        if _close(distance, expected, DIMENSION_TOLERANCE):
            report.matched += 1
        else:
            report.issues.append(
                f"landmarks.{landmark_id}.maximumDistance is {distance}, but the token "
                f"legibility scale derives {expected}"
            )


def projected_spec_fragment(tokens: TokenSet) -> dict[str, Any]:
    """The spec fragment a token set implies, for authoring a conforming spec.

    Emitted so a spec author does not have to reverse-engineer the projection by
    hand and, in doing so, reintroduce exactly the hand-authored numbers this
    module exists to detect.
    """

    thresholds = derive_visual_thresholds(tokens)
    swatches = [
        {
            "id": role.id,
            "rgb": list(role.srgb),
            "roles": [role.tier],
        }
        for role in sorted(tokens.roles.values(), key=lambda item: item.id)
    ]
    object_types = {
        type_id: {
            "scale": {
                "boundsMethod": "oriented-box",
                "minimumSize": [
                    round(envelope["minX"], 2),
                    round(envelope["minY"], 2),
                    round(envelope["minZ"], 2),
                ],
                "maximumSize": [
                    round(envelope["maxX"], 2),
                    round(envelope["maxY"], 2),
                    round(envelope["maxZ"], 2),
                ],
            }
        }
        for type_id, envelope in thresholds.object_scale.items()
    }
    return {
        "palette": {"swatches": swatches},
        "objectTypes": object_types,
        "landmarkMaximumDistance": thresholds.legibility.get("landmarkReadDistance"),
        "derivedFrom": {
            "tokenSetId": tokens.id,
            "tokenSha256": tokens.sha256,
            "revision": tokens.revision,
        },
    }
