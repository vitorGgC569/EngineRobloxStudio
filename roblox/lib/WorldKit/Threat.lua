--!strict
-- Procedural humanoid threats that need no uploaded asset.
--
-- This is the visual half of an enemy, deliberately separate from pathfinding,
-- damage and rewards.  A tower defence, survival game or quest can supply its
-- own authoritative behaviour while sharing one readable silhouette.
--
-- The important invariant is that the figure is one Model with a PrimaryPart.
-- Callers move it with `Threat.pivot`, which delegates to `Model:PivotTo`; no
-- head, limb or health bar can be left behind by a body-only CFrame update.

local Tokens = require(script.Parent.Tokens)

local Threat = {}

export type Spec = {
	--- Stable semantic identity. Instance names are presentation, not identity.
	id: string,
	cframe: CFrame,
	displayName: string?,
	scale: number?,
	seed: number?,
	bodyRole: string?,
	mantleRole: string?,
	faceRole: string?,
	accentRole: string?,
	showName: boolean?,
	showHealth: boolean?,
	health: number?,
	maxHealth: number?,
	canCollide: boolean?,
}

local function fail(message: string): never
	error("[WorldKit.Threat] " .. message, 3)
end

local function validateRole(tokens: Tokens.TokenSet, problems: { string },
	role: string?, field: string): ()
	if role ~= nil and (type(role) ~= "string" or role == "" or not tokens:hasRole(role)) then
		table.insert(problems, field .. " must name a palette role in the token set")
	end
end

--- Validate before allocating any Instances, so a bad enemy never leaves a
--- half-built figure in the world.
function Threat.validate(tokens: Tokens.TokenSet, spec: Spec): { string }
	local problems = {}
	if type(spec) ~= "table" then
		table.insert(problems, "spec must be a table")
		return problems
	end
	if type(spec.id) ~= "string" or spec.id == "" then
		table.insert(problems, "id must be a non-empty semantic identity")
	end
	if typeof(spec.cframe) ~= "CFrame" then
		table.insert(problems, "cframe must be a CFrame at the figure centre")
	end
	if spec.displayName ~= nil
		and (type(spec.displayName) ~= "string" or spec.displayName == "") then
		table.insert(problems, "displayName must be non-empty when present")
	end
	if spec.scale ~= nil and (type(spec.scale) ~= "number" or spec.scale <= 0) then
		table.insert(problems, "scale must be positive when present")
	end
	if spec.seed ~= nil and (type(spec.seed) ~= "number" or spec.seed % 1 ~= 0) then
		table.insert(problems, "seed must be an integer when present")
	end
	local maximum = spec.maxHealth or 100
	local health = if spec.health == nil then maximum else spec.health
	if type(maximum) ~= "number" or maximum <= 0 then
		table.insert(problems, "maxHealth must be positive")
	end
	if type(health) ~= "number" or health < 0 or health > maximum then
		table.insert(problems, "health must be between zero and maxHealth")
	end
	validateRole(tokens, problems, spec.bodyRole, "bodyRole")
	validateRole(tokens, problems, spec.mantleRole, "mantleRole")
	validateRole(tokens, problems, spec.faceRole, "faceRole")
	validateRole(tokens, problems, spec.accentRole, "accentRole")
	return problems
end

local function part(model: Model, tokens: Tokens.TokenSet, name: string,
	size: Vector3, cframe: CFrame, role: string, shape: Enum.PartType?): Part
	local swatch = tokens:swatch(role)
	local built = Instance.new("Part")
	built.Name = name
	built.Anchored = true
	built.CanCollide = false
	built.CanTouch = false
	built.CanQuery = true
	built.CastShadow = true
	built.Size = size
	built.CFrame = cframe
	built.Color = swatch.color
	built.Material = swatch.material
	built.TopSurface = Enum.SurfaceType.Smooth
	built.BottomSurface = Enum.SurfaceType.Smooth
	if shape ~= nil then
		built.Shape = shape
	end
	built:SetAttribute("WorldKitRole", role)
	built.Parent = model
	return built
end

