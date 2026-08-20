"""Materials for a modelling program: built from tokens, checked before building.

The MetaWorldModel document asks for a `material.create` / `apply` / `validate`
family, and the reason it deserves to be a family rather than a parameter is
what the visual critic measures. `material_separation` is 28% of an asset's
score, and the way it fails is not subtle: the whole surface reads as one value,
the eye lands nowhere, and every hour of modelling underneath it is wasted.

Three things live here, and all three are things worth doing *before* Blender
runs. A build plus five renders costs a minute; a flat palette is knowable in
milliseconds from the numbers alone. Catching it after the render is not wrong,
it is just needlessly expensive and arrives with less to say.

**Colours come from the token set.** A modelling program that names its own RGB
is a second palette that drifts from the game's, and then the asset looks
correct alone and wrong in the world it was built for.

**Application is per part, before the join.** This is the shape of the defect
found while calibrating the critic: appending material slots to an object does
not put anything in them -- every polygon keeps `material_index` 0 -- so an
asset declaring three materials rendered entirely in the first while the
manifest reported three. Assigning to parts and letting the join merge them is
the pattern that actually works, so it is the pattern this module emits.

**Validation predicts the critic rather than restating it.** The same luminance
figure the critic measures from pixels can be computed from the palette, so
`validate` says "this will read as flat" before the render exists to prove it.
It is a prediction and says so: lighting, roughness and geometry all move the
measured value, and the check is deliberately loose enough that only a genuinely
flat set trips it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterable


#: Roblox renders and skins per material slot, and each one is a draw call.
#: Mirrors `validation.MATERIAL_SLOT_LIMIT`; imported rather than restated where
#: the two must agree.
from .validation import MATERIAL_SLOT_LIMIT

#: Rec. 709 luminance weights. The same ones the critic's greyscale conversion
#: uses, so a prediction here is comparable to a measurement there.
LUMA = (0.2126, 0.7152, 0.0722)

#: Predicted luminance spread below which the surface will read as one material.
#: Deliberately below the critic's measured floor of 45: lighting and shading
#: add spread that a flat palette cannot, so a palette scoring just under the
#: measured bar may still pass once rendered. Only a genuinely flat set trips
#: this, and a warning that fires on assets which turn out fine is a warning
#: people learn to ignore.
FLAT_PALETTE_SPREAD = 28.0

#: Minimum separation between the lightest and darkest slot. A dark and a light
#: are what make parts readable; two mid tones are not a palette.
MIN_VALUE_RANGE = 60.0


class MaterialError(ValueError):
    """The material set could not be built or is not usable."""


@dataclass(frozen=True)
class MaterialSlot:
    """One slot, in the shape a modelling program's `material` step takes."""

    name: str
    base_color: tuple[int, int, int]
    roughness: float = 0.6
    metallic: float = 0.0
    emissive: tuple[int, int, int] | None = None
    emissive_strength: float = 0.0
    source: str = ""

    @property
    def luminance(self) -> float:
        return sum(weight * channel for weight, channel in zip(LUMA, self.base_color))

    @property
    def is_focal(self) -> bool:
        """Whether this slot can pull the eye.

        The critic's focal-contrast measure asks whether anything on the asset
        reads as a highlight. Emission is the reliable way to produce one; a
        merely light material competes with lighting rather than beating it.
        """

        return self.emissive is not None and self.emissive_strength > 0

    def to_step_slot(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "name": self.name,
            "baseColor": list(self.base_color),
            "roughness": round(float(self.roughness), 3),
        }
        if self.metallic:
            payload["metallic"] = round(float(self.metallic), 3)
        if self.emissive is not None:
            payload["emissive"] = list(self.emissive)
            payload["emissiveStrength"] = round(float(self.emissive_strength), 3)
        return payload

    def to_dict(self) -> dict[str, Any]:
        return {
            **self.to_step_slot(),
            "luminance": round(self.luminance, 1),
            "focal": self.is_focal,
            "source": self.source,
        }


def _clamp_channel(value: float) -> int:
    return max(0, min(255, int(round(value))))


def create(
    role: str,
    *,
    tokens: dict[str, Any],
    name: str | None = None,
    roughness: float | None = None,
    metallic: float = 0.0,
    emissive: bool = False,
    emissive_strength: float = 3.5,
    darken: float = 0.0,
) -> MaterialSlot:
    """Build one slot from a named palette role in a token set.

    `darken` shifts the value without inventing a hue -- a recess or a trim is
    the same colour in shadow, and deriving it keeps the asset inside the
    palette instead of beside it.
    """

    roles = (tokens.get("palette") or {}).get("roles") or {}
    if role not in roles:
        raise MaterialError(
            f"unknown palette role {role!r}; available: {', '.join(sorted(roles))}"
        )
    entry = roles[role]
    srgb = entry.get("srgb")
    if not isinstance(srgb, (list, tuple)) or len(srgb) != 3:
        raise MaterialError(f"palette role {role!r} has no usable srgb triple")

    if not 0.0 <= darken < 1.0:
        raise MaterialError("darken must be in [0, 1)")
    factor = 1.0 - darken
    base = tuple(_clamp_channel(channel * factor) for channel in srgb)

    return MaterialSlot(
        name=name or (role if not darken else f"{role}Shadow"),
        base_color=base,  # type: ignore[arg-type]
        roughness=0.6 if roughness is None else float(roughness),
        metallic=float(metallic),
        emissive=tuple(srgb) if emissive else None,  # type: ignore[arg-type]
        emissive_strength=float(emissive_strength) if emissive else 0.0,
        source=f"token:{role}" + (f"@darken{darken:.2f}" if darken else ""),
    )


