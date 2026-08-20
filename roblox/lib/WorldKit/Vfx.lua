--!strict
-- L5: visual effects.
--
-- Effects are where a world stops looking static, and where frame rate goes to
-- die. Both facts are handled the same way: every emitter here is created from a
-- token-driven preset and **counted against a budget**, because the failure mode
-- is never one effect -- it is forty, each individually reasonable.
--
-- Measured on this project: 49 point lights plus Neon material produced a yellow
-- wash that made the map unreadable, and 320 billboard labels at 400 studs
-- buried it entirely. Neither produced an error. A budget that reports its own
-- consumption is the only thing that turns that class of defect into something a
-- gate can see.
--
-- Colours come from palette roles, never from literals, so an effect re-themes
-- with the rest of the world instead of staying the colour of the game it was
-- written for.

local Semantics = require(script.Parent.Semantics)
local Tokens = require(script.Parent.Tokens)

local Vfx = {}

local OWNED = "WorldKitVfx"

export type Budget = {
	emitters: number,
	beams: number,
	trails: number,
	lights: number,
	highlights: number,
	maxEmitters: number,
	maxLights: number,
}

--- Ceilings, not suggestions. Chosen from what this project measured rather
--- than from taste: past roughly this many the frame cost is visible on a
--- mid-range phone, and the visual result is worse, not better.
local MAX_EMITTERS = 48
local MAX_LIGHTS = 12

local counts = { emitters = 0, beams = 0, trails = 0, lights = 0, highlights = 0 }

local function fail(message: string): never
	error("[WorldKit.Vfx] " .. message, 3)
end

local function adopt(instance: Instance, parent: Instance)
	instance:SetAttribute(OWNED, true)
	instance.Parent = parent
end

function Vfx.budget(): Budget
	return {
		emitters = counts.emitters,
		beams = counts.beams,
		trails = counts.trails,
		lights = counts.lights,
		highlights = counts.highlights,
		maxEmitters = MAX_EMITTERS,
		maxLights = MAX_LIGHTS,
	}
end

function Vfx.resetBudget()
	counts = { emitters = 0, beams = 0, trails = 0, lights = 0, highlights = 0 }
end

--- Two-stop gradient between palette roles, which is what almost every effect
--- actually wants and what nobody remembers to build by hand.
local function gradient(tokens: Tokens.TokenSet, fromRole: string, toRole: string): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, tokens:color(fromRole)),
		ColorSequenceKeypoint.new(1, tokens:color(toRole)),
	})
end

local function fade(startAlpha: number, endAlpha: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, startAlpha),
		NumberSequenceKeypoint.new(1, endAlpha),
	})
end

-- ------------------------------------------------------------------ presets

export type EmitterSpec = {
	--- Palette roles, start and end of the colour ramp.
	fromRole: string,
	toRole: string?,
	rate: number,
	lifetime: NumberRange?,
	speed: NumberRange?,
	size: number?,
	spread: number?,
	--- Emit once and stop, rather than running forever.
	burst: number?,
	texture: string?,
}

--- A particle emitter parented to `host`.
---
--- Returns `nil` when the budget is spent rather than creating the emitter
--- anyway. A caller that ignores the nil gets no effect; a caller that checks it
--- learns the scene is over budget, which is the information that matters.
function Vfx.emitter(tokens: Tokens.TokenSet, host: BasePart, spec: EmitterSpec): ParticleEmitter?
	if typeof(host) ~= "Instance" or not host:IsA("BasePart") then
		fail("Vfx.emitter needs a BasePart host")
	end
	if type(spec.rate) ~= "number" or spec.rate < 0 then
		fail("emitter rate must be a non-negative number")
	end
	if counts.emitters >= MAX_EMITTERS then
		return nil
	end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Vfx"
	emitter.Color = gradient(tokens, spec.fromRole, spec.toRole or spec.fromRole)
	emitter.Rate = if spec.burst ~= nil then 0 else spec.rate
	emitter.Lifetime = spec.lifetime or NumberRange.new(0.6, 1.1)
	emitter.Speed = spec.speed or NumberRange.new(4, 8)
	emitter.SpreadAngle = Vector2.new(spec.spread or 12, spec.spread or 12)
	emitter.Size = NumberSequence.new(spec.size or 1)
	emitter.Transparency = fade(0.1, 1)
	emitter.LightEmission = 0.35
	-- Rotation and drag cost nothing and are the difference between particles
	-- that read as a puff and particles that read as identical sprites.
	emitter.RotSpeed = NumberRange.new(-45, 45)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.Drag = 1.5
	if spec.texture ~= nil then
		emitter.Texture = spec.texture
	end
	adopt(emitter, host)
	counts.emitters += 1

	if spec.burst ~= nil then
		emitter.Enabled = false
		emitter:Emit(spec.burst)
	end
	return emitter