local function statusGui(model: Model, tokens: Tokens.TokenSet, head: BasePart,
	spec: Spec, height: number, accentRole: string): ()
	if spec.showName ~= true and spec.showHealth ~= true then
		return
	end

	local gap = tokens:space("tight")
	local line = tokens:text("body")
	local barHeight = math.max(5, math.floor(gap / 2))
	local guiHeight = (if spec.showName == true then line + gap else 0)
		+ (if spec.showHealth == true then barHeight + gap else 0)

	local status = Instance.new("BillboardGui")
	status.Name = "Status"
	status.Adornee = head
	status.Size = UDim2.fromOffset(line * 10, guiHeight)
	status.StudsOffsetWorldSpace = Vector3.new(0, height * 0.68, 0)
	status.AlwaysOnTop = false
	status.LightInfluence = 0
	status.MaxDistance = math.min(
		tokens:legibility("signageReadDistance"),
		tokens:legibility("silhouetteReadDistance") * 0.25
	)
	status:SetAttribute("RQEThreatStatus", true)
	status.Parent = model

	local cursor = 0
	if spec.showName == true then
		local label = Instance.new("TextLabel")
		label.Name = "DisplayName"
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, 0, 0, line)
		label.Position = UDim2.fromOffset(0, cursor)
		label.Text = spec.displayName or "Threat"
		label.TextColor3 = tokens:color("neutralLight")
		label.TextStrokeColor3 = tokens:color("ink")
		label.TextStrokeTransparency = 0.45
		label.TextSize = line
		label.FontFace = Font.new(
			"rbxasset://fonts/families/" .. tokens.raw.typography.family .. ".json",
			tokens:weight("bold")
		)
		label.Parent = status
		cursor += line + gap
	end

	if spec.showHealth == true then
		local track = Instance.new("Frame")
		track.Name = "HealthTrack"
		track.BackgroundColor3 = tokens:color("ink")
		track.BorderSizePixel = 0
		track.Size = UDim2.new(1, 0, 0, barHeight)
		track.Position = UDim2.fromOffset(0, cursor)
		track.Parent = status

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.BackgroundColor3 = tokens:color(accentRole)
		fill.BorderSizePixel = 0
		fill.Size = UDim2.fromScale(1, 1)
		fill.Parent = track
	end
end

local function assertThreat(model: Model): ()
	if typeof(model) ~= "Instance" or not model:IsA("Model")
		or model:GetAttribute("RQEThreat") ~= true then
		fail("expected a Model built by WorldKit.Threat")
	end
end

--- Move the complete figure as one assembly.
function Threat.pivot(model: Model, cframe: CFrame): Model
	assertThreat(model)
	if model.PrimaryPart == nil then
		fail("threat has no PrimaryPart; coherent movement is impossible")
	end
	if typeof(cframe) ~= "CFrame" then
		fail("pivot needs a CFrame")
	end
	model:PivotTo(cframe)
	local position = cframe.Position
	model:SetAttribute("RQEThreatX", position.X)
	model:SetAttribute("RQEThreatY", position.Y)
	model:SetAttribute("RQEThreatZ", position.Z)
	model:SetAttribute("RQEThreatRevision",
		(tonumber(model:GetAttribute("RQEThreatRevision")) or 0) + 1)
	return model
end

--- Update the authoritative visual health surface. Values outside the range
--- clamp because damage can legitimately overrun the last hit point.
function Threat.setHealth(model: Model, current: number, maximum: number?): number
	assertThreat(model)
	if type(current) ~= "number" then
		fail("health must be a number")
	end
	local maxHealth = maximum or tonumber(model:GetAttribute("RQEThreatMaxHealth"))
	if maxHealth == nil or maxHealth <= 0 then
		fail("maxHealth must be positive")
	end
	local health = math.max(0, math.min(current, maxHealth))
	local fraction = health / maxHealth
	model:SetAttribute("RQEThreatHealth", health)
	model:SetAttribute("RQEThreatMaxHealth", maxHealth)
	model:SetAttribute("RQEThreatAlive", health > 0)
	model:SetAttribute("RQEThreatRevision",
		(tonumber(model:GetAttribute("RQEThreatRevision")) or 0) + 1)

	local status = model:FindFirstChild("Status")
	local track = if status ~= nil then status:FindFirstChild("HealthTrack") else nil
	local fill = if track ~= nil then track:FindFirstChild("Fill") else nil
	if fill ~= nil and fill:IsA("Frame") then
		(fill :: Frame).Size = UDim2.fromScale(fraction, 1)
	end
	return fraction
end

