--!strict
--[[
	Visual — art direction as data.

	Why a generated Roblox game looks generated
	-------------------------------------------
	It is almost never the geometry. It is four things, and all four are
	defaults nobody changed:

	  1. Default Lighting. Flat white ambient, no atmosphere, fog off. Every
	     world lit identically, so every world reads identically.
	  2. Primary colours. `BrickColor.Random()` or hand-picked RGB per system,
	     so nothing shares a palette and everything fights.
	  3. No post. No bloom, no colour grading, no depth cue.
	  4. SmoothPlastic on everything, which reads as plastic because it is.

	A "look" here bundles all four into one named, tunable thing:

		Visual.defineLook("drowned_night", { ... })
		Visual.apply("drowned_night")
		Visual.transition("dawn", 6)

	And a palette makes procedural colour cohere instead of scatter:

		local palette = Visual.palette("shore")
		part.Color = palette:pick("stone", 0.4)

	Quality tiers
	-------------
	Half of Roblox is on a phone that cannot take three post-processing effects
	and shadow maps. `Visual.autoQuality()` reads the device and drops what
	costs most, in the order that costs the least to lose visually.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Core.Signal)
local Ease = require(script.Parent.Core.Ease)

local Visual = {}

Visual.lookChanged = Signal.new() -- (name)
Visual.qualityChanged = Signal.new() -- (tier)

local looks: { [string]: any } = {}
local palettes: { [string]: any } = {}
local currentLook: string? = nil
local quality = "high"
local effects: { [string]: Instance } = {}
local transitionConn: RBXScriptConnection? = nil

--[[
	What each tier is allowed to spend. Ordered by what hurts least to lose:
	sun rays first (decorative), then depth of field (subtle), then bloom
	(noticeable), then shadows (structural — last resort).
]]
Visual.tiers = {
	high = { bloom = true, colorCorrection = true, sunRays = true, depthOfField = true, shadows = true, atmosphere = true },
	medium = { bloom = true, colorCorrection = true, sunRays = false, depthOfField = false, shadows = true, atmosphere = true },
	low = { bloom = false, colorCorrection = true, sunRays = false, depthOfField = false, shadows = false, atmosphere = true },
	potato = { bloom = false, colorCorrection = false, sunRays = false, depthOfField = false, shadows = false, atmosphere = false },
}

-- ================================== looks ===================================
export type Look = {
	clockTime: number?,
	brightness: number?,
	ambient: Color3?,
	outdoorAmbient: Color3?,
	fogColor: Color3?,
	fogStart: number?,
	fogEnd: number?,
	exposure: number?,
	shadowSoftness: number?,
	environmentDiffuse: number?,
	environmentSpecular: number?,
	geographicLatitude: number?,

	atmosphere: { density: number?, offset: number?, haze: number?, glare: number?, color: Color3?, decay: Color3? }?,
	bloom: { intensity: number?, size: number?, threshold: number? }?,
	colorCorrection: { brightness: number?, contrast: number?, saturation: number?, tint: Color3? }?,
	sunRays: { intensity: number?, spread: number? }?,
	depthOfField: { farIntensity: number?, focusDistance: number?, inFocusRadius: number?, nearIntensity: number? }?,
}

function Visual.defineLook(name: string, look: Look)
	looks[name] = look
end

function Visual.defineLooks(table_: { [string]: Look })
	for name, look in table_ do
		Visual.defineLook(name, look)
	end
end

function Visual.lookNames(): { string }
	local out = {}
	for name in looks do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

--[[
	A small set of looks that already read as *chosen*. They exist so a new
	project never ships default Lighting, not so every project ships these —
	copy one and pull it apart.
]]
Visual.presets = {
	overcast_morning = {
		clockTime = 8.4, brightness = 2.2, exposure = 0.05,
		ambient = Color3.fromRGB(96, 100, 110),
		outdoorAmbient = Color3.fromRGB(138, 146, 158),
		fogColor = Color3.fromRGB(178, 188, 200), fogStart = 120, fogEnd = 900,
		shadowSoftness = 0.4, environmentDiffuse = 0.55, environmentSpecular = 0.35,
		atmosphere = { density = 0.38, haze = 2.1, glare = 0.1, color = Color3.fromRGB(196, 206, 218), decay = Color3.fromRGB(104, 112, 126) },
		bloom = { intensity = 0.4, size = 24, threshold = 1.2 },
		colorCorrection = { contrast = 0.06, saturation = -0.05, tint = Color3.fromRGB(246, 248, 255) },
		depthOfField = { farIntensity = 0.12, focusDistance = 60, inFocusRadius = 180, nearIntensity = 0 },
	},

	golden_hour = {
		clockTime = 17.4, brightness = 2.6, exposure = 0.18,
		ambient = Color3.fromRGB(102, 84, 74),
		outdoorAmbient = Color3.fromRGB(168, 128, 96),
		fogColor = Color3.fromRGB(206, 156, 112), fogStart = 90, fogEnd = 760,
		shadowSoftness = 0.28, environmentDiffuse = 0.5, environmentSpecular = 0.55,
		atmosphere = { density = 0.42, haze = 3.2, glare = 0.55, color = Color3.fromRGB(226, 186, 146), decay = Color3.fromRGB(126, 92, 74) },
		bloom = { intensity = 0.85, size = 30, threshold = 0.95 },
		colorCorrection = { contrast = 0.1, saturation = 0.12, tint = Color3.fromRGB(255, 238, 218) },
		sunRays = { intensity = 0.16, spread = 1 },
		depthOfField = { farIntensity = 0.2, focusDistance = 50, inFocusRadius = 140, nearIntensity = 0 },
	},

	drowned_night = {
		clockTime = 22.2, brightness = 0.8, exposure = -0.1,
		ambient = Color3.fromRGB(24, 30, 44),
		outdoorAmbient = Color3.fromRGB(40, 50, 72),
		fogColor = Color3.fromRGB(26, 34, 50), fogStart = 30, fogEnd = 260,
		shadowSoftness = 0.6, environmentDiffuse = 0.3, environmentSpecular = 0.2,
		atmosphere = { density = 0.54, haze = 3.4, glare = 0.4, color = Color3.fromRGB(118, 138, 170), decay = Color3.fromRGB(54, 66, 92) },
		bloom = { intensity = 1.1, size = 34, threshold = 0.75 },
		colorCorrection = { contrast = 0.14, saturation = -0.18, tint = Color3.fromRGB(206, 220, 255) },
		depthOfField = { farIntensity = 0.3, focusDistance = 30, inFocusRadius = 90, nearIntensity = 0.05 },
	},

	ashen_dusk = {
		clockTime = 19.1, brightness = 1.4, exposure = 0,
		ambient = Color3.fromRGB(56, 48, 52),
		outdoorAmbient = Color3.fromRGB(104, 88, 92),
		fogColor = Color3.fromRGB(112, 92, 92), fogStart = 60, fogEnd = 420,
		shadowSoftness = 0.5, environmentDiffuse = 0.42, environmentSpecular = 0.3,
		atmosphere = { density = 0.5, haze = 3.8, glare = 0.25, color = Color3.fromRGB(168, 142, 140), decay = Color3.fromRGB(78, 62, 64) },
		bloom = { intensity = 0.7, size = 28, threshold = 1 },
		colorCorrection = { contrast = 0.16, saturation = -0.24, tint = Color3.fromRGB(255, 236, 226) },
		depthOfField = { farIntensity = 0.26, focusDistance = 40, inFocusRadius = 110, nearIntensity = 0 },
	},

	clear_noon = {
		clockTime = 12.6, brightness = 3, exposure = 0.1,
		ambient = Color3.fromRGB(110, 112, 116),
		outdoorAmbient = Color3.fromRGB(158, 162, 168),
		fogColor = Color3.fromRGB(192, 206, 222), fogStart = 200, fogEnd = 1400,
		shadowSoftness = 0.2, environmentDiffuse = 0.5, environmentSpecular = 0.5,
		atmosphere = { density = 0.3, haze = 1.4, glare = 0.2, color = Color3.fromRGB(200, 214, 228), decay = Color3.fromRGB(108, 122, 140) },
		bloom = { intensity = 0.5, size = 24, threshold = 1.3 },
		colorCorrection = { contrast = 0.08, saturation = 0.06 },
		sunRays = { intensity = 0.1, spread = 0.9 },
	},
}

-- ================================= effects ==================================
local function effect(className: string, name: string): Instance
	local existing = effects[name]
	if existing and existing.Parent then
		return existing
	end
	local found = Lighting:FindFirstChild(name)
	if found then
		effects[name] = found
		return found
	end
	local created = Instance.new(className)
	created.Name = name
	created.Parent = Lighting
	effects[name] = created
	return created
end

local function allowed(feature: string): boolean
	local tier = Visual.tiers[quality] or Visual.tiers.high
	return tier[feature] == true
end

local function applyLook(look: Look)
	if look.clockTime then Lighting.ClockTime = look.clockTime end
	if look.brightness then Lighting.Brightness = look.brightness end
	if look.ambient then Lighting.Ambient = look.ambient end
	if look.outdoorAmbient then Lighting.OutdoorAmbient = look.outdoorAmbient end
	if look.fogColor then Lighting.FogColor = look.fogColor end
	if look.fogStart then Lighting.FogStart = look.fogStart end
	if look.fogEnd then Lighting.FogEnd = look.fogEnd end
	if look.exposure then Lighting.ExposureCompensation = look.exposure end
	if look.geographicLatitude then Lighting.GeographicLatitude = look.geographicLatitude end
	if look.environmentDiffuse then Lighting.EnvironmentDiffuseScale = look.environmentDiffuse end
	if look.environmentSpecular then Lighting.EnvironmentSpecularScale = look.environmentSpecular end

	Lighting.GlobalShadows = allowed("shadows")
	if look.shadowSoftness and allowed("shadows") then
		Lighting.ShadowSoftness = look.shadowSoftness
	end

	if look.atmosphere and allowed("atmosphere") then
		local atmosphere = effect("Atmosphere", "ForgeAtmosphere") :: Atmosphere
		local a = look.atmosphere
		atmosphere.Density = a.density or 0.35
		atmosphere.Offset = a.offset or 0.1
		atmosphere.Haze = a.haze or 2
		atmosphere.Glare = a.glare or 0.2
		atmosphere.Color = a.color or Color3.fromRGB(199, 205, 214)
		atmosphere.Decay = a.decay or Color3.fromRGB(106, 112, 125)
	elseif effects.ForgeAtmosphere then
		effects.ForgeAtmosphere:Destroy()
		effects.ForgeAtmosphere = nil
	end

	if look.bloom and allowed("bloom") then
		local bloom = effect("BloomEffect", "ForgeBloom") :: BloomEffect
		bloom.Intensity = look.bloom.intensity or 0.5
		bloom.Size = look.bloom.size or 24
		bloom.Threshold = look.bloom.threshold or 1.1
		bloom.Enabled = true
	elseif effects.ForgeBloom then
		(effects.ForgeBloom :: BloomEffect).Enabled = false
	end

	if look.colorCorrection and allowed("colorCorrection") then
		local grade = effect("ColorCorrectionEffect", "ForgeGrade") :: ColorCorrectionEffect
		grade.Brightness = look.colorCorrection.brightness or 0
		grade.Contrast = look.colorCorrection.contrast or 0
		grade.Saturation = look.colorCorrection.saturation or 0
		grade.TintColor = look.colorCorrection.tint or Color3.new(1, 1, 1)
		grade.Enabled = true
	elseif effects.ForgeGrade then
		(effects.ForgeGrade :: ColorCorrectionEffect).Enabled = false
	end

	if look.sunRays and allowed("sunRays") then
		local rays = effect("SunRaysEffect", "ForgeSunRays") :: SunRaysEffect
		rays.Intensity = look.sunRays.intensity or 0.12
		rays.Spread = look.sunRays.spread or 0.95
		rays.Enabled = true
	elseif effects.ForgeSunRays then
		(effects.ForgeSunRays :: SunRaysEffect).Enabled = false
	end

	if look.depthOfField and allowed("depthOfField") then
		local dof = effect("DepthOfFieldEffect", "ForgeDof") :: DepthOfFieldEffect
		dof.FarIntensity = look.depthOfField.farIntensity or 0.15
		dof.FocusDistance = look.depthOfField.focusDistance or 50
		dof.InFocusRadius = look.depthOfField.inFocusRadius or 150
		dof.NearIntensity = look.depthOfField.nearIntensity or 0
		dof.Enabled = true
	elseif effects.ForgeDof then
		(effects.ForgeDof :: DepthOfFieldEffect).Enabled = false
	end
end

function Visual.apply(name: string)
	local look = looks[name] or Visual.presets[name]
	if not look then
		warn(string.format("[Visual] no look named '%s'", name))
		return
	end
	if transitionConn then
		transitionConn:Disconnect()
		transitionConn = nil
	end
	applyLook(look)
	currentLook = name
	Visual.lookChanged:Fire(name)
end

--[[
	Blend from the current look to another over `seconds`.

	Not a Tween: half of a look is Atmosphere and post-effect properties across
	four different instances, and driving them from one interpolation keeps them
	in step. A dawn where the fog arrives before the ambient does looks broken
	in a way nobody can name.
]]
function Visual.transition(name: string, seconds: number?)
	local target = looks[name] or Visual.presets[name]
	if not target then
		warn(string.format("[Visual] no look named '%s'", name))
		return
	end
	local duration = seconds or 3

	local from = Visual.capture()
	local elapsed = 0
	if transitionConn then
		transitionConn:Disconnect()
	end

	local signal = RunService:IsClient() and RunService.RenderStepped or RunService.Heartbeat
	transitionConn = signal:Connect(function(dt)
		elapsed += dt
		local alpha = Ease.apply("smooth", math.min(elapsed / duration, 1))

		local blended: any = {}
		for key, value in target do
			local previous = from[key]
			if type(value) == "number" and type(previous) == "number" then
				blended[key] = previous + (value - previous) * alpha
			elseif typeof(value) == "Color3" and typeof(previous) == "Color3" then
				blended[key] = previous:Lerp(value, alpha)
			elseif type(value) == "table" then
				local sub: any = {}
				for subKey, subValue in value do
					local subPrevious = previous and previous[subKey]
					if type(subValue) == "number" and type(subPrevious) == "number" then
						sub[subKey] = subPrevious + (subValue - subPrevious) * alpha
					elseif typeof(subValue) == "Color3" and typeof(subPrevious) == "Color3" then
						sub[subKey] = subPrevious:Lerp(subValue, alpha)
					else
						sub[subKey] = subValue
					end
				end
				blended[key] = sub
			else
				blended[key] = value
			end
		end
		applyLook(blended)

		if alpha >= 1 then
			if transitionConn then
				transitionConn:Disconnect()
				transitionConn = nil
			end
			currentLook = name
			Visual.lookChanged:Fire(name)
		end
	end)
end

-- Snapshot the live Lighting state in Look shape, so a transition can start
-- from whatever is on screen rather than from a named look.
function Visual.capture(): Look
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	local bloom = Lighting:FindFirstChild("ForgeBloom") :: BloomEffect?
	local grade = Lighting:FindFirstChild("ForgeGrade") :: ColorCorrectionEffect?
	local dof = Lighting:FindFirstChild("ForgeDof") :: DepthOfFieldEffect?

	return {
		clockTime = Lighting.ClockTime,
		brightness = Lighting.Brightness,
		ambient = Lighting.Ambient,
		outdoorAmbient = Lighting.OutdoorAmbient,
		fogColor = Lighting.FogColor,
		fogStart = Lighting.FogStart,
		fogEnd = Lighting.FogEnd,
		exposure = Lighting.ExposureCompensation,
		environmentDiffuse = Lighting.EnvironmentDiffuseScale,
		environmentSpecular = Lighting.EnvironmentSpecularScale,
		atmosphere = atmosphere and {
			density = atmosphere.Density, haze = atmosphere.Haze, glare = atmosphere.Glare,
			offset = atmosphere.Offset, color = atmosphere.Color, decay = atmosphere.Decay,
		} or nil,
		bloom = bloom and { intensity = bloom.Intensity, size = bloom.Size, threshold = bloom.Threshold } or nil,
		colorCorrection = grade and {
			brightness = grade.Brightness, contrast = grade.Contrast,
			saturation = grade.Saturation, tint = grade.TintColor,
		} or nil,
		depthOfField = dof and {
			farIntensity = dof.FarIntensity, focusDistance = dof.FocusDistance,
			inFocusRadius = dof.InFocusRadius, nearIntensity = dof.NearIntensity,
		} or nil,
	}
end

-- ================================= quality ==================================
function Visual.setQuality(tier: string)
	if not Visual.tiers[tier] then
		return
	end
	quality = tier
	if currentLook then
		applyLook(looks[currentLook] or Visual.presets[currentLook])
	end
	Visual.qualityChanged:Fire(tier)
end

function Visual.quality(): string
	return quality
end

--[[
	Pick a tier from the device.

	Roblox exposes no reliable GPU signal, so this reads what it can: touch
	without a mouse is a phone, a small viewport is a phone, and everything else
	gets the benefit of the doubt. Wrong in the generous direction on a tablet,
	which is the cheap mistake; wrong in the stingy direction on a desktop would
	be the expensive one.
]]
function Visual.autoQuality(): string
	if not RunService:IsClient() then
		return quality
	end
	local camera = Workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)

	local tier = "high"
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		tier = viewport.X <= 900 and "low" or "medium"
	elseif viewport.X <= 1280 then
		tier = "medium"
	end
	Visual.setQuality(tier)
	return tier
