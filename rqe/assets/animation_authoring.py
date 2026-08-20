"""Procedural animation, authored as a KeyframeSequence.

Animation is the asset class with the narrowest legitimate path on this
platform, and the narrowness is worth stating plainly:

- `KeyframeSequenceProvider:RegisterKeyframeSequence` returns a **Studio-only**
  temporary id. It is fine for a look in the viewport and useless in a shipped
  game, so nothing here uses it.
- The Open Cloud Assets API accepts animations as `.rbxm` and `.rbxmx`. That is
  the route, and it is what this module writes.
- Roblox warns that externally authored files "might not upload successfully",
  because Studio normally does processing on the way in. So a generated
  `.rbxmx` is a **candidate** for upload, never a guaranteed one, and the upload
  result is the only thing that settles it.

The third option remains the best one for most motion: drive `Motor6D` from code
per frame. No asset, no upload, no moderation, and it works in all three
execution surfaces. `GameKit` is where that belongs; this module exists for the
cases where a real Animation asset is genuinely required.

Poses address joints by name. In an R15 rig a pose applies to the `Motor6D`
whose `Part1` carries the same name, which is why the joint vocabulary below is
part names rather than joint names.
"""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence
from xml.sax.saxutils import escape


#: R15 parts a pose may target. Closed on purpose: a misspelled joint silently
#: animates nothing, and a keyframe that animates nothing is indistinguishable
#: from one that was never authored.
R15_JOINTS = (
    "LowerTorso", "UpperTorso", "Head",
    "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot",
)

#: Roblox's own hierarchy, needed because a KeyframeSequence is a tree of Poses
#: and a pose applied to the wrong parent moves the wrong limb.
R15_PARENTS = {
    "LowerTorso": "HumanoidRootPart",
    "UpperTorso": "LowerTorso",
    "Head": "UpperTorso",
    "LeftUpperArm": "UpperTorso", "LeftLowerArm": "LeftUpperArm", "LeftHand": "LeftLowerArm",
    "RightUpperArm": "UpperTorso", "RightLowerArm": "RightUpperArm", "RightHand": "RightLowerArm",
    "LeftUpperLeg": "LowerTorso", "LeftLowerLeg": "LeftUpperLeg", "LeftFoot": "LeftLowerLeg",
    "RightUpperLeg": "LowerTorso", "RightLowerLeg": "RightUpperLeg", "RightFoot": "RightLowerLeg",
}

EASING_STYLES = ("Linear", "Constant", "Cubic", "Elastic", "Bounce")
EASING_DIRECTIONS = ("In", "Out", "InOut")

MAX_SECONDS = 30.0
MAX_KEYFRAMES = 240


class AnimationAuthoringError(ValueError):
    """The animation could not be authored."""


@dataclass(frozen=True)
class Pose:
    """One joint at one moment, as Euler degrees and an optional offset."""

    joint: str
    rotation: tuple[float, float, float] = (0.0, 0.0, 0.0)
    offset: tuple[float, float, float] = (0.0, 0.0, 0.0)

    def __post_init__(self) -> None:
        if self.joint not in R15_JOINTS:
            raise AnimationAuthoringError(
                f"unknown joint {self.joint!r}; an R15 pose must name one of: "
                + ", ".join(R15_JOINTS)
            )


@dataclass(frozen=True)
class Keyframe:
    time: float
    poses: tuple[Pose, ...]

    def __post_init__(self) -> None:
        if self.time < 0:
            raise AnimationAuthoringError("keyframe time must not be negative")
        if not self.poses:
            raise AnimationAuthoringError(
                f"the keyframe at {self.time}s has no poses, so it animates nothing"
            )
        seen = [pose.joint for pose in self.poses]
        duplicates = sorted({name for name in seen if seen.count(name) > 1})
        if duplicates:
            raise AnimationAuthoringError(
                f"the keyframe at {self.time}s poses these joints twice: {', '.join(duplicates)}"
            )


