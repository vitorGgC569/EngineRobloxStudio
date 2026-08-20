"""The one-time human checklist, made verifiable.

Four things stand between this engine and a real `rbxassetid://`, and none of
them can be done from code:

  1. the account or group must be 13+ and **ID-verified**
  2. **"Allow Mesh / Image APIs"** must be on in Game Settings -> Security
  3. the **"CreateAssetAsync Luau API"** beta must be enabled in Studio
  4. an **Open Cloud API key** with the right scopes must exist

A document listing those is worth very little -- somebody reads it, believes
they did it, and the pipeline fails three steps later with a permissions error
nobody can attribute. The useful form is a preflight that asks the running
system and reports which gates are actually open, with the specific remedy for
each one that is not.

Every item here is either **verified** (something reported it), **blocked**
(something reported it missing, with the fix named) or **unknown** (nothing
could report on it). Unknown is never treated as satisfied.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Mapping


class GateStatus(str, Enum):
    VERIFIED = "VERIFIED"
    BLOCKED = "BLOCKED"
    UNKNOWN = "UNKNOWN"


@dataclass(frozen=True)
class Gate:
    id: str
    title: str
    status: GateStatus
    #: Where the answer came from, so a VERIFIED nobody measured is impossible.
    evidence: str = ""
    #: What a human does about it. Empty only when nothing is wrong.
    remedy: str = ""
    human_only: bool = True

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "status": self.status.value,
            "evidence": self.evidence,
            "remedy": self.remedy,
            "humanOnly": self.human_only,
        }


@dataclass
class PreflightReport:
    gates: list[Gate] = field(default_factory=list)

    @property
    def ready(self) -> bool:
        return all(gate.status is GateStatus.VERIFIED for gate in self.gates)

    @property
    def blocked(self) -> list[Gate]:
        return [gate for gate in self.gates if gate.status is GateStatus.BLOCKED]

    @property
    def unknown(self) -> list[Gate]:
        return [gate for gate in self.gates if gate.status is GateStatus.UNKNOWN]

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "ready": self.ready,
            "verified": sum(1 for gate in self.gates if gate.status is GateStatus.VERIFIED),
            "blocked": len(self.blocked),
            "unknown": len(self.unknown),
            "gates": [gate.to_dict() for gate in self.gates],
        }

    def summary(self) -> str:
        if self.ready:
            return "asset publishing is unblocked"
        lines = ["asset publishing is blocked:"]
        for gate in self.blocked + self.unknown:
            lines.append(f"  [{gate.status.value}] {gate.title}")
            if gate.remedy:
                lines.append(f"      -> {gate.remedy}")
        return "\n".join(lines)


#: Substrings Roblox uses when the corresponding gate is shut. Matched rather
#: than parsed because the plugin reports prose and the wording is Roblox's, not
#: ours; a match is a strong signal and a miss degrades to UNKNOWN, never to
#: VERIFIED.
_ID_VERIFICATION_HINTS = ("id-verified", "id verified", "13+")
_MESH_IMAGE_TOGGLE_HINTS = ("allow mesh", "mesh / image", "game settings")
_BETA_FLAG_HINTS = ("createassetasync luau api", "beta features")


def _matches(blockers: list[str], hints: tuple[str, ...]) -> str | None:
    for blocker in blockers:
        lowered = blocker.lower()
        if any(hint in lowered for hint in hints):
            return blocker
    return None


def evaluate(
    capabilities: Mapping[str, Any] | None,
    *,
    environment: Mapping[str, str] | None = None,
) -> PreflightReport:
    """Turn a plugin capability report and the environment into gate statuses.

    `capabilities` is the payload from the `assets.capabilities` bridge command.
    `None` means Studio could not be reached, which makes every Studio-side gate
    UNKNOWN rather than blocked -- an unreachable Studio is not evidence that a
    toggle is off.
    """

    env = dict(environment if environment is not None else os.environ)
    gates: list[Gate] = []

    if capabilities is None:
        for gate_id, title in (
            ("id-verification", "Account or group is 13+ and ID-verified"),
            ("mesh-image-toggle", "\"Allow Mesh / Image APIs\" enabled in Game Settings > Security"),
            ("create-asset-beta", "\"CreateAssetAsync Luau API\" beta enabled in Studio"),
        ):
            gates.append(Gate(
                id=gate_id,
                title=title,
                status=GateStatus.UNKNOWN,
                evidence="Studio could not be reached, so nothing reported on this gate",
                remedy="start Studio with the RQE plugin installed and run the preflight again",
            ))
    else:
        blockers = [str(item) for item in capabilities.get("blockers", [])]

        beta = _matches(blockers, _BETA_FLAG_HINTS)
        gates.append(Gate(
            id="create-asset-beta",
            title="\"CreateAssetAsync Luau API\" beta enabled in Studio",
            status=GateStatus.VERIFIED if capabilities.get("createAsset") else GateStatus.BLOCKED,
            evidence=beta or "AssetService:CreateAssetAsync is callable",
            remedy="" if capabilities.get("createAsset") else
                "Studio > File > Beta Features > enable \"CreateAssetAsync Luau API\", then restart Studio",
        ))

        editable = capabilities.get("editableImage")
        toggle_blocker = _matches(blockers, _MESH_IMAGE_TOGGLE_HINTS)
        gates.append(Gate(
            id="mesh-image-toggle",
            title="\"Allow Mesh / Image APIs\" enabled in Game Settings > Security",
            status=GateStatus.VERIFIED if editable else GateStatus.BLOCKED,
            evidence=toggle_blocker or "AssetService can create an EditableImage",
            remedy="" if editable else
                "Studio > File > Game Settings > Security > enable \"Allow Mesh / Image APIs\"",
        ))

        # ID verification has no direct probe. It is inferred from the same
        # blocker text, and stays UNKNOWN when the editable path works for some
        # other reason -- an inference is not a measurement.
        identity = _matches(blockers, _ID_VERIFICATION_HINTS)
        gates.append(Gate(
            id="id-verification",
            title="Account or group is 13+ and ID-verified",
            status=GateStatus.BLOCKED if identity else (
                GateStatus.VERIFIED if editable else GateStatus.UNKNOWN
            ),
            evidence=identity or (
                "EditableImage creation succeeded, which requires verification"
                if editable else "no probe reported on verification directly"
            ),
            remedy="" if editable and not identity else
                "verify the account at roblox.com > Settings > Account Info > Verification",
        ))

    key = env.get("ROBLOX_OPEN_CLOUD_KEY", "")
    gates.append(Gate(
        id="open-cloud-key",
        title="Open Cloud API key available in the environment",
        status=GateStatus.VERIFIED if key else GateStatus.BLOCKED,
        evidence="ROBLOX_OPEN_CLOUD_KEY is set" if key else "ROBLOX_OPEN_CLOUD_KEY is not set",
        remedy="" if key else (
            "create a key on the Creator Dashboard with asset:write and "
            "luau-execution-sessions:write, then export ROBLOX_OPEN_CLOUD_KEY"
        ),
        human_only=True,
    ))

    universe = env.get("ROBLOX_UNIVERSE_ID", "")
    place = env.get("ROBLOX_PLACE_ID", "")
    gates.append(Gate(
        id="cloud-target",
        title="Universe and place identified for cloud execution",
        status=GateStatus.VERIFIED if universe and place else GateStatus.BLOCKED,
        evidence=f"universe={universe or 'unset'} place={place or 'unset'}",
        remedy="" if universe and place else
            "export ROBLOX_UNIVERSE_ID and ROBLOX_PLACE_ID for the target experience",
        human_only=True,
    ))

    return PreflightReport(gates=gates)


#: The checklist as a document, for a human who wants to do all of it up front
#: rather than discover the items one refusal at a time.
CHECKLIST = """\
Asset publishing preflight -- one-time human setup

