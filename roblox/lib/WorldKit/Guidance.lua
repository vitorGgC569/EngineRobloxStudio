--!strict
-- Semantic targeting for the next player action.
--
-- A prompt answers "what happens if I am already here?". Guidance answers the
-- earlier question: "where should I go?" It binds a stable semantic id to the
-- target, adds a restrained outline and proximity label, and exposes a probe
-- that distinguishes inactive from not observable.
--
-- Nothing in this module names a pad, tower or genre. A purchase site, quest
-- giver, extraction gate and crafting bench are the same affordance here.

local Guidance = {}

export type Spec = {
	id: string,
	action: string,
	role: string?,
	outlineRole: string?,
	maxDistance: number?,
	throughWalls: boolean?,
}

export type Handle = {
	id: string,
	target: Instance,
	cue: Folder,
	revision: number,
}

export type Probe = {
	id: string,
	status: string,
	observable: boolean,
	active: boolean,
	targets: number,
	cues: number,
	revision: number?,
}

local CUE_NAME = "WorldKitGuidance"

local function fail(message: string): never
	error("[Guidance] " .. message, 3)
end

local function hostPart(target: Instance): BasePart?
	if target:IsA("BasePart") then
		return target :: BasePart
	end
	if target:IsA("Model") and (target :: Model).PrimaryPart ~= nil then
		return (target :: Model).PrimaryPart
	end
	for _, child in ipairs(target:GetDescendants()) do
		if child:IsA("BasePart") then
			return child :: BasePart
		end
	end
	return nil
end

local function candidates(root: Instance): { Instance }
	local result = { root }
	for _, descendant in ipairs(root:GetDescendants()) do
		table.insert(result, descendant)
	end
	return result
end

function Guidance.validate(target: Instance, spec: Spec): { string }
	local problems = {}
	if typeof(target) ~= "Instance" then
		table.insert(problems, "target must be an Instance")
		return problems
	end
	if type(spec.id) ~= "string" or spec.id == "" then
		table.insert(problems, "guidance needs a stable semantic id")
	end
	if type(spec.action) ~= "string" or spec.action == "" then
		table.insert(problems, "guidance needs a player-facing action")
	end
	if spec.maxDistance ~= nil and (type(spec.maxDistance) ~= "number" or spec.maxDistance <= 0) then
		table.insert(problems, "maxDistance must be positive when present")
	end
	if hostPart(target) == nil then
		table.insert(problems, "target needs a BasePart for a spatial cue")
	end
	return problems
end