@dataclass(frozen=True)
class Animation:
    id: str
    keyframes: tuple[Keyframe, ...]
    looped: bool = False
    priority: str = "Action"
    generator: str = "authored"

    def __post_init__(self) -> None:
        if not self.keyframes:
            raise AnimationAuthoringError("an animation needs at least one keyframe")
        if len(self.keyframes) > MAX_KEYFRAMES:
            raise AnimationAuthoringError(f"at most {MAX_KEYFRAMES} keyframes")
        times = [frame.time for frame in self.keyframes]
        if times != sorted(times):
            raise AnimationAuthoringError("keyframes must be in ascending time order")
        if len(set(times)) != len(times):
            raise AnimationAuthoringError("two keyframes share the same time")
        if self.duration > MAX_SECONDS:
            raise AnimationAuthoringError(f"an animation may not exceed {MAX_SECONDS} seconds")
        if self.looped:
            first, last = self.keyframes[0], self.keyframes[-1]
            if {pose.joint for pose in first.poses} != {pose.joint for pose in last.poses}:
                # A looped animation whose first and last keyframes pose
                # different joints snaps visibly at the loop point, which reads
                # as a bug in the game rather than in the asset.
                raise AnimationAuthoringError(
                    "a looped animation must pose the same joints in its first and last "
                    "keyframes, or it will snap at the loop point"
                )

    @property
    def duration(self) -> float:
        return self.keyframes[-1].time

    @property
    def joints(self) -> tuple[str, ...]:
        names: set[str] = set()
        for frame in self.keyframes:
            names.update(pose.joint for pose in frame.poses)
        return tuple(sorted(names))

    def to_rbxmx(self) -> str:
        return _serialise(self)

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.to_rbxmx().encode("utf-8")).hexdigest()

    def write(self, path: Path) -> Path:
        path = Path(path)
        if path.suffix.lower() != ".rbxmx":
            raise AnimationAuthoringError(
                "the Open Cloud Assets API takes animations as .rbxm or .rbxmx; "
                f"{path.suffix or 'no extension'} would be rejected"
            )
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(self.to_rbxmx(), encoding="utf-8")
        return path

    def provenance(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "generator": self.generator,
            "animationId": self.id,
            "durationSeconds": round(self.duration, 4),
            "keyframes": len(self.keyframes),
            "joints": list(self.joints),
            "looped": self.looped,
            "priority": self.priority,
            "sha256": self.sha256,
            "placeholder": False,
            # Stated on every receipt, because it is the one thing about this
            # pipeline that cannot be established locally.
            "uploadCaveat": (
                "Roblox processes animations on import from Studio; an externally "
                "authored .rbxmx is a candidate for upload and the API result is the "
                "only thing that settles it"
            ),
        }


# ---------------------------------------------------------------- serialising


def _cframe(pose: Pose) -> str:
    """Euler degrees to a Roblox CFrame's twelve components.

    Roblox stores a CFrame as position plus a row-major rotation matrix. Emitting
    Euler angles directly would be silently ignored by the loader.
    """

    x, y, z = (math.radians(value) for value in pose.rotation)
    cx, sx = math.cos(x), math.sin(x)
    cy, sy = math.cos(y), math.sin(y)
    cz, sz = math.cos(z), math.sin(z)

    # XYZ order, matching CFrame.Angles.
    r00 = cy * cz
    r01 = -cy * sz
    r02 = sy
    r10 = sx * sy * cz + cx * sz
    r11 = -sx * sy * sz + cx * cz
    r12 = -sx * cy
    r20 = -cx * sy * cz + sx * sz
    r21 = cx * sy * sz + sx * cz
    r22 = cx * cy

    px, py, pz = pose.offset
    rows = (
        ("X", px), ("Y", py), ("Z", pz),
        ("R00", r00), ("R01", r01), ("R02", r02),
        ("R10", r10), ("R11", r11), ("R12", r12),
        ("R20", r20), ("R21", r21), ("R22", r22),
    )
    return "".join(f"<{name}>{value:.6f}</{name}>" for name, value in rows)


def _pose_xml(pose: Pose, indent: str) -> str:
    return (
        f'{indent}<Item class="Pose" referent="RBX{abs(hash((pose.joint, pose.rotation))) % 10**12}">\n'
        f"{indent}  <Properties>\n"
        f'{indent}    <string name="Name">{escape(pose.joint)}</string>\n'
        f'{indent}    <CoordinateFrame name="CFrame">{_cframe(pose)}</CoordinateFrame>\n'
        f'{indent}    <float name="Weight">1</float>\n'
        f'{indent}    <token name="EasingDirection">0</token>\n'
        f'{indent}    <token name="EasingStyle">0</token>\n'
        f"{indent}  </Properties>\n"
        f"{indent}</Item>\n"
    )