1. Verify the account (or the group that owns the experience)
   roblox.com > Settings > Account Info > Verification. Must be 13+ and ID-verified.

2. Enable the mesh and image APIs for the experience
   Studio > File > Game Settings > Security > "Allow Mesh / Image APIs".

3. Enable the asset creation beta in Studio
   Studio > File > Beta Features > "CreateAssetAsync Luau API". Restart Studio.

4. Create an Open Cloud API key
   create.roblox.com > Dashboard > Open Cloud > API Keys.
   Scopes: asset:write, luau-execution-sessions:write, universe-places:write.
   Export it as ROBLOX_OPEN_CLOUD_KEY, plus ROBLOX_UNIVERSE_ID and ROBLOX_PLACE_ID.

Then run:  python -m rqe.assets.preflight

Nothing after this point is human work. Everything before it is, and no
architecture removes that.
"""


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - CLI
    import argparse
    import json

    parser = argparse.ArgumentParser(description="Check whether asset publishing is unblocked.")
    parser.add_argument("--json", action="store_true", help="emit the report as JSON")
    parser.add_argument("--checklist", action="store_true", help="print the human checklist and exit")
    parser.add_argument("--hub", default=None, help="bridge hub URL, to ask a live Studio")
    arguments = parser.parse_args(argv)

    if arguments.checklist:
        print(CHECKLIST)
        return 0

    capabilities = None
    if arguments.hub:
        try:
            from ..hub.client import StudioBridge

            capabilities = StudioBridge(arguments.hub).call("assets.capabilities", {})
        except Exception as exc:  # noqa: BLE001 - any failure means "unknown"
            print(f"could not reach Studio: {exc}")

    report = evaluate(capabilities)
    if arguments.json:
        print(json.dumps(report.to_dict(), indent=2))
    else:
        print(report.summary())
    return 0 if report.ready else 1


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