--- Focus a semantic target, replacing any older cue on the same instance.
function Guidance.focus(tokens: any, target: Instance, spec: Spec): Handle
	local problems = Guidance.validate(target, spec)
	if #problems > 0 then
		fail("target does not validate: " .. table.concat(problems, "; "))
	end
	local part = hostPart(target) :: BasePart
	local old = target:FindFirstChild(CUE_NAME)
	if old ~= nil then
		old:Destroy()
	end

	local revision = (tonumber(target:GetAttribute("RQEGuidanceRevision")) or 0) + 1
	local role = spec.role or "accentGold"
	local outlineRole = spec.outlineRole or role

	local cue = Instance.new("Folder")
	cue.Name = CUE_NAME
	cue:SetAttribute("RQEGuidanceCue", true)
	cue:SetAttribute("RQEGuidanceId", spec.id)
	cue:SetAttribute("RQEGuidanceAction", spec.action)
	cue:SetAttribute("RQEGuidanceRevision", revision)
	cue.Parent = target

	local highlight = Instance.new("Highlight")
	 highlight.Name = "TargetOutline"
	 highlight.Adornee = target
	 highlight.FillColor = tokens:color(role)
	 highlight.OutlineColor = tokens:color(outlineRole)
	 highlight.FillTransparency = 0.84
	 highlight.OutlineTransparency = 0
	 highlight.DepthMode = if spec.throughWalls == true
		then Enum.HighlightDepthMode.AlwaysOnTop
		else Enum.HighlightDepthMode.Occluded
	 highlight.Parent = cue

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ActionLabel"
	billboard.Adornee = part
	billboard.Size = UDim2.fromOffset(220, 42)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, math.max(part.Size.Y * 0.65, 3), 0)
	billboard.AlwaysOnTop = false
	-- Labels exist only while the player is close enough to act. The shared
	-- token is the same distance the visual judge uses, so the builder and the
	-- judge cannot disagree about when world text becomes clutter.
	billboard.MaxDistance = spec.maxDistance or tokens:legibility("labelReadDistance")
	billboard.Parent = cue

	local label = Instance.new("TextLabel")
	label.Name = "Action"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.2
	label.BackgroundColor3 = tokens:color("ink")
	label.TextColor3 = tokens:color("neutralLight")
	label.TextStrokeTransparency = 0.55
	label.FontFace = Font.new(
		"rbxasset://fonts/families/" .. tokens.raw.typography.family .. ".json",
		tokens:weight("bold")
	)
	label.TextSize = tokens:text("body")
	label.Text = spec.action
	label.Parent = billboard

	target:SetAttribute("RQEGuidanceId", spec.id)
	target:SetAttribute("RQEGuidanceAction", spec.action)
	target:SetAttribute("RQEGuidanceRevision", revision)
	target:SetAttribute("RQEGuidanceActive", true)

	return { id = spec.id, target = target, cue = cue, revision = revision }
end

--- Remove a cue while preserving its semantic marker for an honest probe.
---
--- A missing marker means the instrument cannot observe this target. A marker
--- with `active=false` means it observed the target and the requested effect is
--- absent. Those are intentionally different verdicts.
function Guidance.clear(target: Instance, expectedId: string?): boolean
	local id = target:GetAttribute("RQEGuidanceId")
	if type(id) ~= "string" or id == "" then
		return false
	end
	if expectedId ~= nil and id ~= expectedId then
		return false
	end
	local cue = target:FindFirstChild(CUE_NAME)
	if cue ~= nil then
		cue:Destroy()
	end
	target:SetAttribute("RQEGuidanceActive", false)
	local revision = (tonumber(target:GetAttribute("RQEGuidanceRevision")) or 0) + 1
	target:SetAttribute("RQEGuidanceRevision", revision)
	return true
end

--- Observe one target by semantic id, never by mutable instance name.
function Guidance.probe(root: Instance, id: string): Probe
	if type(id) ~= "string" or id == "" then
		fail("probe needs a non-empty semantic id")
	end
	local targets = 0
	local cues = 0
	local active = 0
	local revision: number? = nil
	for _, candidate in ipairs(candidates(root)) do
		if candidate:GetAttribute("RQEGuidanceId") == id
			and candidate:GetAttribute("RQEGuidanceCue") ~= true then
			targets += 1
			revision = math.max(revision or 0,
				tonumber(candidate:GetAttribute("RQEGuidanceRevision")) or 0)
			local cue = candidate:FindFirstChild(CUE_NAME)
			if cue ~= nil and cue:GetAttribute("RQEGuidanceId") == id then
				cues += 1
				if candidate:GetAttribute("RQEGuidanceActive") == true then
					active += 1
				end
			end
		end
	end

	if targets == 0 then
		return {
			id = id, status = "NOT_OBSERVABLE", observable = false,
			active = false, targets = 0, cues = 0, revision = nil,
		}
	end
	if targets > 1 then
		return {
			id = id, status = "AMBIGUOUS", observable = true,
			active = false, targets = targets, cues = cues, revision = revision,
		}
	end
	return {
		id = id,
		status = if active == 1 and cues == 1 then "ACTIVE" else "INACTIVE",
		observable = true,
		active = active == 1 and cues == 1,
		targets = targets,
		cues = cues,
		revision = revision,
	}
end

return Guidance