def apply(
    program: dict[str, Any],
    assignments: dict[str, MaterialSlot],
) -> dict[str, Any]:
    """Insert per-part `material` steps into a modelling program.

    Each step is placed immediately after the part it paints and before any
    `join`, which is the only ordering that actually works: Blender remaps
    material indices when objects merge, so parts painted separately survive the
    join with their own materials, while slots appended to the joined result
    reach no faces at all.
    """

    steps = list(program.get("steps") or [])
    if not steps:
        raise MaterialError("a program with no steps has nothing to paint")

    created = {step.get("name") for step in steps if step.get("name")}
    unknown = [target for target in assignments if target not in created]
    if unknown:
        raise MaterialError(
            f"nothing in this program creates {', '.join(sorted(unknown))}; "
            f"it builds: {', '.join(sorted(n for n in created if n))}"
        )

    join_at = next(
        (index for index, step in enumerate(steps) if step.get("op") == "join"),
        len(steps),
    )

    out: list[dict[str, Any]] = []
    painted: set[str] = set()
    for index, step in enumerate(steps):
        # Drop material steps that would land on the joined result: they are the
        # bug this function exists to avoid emitting.
        if step.get("op") == "material" and index > join_at:
            continue
        out.append(step)
        name = step.get("name")
        if index < join_at and name in assignments and name not in painted:
            out.append({
                "op": "material",
                "target": name,
                "assign": 0,
                "slots": [assignments[name].to_step_slot()],
            })
            painted.add(name)

    unpainted = set(assignments) - painted
    if unpainted:
        raise MaterialError(
            f"could not place materials for {', '.join(sorted(unpainted))}: the part is "
            "created after the join, so nothing survives to paint"
        )

    return dict(program, steps=out)


def validate(slots: Iterable[MaterialSlot]) -> dict[str, Any]:
    """Predict what the critic will measure, before anything is built."""

    slots = list(slots)
    findings: list[dict[str, str]] = []

    def add(rule: str, severity: str, message: str) -> None:
        findings.append({"rule": rule, "severity": severity, "message": message})

    if not slots:
        add("material-present", "blocking", "no materials: the asset has nothing to render with")
        return {
            "schemaVersion": 1, "ok": False, "slots": 0, "findings": findings,
            "predicted": {}, "prediction": _disclaimer(),
        }

    names = [slot.name for slot in slots]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        add("material-duplicate", "major",
            f"{', '.join(duplicates)} declared more than once; a duplicate slot is a "
            "draw call that renders the same thing")

    if len(slots) > MATERIAL_SLOT_LIMIT:
        add("material-budget", "major",
            f"{len(slots)} slots exceeds Roblox's {MATERIAL_SLOT_LIMIT}; each one is a draw call")

    luminances = [slot.luminance for slot in slots]
    value_range = max(luminances) - min(luminances)
    mean = sum(luminances) / len(luminances)
    spread = (sum((value - mean) ** 2 for value in luminances) / len(luminances)) ** 0.5

    if value_range < MIN_VALUE_RANGE:
        add("material-value-range", "major",
            f"lightest and darkest slot are only {value_range:.0f} apart; a dark and a "
            "light are what make the parts readable, not two mid tones")

    if spread < FLAT_PALETTE_SPREAD:
        add("material-flat", "major",
            f"predicted luminance spread {spread:.0f} will read as a single flat value; "
            "the critic scores material separation at 28% of the total")

    if not any(slot.is_focal for slot in slots):
        add("material-no-focal", "minor",
            "nothing in this set is emissive, so nothing will pull the eye; the critic "
            "measures focal contrast and an asset with no highlight scores low on it")

    blocking = [f for f in findings if f["severity"] == "blocking"]
    major = [f for f in findings if f["severity"] == "major"]
    return {
        "schemaVersion": 1,
        "ok": not blocking and not major,
        "slots": len(slots),
        "findings": findings,
        "predicted": {
            "luminanceSpread": round(spread, 1),
            "valueRange": round(value_range, 1),
            "lightest": round(max(luminances), 1),
            "darkest": round(min(luminances), 1),
            "focalSlots": [slot.name for slot in slots if slot.is_focal],
        },
        "prediction": _disclaimer(),
    }


def _disclaimer() -> str:
    return (
        "predicted from the palette alone. Lighting, roughness and geometry all move "
        "the value the critic measures from the render, so this is a cheap early "
        "warning and not a substitute for scoring the frames"
    )


def palette_roles(tokens: dict[str, Any]) -> list[dict[str, Any]]:
    """The roles available to build from, with the tier each one belongs to."""

    roles = (tokens.get("palette") or {}).get("roles") or {}
    return [
        {
            "role": name,
            "srgb": list(entry.get("srgb", [])),
            "tier": entry.get("tier"),
            "usage": entry.get("usage", ""),
            "luminance": round(
                sum(w * c for w, c in zip(LUMA, entry.get("srgb", (0, 0, 0)))), 1
            ),
        }
        for name, entry in sorted(roles.items())
    ]