def _serialise(animation: Animation) -> str:
    """Write the KeyframeSequence as Roblox XML.

    Poses nest by the rig hierarchy rather than sitting flat: a Pose applies to
    the joint between itself and its parent, so a flat list moves the wrong
    limbs.
    """

    parts: list[str] = [
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="4">\n',
        '  <Item class="KeyframeSequence" referent="RBXSEQ">\n',
        "    <Properties>\n",
        f'      <string name="Name">{escape(animation.id)}</string>\n',
        f'      <bool name="Loop">{"true" if animation.looped else "false"}</bool>\n',
        f'      <string name="Priority">{escape(animation.priority)}</string>\n',
        "    </Properties>\n",
    ]

    for index, frame in enumerate(animation.keyframes):
        parts.append(f'    <Item class="Keyframe" referent="RBXKF{index}">\n')
        parts.append("      <Properties>\n")
        parts.append(f'        <string name="Name">Keyframe{index}</string>\n')
        parts.append(f'        <float name="Time">{frame.time:.6f}</float>\n')
        parts.append("      </Properties>\n")

        # Every keyframe roots at HumanoidRootPart, and each posed joint hangs
        # off its real parent so the loader applies it to the right Motor6D.
        parts.append('      <Item class="Pose" referent="RBXROOT{}">\n'.format(index))
        parts.append("        <Properties>\n")
        parts.append('          <string name="Name">HumanoidRootPart</string>\n')
        parts.append(
            '          <CoordinateFrame name="CFrame">'
            + _cframe(Pose("LowerTorso"))
            + "</CoordinateFrame>\n"
        )
        parts.append('          <float name="Weight">1</float>\n')
        parts.append("        </Properties>\n")

        posed = {pose.joint: pose for pose in frame.poses}
        emitted: set[str] = set()

        def emit(joint: str, indent: str) -> str:
            if joint in emitted:
                return ""
            emitted.add(joint)
            pose = posed.get(joint) or Pose(joint)
            body = _pose_xml(pose, indent)
            children = [
                name for name, parent in R15_PARENTS.items()
                if parent == joint and name in posed
            ]
            if not children:
                return body
            # Re-open the item to nest children inside it.
            opening, closing = body.rsplit(f"{indent}</Item>\n", 1)
            nested = "".join(emit(child, indent + "  ") for child in sorted(children))
            return opening + nested + f"{indent}</Item>\n" + closing

        for joint in sorted(posed):
            if R15_PARENTS.get(joint) == "HumanoidRootPart" or R15_PARENTS.get(joint) not in posed:
                parts.append(emit(joint, "          "))

        parts.append("      </Item>\n")
        parts.append("    </Item>\n")

    parts.append("  </Item>\n")
    parts.append("</roblox>\n")
    return "".join(parts)


# ------------------------------------------------------------------ generators


def idle_breath(*, joint: str = "UpperTorso", amplitude: float = 2.5, period: float = 3.0) -> Animation:
    """A looping idle: the smallest motion that stops a character reading as dead."""

    frames = []
    for index in range(5):
        position = index / 4
        angle = math.sin(position * 2 * math.pi) * amplitude
        frames.append(Keyframe(
            time=round(position * period, 4),
            poses=(Pose(joint, rotation=(angle, 0.0, 0.0)),),
        ))
    return Animation(
        id="idle_breath", keyframes=tuple(frames), looped=True,
        priority="Idle", generator="idle_breath",
    )


def wave(*, arm: str = "Right", period: float = 1.2) -> Animation:
    """A greeting wave, for onboarding and NPC acknowledgement."""

    upper, lower = f"{arm}UpperArm", f"{arm}LowerArm"
    sign = 1.0 if arm == "Right" else -1.0
    frames = []
    for index in range(5):
        position = index / 4
        swing = math.sin(position * 2 * math.pi) * 25.0
        frames.append(Keyframe(
            time=round(position * period, 4),
            poses=(
                Pose(upper, rotation=(0.0, 0.0, sign * -110.0)),
                Pose(lower, rotation=(0.0, 0.0, sign * (-20.0 + swing))),
            ),
        ))
    return Animation(
        id="wave", keyframes=tuple(frames), looped=True,
        priority="Action", generator=f"wave:{arm}",
    )


GENERATORS = {"idle_breath": idle_breath, "wave": wave}