--- Build a faceless, hooded humanoid from token-coloured Parts.
---
--- `spec.cframe` is the centre pivot, not the feet. This matches the CFrame a
--- moving enemy owns and prevents callers from re-deriving a height offset.
function Threat.build(parent: Instance, tokens: Tokens.TokenSet, spec: Spec): Model
	if typeof(parent) ~= "Instance" then
		fail("parent must be an Instance")
	end
	local problems = Threat.validate(tokens, spec)
	if #problems > 0 then
		fail("spec does not validate: " .. table.concat(problems, "; "))
	end

	local scale = spec.scale or 1
	local height = tokens:character("height") * scale
	local width = tokens:character("width") * scale
	local bodyRole = spec.bodyRole or "ink"
	local mantleRole = spec.mantleRole or "structureSecondary"
	local faceRole = spec.faceRole or "neutralLight"
	local accentRole = spec.accentRole or "accentDanger"
	local random = Random.new(spec.seed or 1)

	local model = Instance.new("Model")
	model.Name = spec.displayName or "FacelessThreat"
	model:SetAttribute("RQEThreat", true)
	model:SetAttribute("RQEThreatId", spec.id)
	model:SetAttribute("RQEThreatStyle", "faceless")
	model:SetAttribute("RQEThreatTokenSet", tokens.id)
	model.Parent = parent

	-- Invisible centre pivot and optional single collider. Every visible piece is
	-- non-collidable, so the silhouette cannot snag a player or a nav agent.
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Anchored = true
	root.CanCollide = spec.canCollide == true
	root.CanTouch = spec.canCollide == true
	root.CanQuery = false
	root.CastShadow = false
	root.Transparency = 1
	root.Size = Vector3.new(width * 0.72, height * 0.9, width * 0.52)
	root.CFrame = CFrame.identity
	root.Parent = model
	model.PrimaryPart = root

	-- A broad lower mass, narrower torso and mantle produce the taper a single
	-- rectangular body lacks. The slightly asymmetric arms are deterministic.
	part(model, tokens, "Cloak", Vector3.new(width * 1.45, height * 0.54, width * 0.86),
		CFrame.new(0, -height * 0.19, 0), bodyRole, nil)
	part(model, tokens, "Torso", Vector3.new(width * 1.08, height * 0.4, width * 0.7),
		CFrame.new(0, height * 0.12, 0), bodyRole, nil)
	part(model, tokens, "Mantle", Vector3.new(width * 1.72, height * 0.1, width * 0.86),
		CFrame.new(0, height * 0.29, 0), mantleRole, nil)

	local leftLean = math.rad(random:NextNumber(5, 13))
	local rightLean = math.rad(random:NextNumber(5, 13))
	part(model, tokens, "LeftArm", Vector3.new(width * 0.3, height * 0.48, width * 0.3),
		CFrame.new(-width * 0.72, height * 0.04, 0) * CFrame.Angles(0, 0, leftLean),
		bodyRole, nil)
	part(model, tokens, "RightArm", Vector3.new(width * 0.3, height * 0.48, width * 0.3),
		CFrame.new(width * 0.72, height * 0.04, 0) * CFrame.Angles(0, 0, -rightLean),
		bodyRole, nil)

	local hood = part(model, tokens, "Hood",
		Vector3.new(height * 0.34, height * 0.36, height * 0.34),
		CFrame.new(0, height * 0.41, 0), mantleRole, Enum.PartType.Ball)
	local face = part(model, tokens, "Face",
		Vector3.new(height * 0.055, height * 0.21, height * 0.25),
		CFrame.new(0, height * 0.41, -height * 0.165)
			* CFrame.Angles(0, math.rad(90), 0),
		faceRole, Enum.PartType.Cylinder)
	face.CastShadow = false

	-- One small accent gives targeting feedback without turning the whole enemy
	-- into Neon. Its role is shared with the health bar.
	part(model, tokens, "Relic", Vector3.new(width * 0.22, width * 0.22, width * 0.22),
		CFrame.new(0, height * 0.19, -width * 0.39), accentRole, Enum.PartType.Ball)

	statusGui(model, tokens, hood, spec, height, accentRole)
	Threat.pivot(model, spec.cframe)
	Threat.setHealth(model, spec.health or spec.maxHealth or 100, spec.maxHealth or 100)
	model:SetAttribute("RQEThreatVisualParts", 8)
	return model
end

return Threat
