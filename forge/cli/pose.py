"""Pose a rig from a clip and report what the pose actually is.

The loop this replaces
----------------------

Getting one archery pose right cost, per attempt: edit the clip, run the
doctor, build the place, restart Studio, start Play Solo, wait for terrain,
and then ask a person to look and describe what they saw. Minutes, and the
answer arrived as prose — "he holds the bow with one hand" — which had to be
translated back into shoulder angles by guessing.

This runs in edit mode against the already-open place. No build, no play, no
terrain. It applies the clip to a rig, samples it, and reports two things:

  * the joint angles at each sample, which is what the clip says;
  * the world distance between the hands, the feet and the head, which is what
    the pose *is*.

That second part matters more than it sounds. "Are both hands on the bow?" is
not answerable from a table of shoulder angles, but it is exactly answerable
from the distance between the two hands — and that is a number an agent can
check without anyone looking at a screen.

The rig is left standing in the viewport with the camera on it, so a person
can also just look, which is still the fastest way to catch things no metric
was written for.

    forge pose bow_draw
    forge pose attack_3 --samples 8
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]


class BridgeError(RuntimeError):
    pass


def bridge_exec(source: str, timeout: int = 180) -> Any:
    proc = subprocess.run(
        [sys.executable, str(REPO / "rqe.py"), "studio", "call", "bridge.exec",
         "--allow-arbitrary", "--params", json.dumps({"source": source}), "--timeout", str(timeout)],
        capture_output=True, text=True, timeout=timeout + 30, cwd=str(REPO),
    )
    raw = proc.stdout.strip() or proc.stderr.strip()
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BridgeError(f"bridge did not return JSON: {exc}\n{raw[:300]}")
    if not envelope.get("ok"):
        raise BridgeError(json.dumps(envelope.get("error"))[:300])
    return envelope.get("result", {}).get("returned")


_POSE_LUAU = """
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local forgeFolder = ReplicatedStorage:FindFirstChild("Forge")
if not forgeFolder then
	return { error = "no Forge in ReplicatedStorage; open a built place" }
end

local Forge = require(forgeFolder)
local Anim = Forge.Anim
local Rig = Forge.Rig

Anim.registerAll(require(forgeFolder.Anim.Presets))

-- Reuse the stage across runs so the camera stays where it was put and the
-- viewport does not jump on every sample.
local stage = Workspace:FindFirstChild("ForgePoseStage")
if stage then
	stage:Destroy()
end
stage = Instance.new("Folder")
stage.Name = "ForgePoseStage"
stage.Parent = Workspace

local rig = Rig.build({
	name = "PoseSubject",
	rigType = %(rigType)s,
	scale = %(scale)s,
	shape = "biped",
	body = Color3.fromRGB(150, 152, 160),
	accent = Color3.fromRGB(96, 98, 108),
	eyes = Color3.fromRGB(140, 200, 255),
})
rig.Parent = stage
rig:PivotTo(CFrame.new(%(x)s, %(y)s, %(z)s))

--[[
	Anchor the root only.

	The first version anchored every part so the rig would not fall over, and
	every sample then reported identical hand positions — because a Motor6D
	cannot move an anchored part. The measurements were real readings of a
	frozen rig. Anchoring the root holds the rig in the air and leaves the
	joints free to pose everything hanging off it.
]]
local root = rig:FindFirstChild("HumanoidRootPart") :: BasePart?
if root then
	root.Anchored = true
end

local animator = Anim.new(rig)
animator:setLocomotion(false)

local clipName = %(clip)s
local ok = pcall(function()
	animator:play(clipName, { blendIn = 0 })
end)
if not ok then
	return { error = "no clip named " .. clipName }
end

local shape = animator:describe()
local samples = {}
local steps = %(samples)d
local duration = %(duration)s