end

--- A one-shot burst that cleans itself up.
---
--- The lifetime is derived from the emitter's own particle lifetime rather than
--- guessed, so a burst never disappears mid-flight and never lingers as a leaked
--- instance.
function Vfx.burst(tokens: Tokens.TokenSet, host: BasePart, spec: EmitterSpec, amount: number): ParticleEmitter?
	local emitter = Vfx.emitter(tokens, host, spec)
	if emitter == nil then
		return nil
	end
	emitter.Enabled = false
	emitter:Emit(amount)
	local lifetime = emitter.Lifetime.Max
	task.delay(lifetime + 0.25, function()
		if emitter.Parent ~= nil then
			emitter:Destroy()
			counts.emitters -= 1
		end
	end)
	return emitter
end

--- A beam between two attachments, for conveyor lines, tethers and lasers.
function Vfx.beam(tokens: Tokens.TokenSet, from: Attachment, to: Attachment, roleFrom: string, roleTo: string?, options: { [string]: any }?): Beam
	local opts = options or {}
	local beam = Instance.new("Beam")
	beam.Name = "VfxBeam"
	beam.Attachment0 = from
	beam.Attachment1 = to
	beam.Color = gradient(tokens, roleFrom, roleTo or roleFrom)
	beam.Width0 = opts.width0 or 0.6
	beam.Width1 = opts.width1 or 0.6
	beam.FaceCamera = true
	beam.LightEmission = opts.lightEmission or 0.4
	beam.Transparency = fade(opts.startTransparency or 0.15, opts.endTransparency or 0.15)
	if opts.texture ~= nil then
		beam.Texture = opts.texture
		beam.TextureSpeed = opts.textureSpeed or 1
		beam.TextureLength = opts.textureLength or 2
	end
	adopt(beam, from.Parent :: Instance)
	counts.beams += 1
	return beam
end

--- A trail behind a moving part.
function Vfx.trail(tokens: Tokens.TokenSet, host: BasePart, roleFrom: string, roleTo: string?, options: { [string]: any }?): Trail
	local opts = options or {}
	-- Two attachments spaced across the part, because a trail between two
	-- coincident attachments renders as nothing at all.
	local spread = opts.spread or math.max(host.Size.Y / 2, 0.5)
	local top = Instance.new("Attachment")
	top.Name = "VfxTrailTop"
	top.Position = Vector3.new(0, spread, 0)
	adopt(top, host)
	local bottom = Instance.new("Attachment")
	bottom.Name = "VfxTrailBottom"
	bottom.Position = Vector3.new(0, -spread, 0)
	adopt(bottom, host)

	local trail = Instance.new("Trail")
	trail.Name = "VfxTrail"
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Color = gradient(tokens, roleFrom, roleTo or roleFrom)
	trail.Lifetime = opts.lifetime or 0.45
	trail.Transparency = fade(opts.startTransparency or 0.2, 1)
	trail.LightEmission = opts.lightEmission or 0.3
	trail.MinLength = 0
	adopt(trail, host)
	counts.trails += 1
	return trail
end