end

-- ================================ palettes ==================================
--[[
	A palette is a set of named colour ramps.

	Procedural content picks colours constantly — a rock, a leaf, a wall — and
	picking each one independently is what makes a generated world look like
	confetti. Pulling from a ramp means everything in a world shares a family
	whether or not the system that placed it knows about the others.

		local p = Visual.palette("shore")
		part.Color = p:pick("stone", rng:number())
]]
local Palette = {}
Palette.__index = Palette

function Visual.definePalette(name: string, ramps: { [string]: { Color3 } })
	local palette = setmetatable({ name = name, ramps = ramps }, Palette)
	palettes[name] = palette
	return palette
end

function Visual.palette(name: string): any
	return palettes[name] or Visual.definePalette(name, Visual.defaultRamps)
end

-- Sample a ramp at 0..1, interpolating between stops.
function Palette:pick(ramp: string, alpha: number): Color3
	local stops = self.ramps[ramp]
	if not stops or #stops == 0 then
		return Color3.fromRGB(160, 160, 160)
	end
	if #stops == 1 then
		return stops[1]
	end
	local t = math.clamp(alpha, 0, 1) * (#stops - 1)
	local index = math.floor(t) + 1
	local nextIndex = math.min(index + 1, #stops)
	return stops[index]:Lerp(stops[nextIndex], t - math.floor(t))
end

-- Sample with a small hue/value jitter, so a hundred rocks are a family
-- rather than a hundred copies.
function Palette:vary(ramp: string, alpha: number, amount: number?): Color3
	local base = self:pick(ramp, alpha)
	local jitter = amount or 0.06
	local h, s, v = base:ToHSV()
	return Color3.fromHSV(
		(h + (math.random() - 0.5) * jitter) % 1,
		math.clamp(s + (math.random() - 0.5) * jitter, 0, 1),
		math.clamp(v + (math.random() - 0.5) * jitter * 1.5, 0, 1)
	)
end

function Palette:names(): { string }
	local out = {}
	for name in self.ramps do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

Visual.defaultRamps = {
	stone = { Color3.fromRGB(58, 60, 64), Color3.fromRGB(96, 98, 102), Color3.fromRGB(142, 142, 146) },
	earth = { Color3.fromRGB(52, 42, 32), Color3.fromRGB(94, 74, 54), Color3.fromRGB(138, 112, 82) },
	foliage = { Color3.fromRGB(38, 58, 38), Color3.fromRGB(64, 92, 56), Color3.fromRGB(108, 132, 76) },
	wood = { Color3.fromRGB(48, 36, 26), Color3.fromRGB(88, 64, 44), Color3.fromRGB(132, 102, 70) },
	metal = { Color3.fromRGB(64, 68, 74), Color3.fromRGB(122, 128, 136), Color3.fromRGB(186, 192, 200) },
	warm = { Color3.fromRGB(122, 52, 30), Color3.fromRGB(206, 108, 46), Color3.fromRGB(255, 196, 108) },
	cold = { Color3.fromRGB(32, 52, 78), Color3.fromRGB(72, 116, 162), Color3.fromRGB(158, 206, 236) },
	cloth = { Color3.fromRGB(64, 56, 60), Color3.fromRGB(120, 104, 96), Color3.fromRGB(178, 164, 148) },
}

--[[
	Material pairing. `SmoothPlastic` on everything is the fourth reason a
	generated world reads as generated: real surfaces catch light differently,
	and Roblox gives that away for the price of one enum.
]]
Visual.materials = {
	stone = { Enum.Material.Slate, Enum.Material.Rock, Enum.Material.Basalt },
	earth = { Enum.Material.Ground, Enum.Material.Mud, Enum.Material.Sand },
	foliage = { Enum.Material.Grass, Enum.Material.LeafyGrass },
	wood = { Enum.Material.Wood, Enum.Material.WoodPlanks },
	metal = { Enum.Material.Metal, Enum.Material.DiamondPlate, Enum.Material.CorrodedMetal },
	cloth = { Enum.Material.Fabric },
}

function Visual.material(family: string, seed: number?): Enum.Material
	local options = Visual.materials[family]
	if not options then
		return Enum.Material.SmoothPlastic
	end
	local index = seed and (math.floor(seed * #options) % #options) + 1 or math.random(1, #options)
	return options[index]
end

-- Dress an instance from a palette family in one call.
function Visual.dress(instance: Instance, family: string, alpha: number?, paletteName: string?)
	local palette = Visual.palette(paletteName or "default")
	local shade = alpha or math.random()
	for _, part in (instance:IsA("BasePart") and { instance } or instance:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Color = palette:vary(family, shade)
			part.Material = Visual.material(family, shade)
		end
	end
end

function Visual.describe(): { [string]: any }
	local active: { [string]: boolean } = {}
	for name, instance in effects do
		local ok, enabled = pcall(function()
			return (instance :: any).Enabled
		end)
		active[name] = ok and enabled or instance.Parent ~= nil
	end
	-- `Lighting.Technology` raises "lacking capability RobloxScript" when read
	-- from ordinary code. It is a property Studio shows and scripts may not
	-- touch, which is exactly the sort of thing that only surfaces when a
	-- snapshot is actually taken.
	local okTechnology, technology = pcall(function()
		return Lighting.Technology.Name
	end)

	if not RunService:IsClient() then
		-- Lighting is a client-side concern. Reporting an unconfigured server
		-- copy as if it were the game's art direction is a false negative, and
		-- a validator would read it as "no look applied".
		return { context = "client-only", appliesHere = false }
	end

	return {
		look = currentLook,
		quality = quality,
		looks = Visual.lookNames(),
		presets = (function()
			local out = {}
			for name in Visual.presets do
				table.insert(out, name)
			end
			table.sort(out)
			return out
		end)(),
		effects = active,
		technology = okTechnology and technology or "unreadable",
	}
end

return Visual