--[[
	Stepped by hand rather than by a heartbeat.

	Edit mode has no reliable frame loop to hang an animator on, and even if it
	did, sampling "whenever a frame happened" gives inconsistent times. Driving
	`update` directly makes each sample land exactly where it was asked for.
]]
--[[
	Where the *hand* is, not where the limb's centre is.

	Measuring part centres made `handsApart` almost constant: both arms swing
	forward together, so the distance between two shoulder-width boxes barely
	moves however the pose changes. The question worth answering — "are both
	hands on the bow?" — is about the far end of the limb, so that is what
	gets measured. On R15 the hand is its own part and is used directly.
]]
local function limbEnd(name)
	local part = rig:FindFirstChild(name) :: BasePart?
	if not part then
		return nil
	end
	if name:find("Hand") or name == "Head" then
		return part.Position
	end
	return (part.CFrame * CFrame.new(0, -part.Size.Y / 2, 0)).Position
end

local function partPosition(name)
	return limbEnd(name)
end

local dt = duration / steps
for i = 1, steps do
	animator:update(dt)

	local angles = {}
	for key, joint in pairs(animator.joints) do
		local applied = animator.applied[key]
		if applied and (math.abs(applied.swing) > 0.5 or math.abs(applied.spread) > 0.5
			or math.abs(applied.twist) > 0.5) then
			angles[key] = {
				math.floor(applied.swing * 10) / 10,
				math.floor(applied.spread * 10) / 10,
				math.floor(applied.twist * 10) / 10,
			}
		end
	end

	local rightHand = partPosition("Right Arm") or partPosition("RightHand")
	local leftHand = partPosition("Left Arm") or partPosition("LeftHand")
	local head = partPosition("Head")

	local measures = {}
	if rightHand and leftHand then
		measures.handsApart = math.floor((rightHand - leftHand).Magnitude * 10) / 10
	end
	if rightHand and head then
		measures.rightHandToHead = math.floor((rightHand - head).Magnitude * 10) / 10
	end
	if leftHand and head then
		measures.leftHandToHead = math.floor((leftHand - head).Magnitude * 10) / 10
	end

	table.insert(samples, {
		t = math.floor((i * dt) * 100) / 100,
		angles = angles,
		measures = measures,
	})
end

-- Frame it, so a person can simply look at Studio.
local camera = Workspace.CurrentCamera
if camera then
	local pivot = rig:GetPivot().Position
	camera.CFrame = CFrame.lookAt(pivot + Vector3.new(9, 3.5, 9), pivot + Vector3.new(0, 1, 0))
end

return {
	clip = clipName,
	rig = shape.rig,
	joints = shape.joints,
	jointKinds = shape.jointKinds,
	samples = samples,
}
"""


def preview(clip: str, samples: int = 6, duration: float = 1.0,
            scale: float = 1.0, rig_type: str = "R15",
            at: tuple[float, float, float] = (0, 20, 0)) -> dict:
    """Pose a clip and report it.

    R15 by default, because that is what a player actually is and it is the
    only rig with the elbows and knees the joint map grew. Pass "R6" to see
    what an enemy built by `Rig.build` will do with the same clip — they are
    genuinely different, and a clip that reads well on one can be limp on the
    other.
    """
    source = _POSE_LUAU % {
        "clip": json.dumps(clip),
        "samples": samples,
        "duration": duration,
        "scale": scale,
        "rigType": json.dumps(rig_type),
        "x": at[0], "y": at[1], "z": at[2],
    }
    return bridge_exec(source) or {}


def render(report: dict) -> str:
    """A readable dump, because the point is to be looked at."""
    if report.get("error"):
        return f"pose: {report['error']}"

    lines = [
        f"clip {report['clip']}  rig {report.get('rig')}  "
        f"joints {len(report.get('joints') or [])}",
    ]
    for sample in report.get("samples", []):
        angles = sample.get("angles") or {}
        measured = sample.get("measures") or {}
        lines.append(f"\n  t={sample['t']:<5}  " + "  ".join(
            f"{k}={v}" for k, v in sorted(measured.items())))
        for joint, triple in sorted(angles.items()):
            lines.append(f"      {joint:<14} swing={triple[0]:>7}  "
                         f"spread={triple[1]:>7}  twist={triple[2]:>7}")
    return "\n".join(lines)