--- An outline for something the player must notice.
---
--- Cheaper and far more legible than a light, which is why it is the default
--- answer to "make this stand out" in this SDK.
function Vfx.highlight(tokens: Tokens.TokenSet, target: Instance, roleFill: string, roleOutline: string?, options: { [string]: any }?): Highlight
	local opts = options or {}
	local highlight = Instance.new("Highlight")
	highlight.Name = "VfxHighlight"
	highlight.Adornee = target
	highlight.FillColor = tokens:color(roleFill)
	highlight.OutlineColor = tokens:color(roleOutline or roleFill)
	highlight.FillTransparency = opts.fillTransparency or 0.75
	highlight.OutlineTransparency = opts.outlineTransparency or 0
	highlight.DepthMode = if opts.throughWalls == true
		then Enum.HighlightDepthMode.AlwaysOnTop
		else Enum.HighlightDepthMode.Occluded
	adopt(highlight, target)
	counts.highlights += 1
	return highlight
end

--- A point light, budgeted hard.
---
--- Returns nil past the ceiling. Lights are the single easiest way to destroy a
--- scene on this platform and the hardest to notice while adding them one at a
--- time.
function Vfx.light(tokens: Tokens.TokenSet, host: BasePart, role: string, options: { [string]: any }?): PointLight?
	if counts.lights >= MAX_LIGHTS then
		return nil
	end
	local opts = options or {}
	local light = Instance.new("PointLight")
	light.Color = tokens:color(role)
	light.Brightness = opts.brightness or 1.2
	light.Range = opts.range or 18
	light.Shadows = opts.shadows ~= false
	adopt(light, host)
	counts.lights += 1
	return light
end

-- ------------------------------------------------------------------ presets

--- Named effects a game asks for by intent rather than by parameter.
---
--- The point of a preset library is that "a reward just landed" produces the
--- same feeling in every game built on this SDK, at the same speed, in the
--- palette of whichever world it is in.
Vfx.Presets = {
	reward = function(tokens: Tokens.TokenSet, host: BasePart): ParticleEmitter?
		return Vfx.burst(tokens, host, {
			fromRole = "accentGold",
			toRole = "accentSuccess",
			rate = 0,
			lifetime = NumberRange.new(0.5, 0.9),
			speed = NumberRange.new(9, 16),
			size = 1.1,
			spread = 180,
		}, 26)
	end,

	rarity = function(tokens: Tokens.TokenSet, host: BasePart): ParticleEmitter?
		return Vfx.emitter(tokens, host, {
			fromRole = "accentRare",
			toRole = "neutralLight",
			rate = 9,
			lifetime = NumberRange.new(0.8, 1.4),
			speed = NumberRange.new(1.5, 3),
			size = 0.7,
			spread = 30,
		})
	end,

	machine = function(tokens: Tokens.TokenSet, host: BasePart): ParticleEmitter?
		return Vfx.emitter(tokens, host, {
			fromRole = "neutralLight",
			toRole = "stonePrimary",
			rate = 3,
			lifetime = NumberRange.new(1.2, 2.0),
			speed = NumberRange.new(1, 2.5),
			size = 1.6,
			spread = 20,
		})
	end,

	denial = function(tokens: Tokens.TokenSet, host: BasePart): ParticleEmitter?
		return Vfx.burst(tokens, host, {
			fromRole = "accentDanger",
			rate = 0,
			lifetime = NumberRange.new(0.3, 0.5),
			speed = NumberRange.new(3, 6),
			size = 0.8,
			spread = 90,
		}, 12)
	end,
}

local FEEDBACK_EFFECTS: { [string]: { fromRole: string, toRole: string, amount: number } } = {
	success = { fromRole = "accentSuccess", toRole = "neutralLight", amount = 14 },
	error = { fromRole = "accentDanger", toRole = "neutralLight", amount = 10 },
	purchase = { fromRole = "accentGold", toRole = "accentSuccess", amount = 18 },
	reward = { fromRole = "accentGold", toRole = "neutralLight", amount = 22 },
	build = { fromRole = "accentGold", toRole = "neutralLight", amount = 16 },
	upgrade = { fromRole = "accentRare", toRole = "neutralLight", amount = 20 },
	unlock = { fromRole = "accentRare", toRole = "accentSuccess", amount = 24 },
	damage = { fromRole = "accentDanger", toRole = "neutralLight", amount = 12 },
	wave = { fromRole = "accentGold", toRole = "neutralLight", amount = 12 },
	victory = { fromRole = "accentSuccess", toRole = "accentGold", amount = 30 },
	defeat = { fromRole = "accentDanger", toRole = "stoneSecondary", amount = 18 },
}

