--!strict
--[[
	Visual.Sky — the "shader pack" layer.

	What people mean by a Minecraft shader pack is not one effect. It is five
	things arriving together, and Roblox can do all five — most projects just
	never turn them on:

	  1. Real shadows. `Lighting.Technology = Future` is the single biggest
	     lever there is, and it is the one setting that cannot be changed from
	     a script: it has to be in the place file. Everything below looks flat
	     without it.
	  2. A sun that reads as a light source. Large angular size, strong glare,
	     god rays through the haze.
	  3. Volumetric clouds. One `Clouds` instance under Terrain, and a flat sky
	     becomes a sky.
	  4. Water that reflects and moves.
	  5. A day that actually passes, with colour grading keyed to the hour
	     rather than one look bolted on.

		Sky.install()                       -- sky, clouds, water
		Sky.cycle({ minutesPerDay = 20 })   -- and time starts moving

	The cycle interpolates every property together. A dawn where the fog warms
	before the ambient does looks broken in a way nobody can name, which is why
	this drives one blend across a keyframe table instead of tweening each
	effect on its own schedule.
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Visual = require(script.Parent)
local Signal = require(script.Parent.Parent.Core.Signal)

local Sky = {}

Sky.hourChanged = Signal.new() -- (hour)
Sky.phaseChanged = Signal.new() -- (phaseName)

local cycleConn: RBXScriptConnection? = nil
local pinGuard: RBXScriptConnection? = nil
local clock = 8.0
local phase = "morning"

-- Properties this Roblox version refused. Read it rather than wondering why
-- the grass never appeared.
Sky.unavailable = {} :: { string }

Sky.config = {
	minutesPerDay = 24,
	startHour = 7.5,
	-- Sun size drives how "present" the light feels. Roblox's default 21 reads
	-- as a distant lamp; a wider disc with strong glare reads as a sun.
	sunAngularSize = 26,
	moonAngularSize = 14,
	starCount = 6500,
	clouds = true,
	water = true,
	decoration = true,
}

-- ============================== the day table ===============================
--[[
	Eight keys around the clock. Between them everything interpolates.

	The values are chosen so the *shape* of the day is right: cold and low at
	dawn, neutral and high at noon, warm and long at golden hour, and a night
	that is blue and legible rather than black. A night you cannot see in is not
	atmospheric, it is a bug report.
]]
--[[
	Eight keys around the clock.

	Retuned after looking at the result: the first version used atmosphere and
	fog as its main tool and produced a grey-green wash — everything equally
	hazy, saturation pulled *down*, contrast flat. That is the opposite of what
	people mean by a shader look.

	The principle these values follow instead:

	  * Clear air near, haze only far. `fogStart` sits at half of `fogEnd`, not
	    at a tenth, so nothing within combat distance is veiled.
	  * Contrast and saturation go **up**, not down. A shader look is bright
	    highlights against dark shadows, not an even mid-grey.
	  * The sun is a light source you can look at. Large disc, high glare,
	    exposure high enough that lit surfaces clip a little.
	  * Density stays low. Roblox atmosphere at 0.5 fogs the whole world; the
	    interesting range for a clear day is 0.1 to 0.25.
]]
Sky.day = {
	{
		hour = 0, name = "deep_night",
		brightness = 0.8, exposure = 0.05,
		ambient = Color3.fromRGB(22, 30, 52), outdoor = Color3.fromRGB(46, 60, 96),
		fog = Color3.fromRGB(22, 30, 52), fogEnd = 900,
		atmosphere = { density = 0.2, haze = 1.2, glare = 0.1, color = Color3.fromRGB(120, 146, 196), decay = Color3.fromRGB(30, 40, 66) },
		grade = { contrast = 0.2, saturation = 0.08, tint = Color3.fromRGB(206, 220, 255), brightness = 0.01 },
		bloom = { intensity = 1.2, size = 30, threshold = 0.65 },
		rays = 0,
		clouds = { cover = 0.45, density = 0.04, color = Color3.fromRGB(70, 88, 128) },
	},
	{
		hour = 5.6, name = "dawn",
		brightness = 1.9, exposure = 0.22,
		ambient = Color3.fromRGB(64, 56, 72), outdoor = Color3.fromRGB(150, 120, 130),
		fog = Color3.fromRGB(196, 140, 138), fogEnd = 1200,
		atmosphere = { density = 0.24, haze = 3.4, glare = 0.7, color = Color3.fromRGB(255, 186, 168), decay = Color3.fromRGB(88, 74, 96) },
		grade = { contrast = 0.16, saturation = 0.2, tint = Color3.fromRGB(255, 238, 232) },
		bloom = { intensity = 1.1, size = 30, threshold = 0.8 },
		-- Low sun through haze: the one hour where rays are the whole picture.
		rays = 0.55,
		clouds = { cover = 0.5, density = 0.05, color = Color3.fromRGB(255, 190, 178) },
	},
	{
		hour = 8, name = "morning",
		brightness = 2.8, exposure = 0.16,
		ambient = Color3.fromRGB(96, 102, 112), outdoor = Color3.fromRGB(178, 190, 204),
		fog = Color3.fromRGB(196, 214, 232), fogEnd = 2200,
		atmosphere = { density = 0.14, haze = 1.6, glare = 0.35, color = Color3.fromRGB(214, 228, 244), decay = Color3.fromRGB(96, 110, 132) },
		grade = { contrast = 0.14, saturation = 0.16, tint = Color3.fromRGB(252, 253, 255) },
		bloom = { intensity = 0.7, size = 26, threshold = 1.0 },
		rays = 0.25,
		clouds = { cover = 0.4, density = 0.045, color = Color3.fromRGB(248, 252, 255) },
	},
	{
		hour = 12.5, name = "noon",
		brightness = 3.4, exposure = 0.18,
		ambient = Color3.fromRGB(116, 120, 126), outdoor = Color3.fromRGB(196, 202, 210),
		fog = Color3.fromRGB(206, 224, 244), fogEnd = 3000,
		atmosphere = { density = 0.1, haze = 1.0, glare = 0.4, color = Color3.fromRGB(216, 232, 250), decay = Color3.fromRGB(102, 120, 146) },
		grade = { contrast = 0.13, saturation = 0.18 },
		bloom = { intensity = 0.6, size = 24, threshold = 1.15 },
		rays = 0.18,
		clouds = { cover = 0.3, density = 0.04, color = Color3.fromRGB(252, 254, 255) },
	},
	{
		hour = 16.5, name = "afternoon",
		brightness = 3.0, exposure = 0.24,
		ambient = Color3.fromRGB(112, 100, 88), outdoor = Color3.fromRGB(206, 176, 142),
		fog = Color3.fromRGB(232, 196, 156), fogEnd = 2000,
		atmosphere = { density = 0.16, haze = 2.4, glare = 0.65, color = Color3.fromRGB(255, 216, 178), decay = Color3.fromRGB(112, 94, 78) },
		grade = { contrast = 0.15, saturation = 0.24, tint = Color3.fromRGB(255, 248, 238) },
		bloom = { intensity = 0.9, size = 28, threshold = 0.95 },
		rays = 0.4,
		clouds = { cover = 0.35, density = 0.05, color = Color3.fromRGB(255, 240, 220) },
	},
	{
		hour = 18.4, name = "golden",
		brightness = 2.8, exposure = 0.34,
		ambient = Color3.fromRGB(104, 78, 62), outdoor = Color3.fromRGB(214, 146, 96),
		fog = Color3.fromRGB(246, 176, 110), fogEnd = 1700,
		atmosphere = { density = 0.2, haze = 3.0, glare = 0.9, color = Color3.fromRGB(255, 200, 146), decay = Color3.fromRGB(116, 82, 62) },
		grade = { contrast = 0.18, saturation = 0.3, tint = Color3.fromRGB(255, 244, 226) },
		bloom = { intensity = 1.25, size = 32, threshold = 0.8 },
		-- Peak rays. Glare near 1 and a low sun is the whole effect.
		rays = 0.85,
		clouds = { cover = 0.45, density = 0.055, color = Color3.fromRGB(255, 214, 164) },
	},
	{
		hour = 20.0, name = "dusk",
		brightness = 1.5, exposure = 0.18,
		ambient = Color3.fromRGB(54, 52, 74), outdoor = Color3.fromRGB(110, 112, 156),
		fog = Color3.fromRGB(104, 100, 146), fogEnd = 1300,
		atmosphere = { density = 0.22, haze = 2.4, glare = 0.5, color = Color3.fromRGB(190, 180, 226), decay = Color3.fromRGB(60, 62, 96) },
		grade = { contrast = 0.2, saturation = 0.14, tint = Color3.fromRGB(236, 238, 255) },
		bloom = { intensity = 1.2, size = 32, threshold = 0.75 },
		rays = 0.3,
		clouds = { cover = 0.5, density = 0.05, color = Color3.fromRGB(168, 164, 208) },
	},
	{
		hour = 24, name = "deep_night",
		brightness = 0.8, exposure = 0.05,
		ambient = Color3.fromRGB(22, 30, 52), outdoor = Color3.fromRGB(46, 60, 96),
		fog = Color3.fromRGB(22, 30, 52), fogEnd = 900,
		atmosphere = { density = 0.2, haze = 1.2, glare = 0.1, color = Color3.fromRGB(120, 146, 196), decay = Color3.fromRGB(30, 40, 66) },
		grade = { contrast = 0.2, saturation = 0.08, tint = Color3.fromRGB(206, 220, 255), brightness = 0.01 },
		bloom = { intensity = 1.2, size = 30, threshold = 0.65 },
		rays = 0,
		clouds = { cover = 0.45, density = 0.04, color = Color3.fromRGB(70, 88, 128) },
	},
}

-- ================================= install ==================================
local function effect(className: string, name: string, parent: Instance): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local created = Instance.new(className)
	created.Name = name
	created.Parent = parent
	return created
end

--[[
	Sky, clouds and water. Idempotent, so calling it twice is harmless.

	`Lighting.Technology` is read-only at runtime and raises a capability error
	if even *read* from an ordinary script, so it is not touched here — it goes
	in the project file. This function warns when the place is not on Future,
	because every value below was chosen for it.
]]
function Sky.install()
	local sky = effect("Sky", "ForgeSky", Lighting) :: Sky
	sky.StarCount = Sky.config.starCount
	sky.SunAngularSize = Sky.config.sunAngularSize
	sky.MoonAngularSize = Sky.config.moonAngularSize
	sky.CelestialBodiesShown = true

	if Sky.config.clouds then
		local terrain = Workspace.Terrain
		local clouds = terrain:FindFirstChildOfClass("Clouds")
		if not clouds then
			clouds = Instance.new("Clouds")
			clouds.Parent = terrain
		end
		;(clouds :: Clouds).Enabled = true
	end

	--[[
		Waving grass on grass-material terrain.

		Guarded, and the guard is the lesson. `Terrain.Decoration` does not
		exist in every Roblox version — on 0.735 it throws "not a valid member",
		and because `install` is a straight run of property writes, that one
		line aborted everything after it: the water never got its reflectance,
		and the warning about Lighting.Technology never printed. A cosmetic
		nicety took out the rest of the function.

		Anything optional in here gets this treatment. A missing property should
		cost you that property, not the sky.
	]]
	if Sky.config.decoration then
		local ok = pcall(function()
			(Workspace.Terrain :: any).Decoration = true
		end)
		if not ok then
			table.insert(Sky.unavailable, "Terrain.Decoration")
		end
	end

	if Sky.config.water then
		local terrain = Workspace.Terrain
		-- Reflectance is what makes water read as a surface rather than as
		-- tinted glass; the wave settings keep it from looking like a mirror.
		terrain.WaterReflectance = 0.6
		terrain.WaterTransparency = 0.55
		terrain.WaterWaveSize = 0.12
		terrain.WaterWaveSpeed = 8
		terrain.WaterColor = Color3.fromRGB(26, 84, 96)
	end

	local ok, technology = pcall(function()
		return Lighting.Technology.Name
	end)
	if ok and technology ~= "Future" then
		warn(string.format(
			"[Sky] Lighting.Technology is %s. Every value here was tuned for Future; "
			.. "set it in default.project.json — it cannot be changed from a script.",
			technology
		))
	end
end

-- ================================== cycle ===================================
local function blend(a: any, b: any, alpha: number): any
	local out: any = {}
	for key, value in b do
		local previous = a[key]
		if type(value) == "number" and type(previous) == "number" then
			out[key] = previous + (value - previous) * alpha
		elseif typeof(value) == "Color3" and typeof(previous) == "Color3" then
			out[key] = previous:Lerp(value, alpha)
		elseif type(value) == "table" and type(previous) == "table" then
			out[key] = blend(previous, value, alpha)
		else
			out[key] = value
		end
	end
	return out
end

function Sky.keyAt(hour: number): (any, any, number)
	local keys = Sky.day
	for index = 1, #keys - 1 do
		local a, b = keys[index], keys[index + 1]
		if hour >= a.hour and hour <= b.hour then
			local span = b.hour - a.hour
			return a, b, span > 0 and (hour - a.hour) / span or 0
		end
	end
	return keys[#keys - 1], keys[#keys], 1
end

-- Turn a blended key into a `Visual` look and apply it, so quality tiers and
-- everything else in Visual keep working.
function Sky.applyHour(hour: number)
	local a, b, alpha = Sky.keyAt(hour % 24)
	local key = blend(a, b, alpha)

	Visual.defineLook("__sky", {
		clockTime = hour % 24,
		brightness = key.brightness,
		exposure = key.exposure,
		ambient = key.ambient,
		outdoorAmbient = key.outdoor,
		fogColor = key.fog,
		-- Half, not a tenth: air within fighting distance must be clear.
		fogStart = key.fogEnd * 0.5,
		fogEnd = key.fogEnd,
		shadowSoftness = 0.35,
		environmentDiffuse = 0.5,
		environmentSpecular = 0.45,
		atmosphere = key.atmosphere,
		bloom = key.bloom,
		colorCorrection = key.grade,
		sunRays = key.rays > 0 and { intensity = key.rays, spread = 1 } or nil,
	})
	Visual.apply("__sky")

	local clouds = Workspace.Terrain:FindFirstChildOfClass("Clouds")
	if clouds and key.clouds then
		clouds.Cover = key.clouds.cover
		clouds.Density = key.clouds.density
		clouds.Color = key.clouds.color
	end

	local name = alpha < 0.5 and a.name or b.name
	if name ~= phase then
		phase = name
		Sky.phaseChanged:Fire(phase)
	end
end

function Sky.cycle(options: any?)
	local opts = options or {}
	Sky.config.minutesPerDay = opts.minutesPerDay or Sky.config.minutesPerDay
	clock = opts.startHour or Sky.config.startHour

	Sky.install()
	Sky.applyHour(clock)

	if cycleConn then
		cycleConn:Disconnect()
	end
	local secondsPerHour = (Sky.config.minutesPerDay * 60) / 24
	local signal = RunService:IsClient() and RunService.RenderStepped or RunService.Heartbeat

	cycleConn = signal:Connect(function(dt)
		clock = (clock + dt / secondsPerHour) % 24
		Sky.applyHour(clock)
		Sky.hourChanged:Fire(clock)
	end)
end

function Sky.stop()
	if cycleConn then
		cycleConn:Disconnect()
		cycleConn = nil
	end
end

function Sky.setHour(hour: number)
	clock = hour % 24
	Sky.applyHour(clock)
end

--[[
	Hold a fixed hour against replication.

	`setHour` alone loses: Lighting replicates from the server, so the place
	file's `ClockTime` lands *after* an early client write and silently wins.
	The symptom is a sky stuck at whatever the project file says while the code
	insists it set golden hour — which is exactly what happened here.

	A cycle does not have this problem because it rewrites every frame. A pinned
	look needs to notice and reassert.
]]
function Sky.pin(hour: number)
	Sky.stop()
	clock = hour % 24
	Sky.applyHour(clock)

	local guard
	guard = Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
		if math.abs(Lighting.ClockTime - clock) > 0.05 then
			Sky.applyHour(clock)
		end
	end)
	pinGuard = guard

	--[[
		And a heartbeat, because the Changed guard alone is not enough: if the
		replicated value lands *before* the connection exists, nothing ever
		fires and the pin silently loses. Re-asserting once a second is cheap
		and cannot be raced.
	]]
	task.spawn(function()
		while pinGuard do
			Sky.applyHour(clock)
			task.wait(1)
		end
	end)
end

function Sky.unpin()
	if pinGuard then
		pinGuard:Disconnect()
		pinGuard = nil
	end
end

function Sky.hour(): number
	return clock
end

function Sky.phase(): string
	return phase
end

function Sky.describe(): { [string]: any }
	local clouds = Workspace.Terrain:FindFirstChildOfClass("Clouds")
	local ok, technology = pcall(function()
		return Lighting.Technology.Name
	end)
	return {
		hour = math.floor(clock * 100) / 100,
		phase = phase,
		running = cycleConn ~= nil,
		clouds = clouds ~= nil and clouds.Enabled,
		waterReflectance = Workspace.Terrain.WaterReflectance,
		technology = ok and technology or "unreadable",
		minutesPerDay = Sky.config.minutesPerDay,
	}
end

return Sky