function Vfx.feedbackEvents(): { string }
	local names = {}
	for name in pairs(FEEDBACK_EFFECTS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- A one-shot effect keyed by what happened, not by a game's genre.
---
--- When given a position it owns and cleans an invisible client-side anchor.
--- Callers never need to add a permanent Part just to show one purchase.
function Vfx.feedback(tokens: Tokens.TokenSet, event: string,
	at: BasePart | Vector3): ParticleEmitter?
	local definition = FEEDBACK_EFFECTS[event]
	if definition == nil then
		return nil
	end

	local host: BasePart
	local ownsHost = false
	if typeof(at) == "Vector3" then
		local anchor = Instance.new("Part")
		anchor.Name = "FeedbackAnchor_" .. event
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanTouch = false
		anchor.CanQuery = false
		anchor.Transparency = 1
		anchor.Size = Vector3.one
		anchor.Position = at :: Vector3
		anchor:SetAttribute(OWNED, true)
		anchor.Parent = workspace
		host = anchor
		ownsHost = true
	else
		host = at :: BasePart
	end

	local emitter = Vfx.burst(tokens, host, {
		fromRole = definition.fromRole,
		toRole = definition.toRole,
		rate = 0,
		lifetime = NumberRange.new(0.32, 0.72),
		speed = NumberRange.new(5, 11),
		size = 0.9,
		spread = if event == "victory" or event == "reward" then 180 else 90,
	}, definition.amount)
	if emitter == nil and ownsHost then
		host:Destroy()
	elseif ownsHost then
		task.delay(1.1, function()
			if host.Parent ~= nil then
				host:Destroy()
			end
		end)
	end
	return emitter
end

--- Remove everything this module created beneath a root.
function Vfx.clear(root: Instance): number
	local removed = 0
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:GetAttribute(OWNED) == true then
			descendant:Destroy()
			removed += 1
		end
	end
	Vfx.resetBudget()
	return removed
end

--- Effects present in a tree, whoever created them.
---
--- Counts everything, not just what this module owns, because a scene is slow
--- because of its total effect load and not because of the well-behaved half.
function Vfx.census(root: Instance): { [string]: number }
	local census = { emitters = 0, beams = 0, trails = 0, lights = 0, highlights = 0, neonParts = 0 }
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			census.emitters += 1
		elseif descendant:IsA("Beam") then
			census.beams += 1
		elseif descendant:IsA("Trail") then
			census.trails += 1
		elseif descendant:IsA("Light") then
			census.lights += 1
		elseif descendant:IsA("Highlight") then
			census.highlights += 1
		elseif descendant:IsA("BasePart") and descendant.Material == Enum.Material.Neon then
			census.neonParts += 1
		end
	end
	return census
end

--- Complaints about a scene's effect load, checked against the token policy.
function Vfx.problems(tokens: Tokens.TokenSet, root: Instance): { string }
	local census = Vfx.census(root)
	local problems: { string } = {}
	if census.lights > MAX_LIGHTS then
		table.insert(problems, string.format(
			"%d lights, above the budget of %d; measured on this project, this is what produced a yellow wash over the whole map",
			census.lights, MAX_LIGHTS
		))
	end
	if census.emitters > MAX_EMITTERS then
		table.insert(problems, string.format(
			"%d particle emitters, above the budget of %d", census.emitters, MAX_EMITTERS
		))
	end
	local forbidden = tokens.raw.palette.harmony.forbiddenMaterials or {}
	for _, material in ipairs(forbidden) do
		if material == "Neon" and census.neonParts > 0 then
			table.insert(problems, string.format(
				"%d parts use Neon, which this token set forbids", census.neonParts
			))
		end
	end
	return problems
end

return Vfx
