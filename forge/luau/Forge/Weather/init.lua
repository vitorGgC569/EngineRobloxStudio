--!strict
--[[
	Weather — conditions that change while people are playing.

	`Visual` and `Sky` decide what a world looks like at an hour. Neither has
	any notion of a world that is *currently* raining, or of one condition
	giving way to another over a minute rather than a cut. That gap is why the
	engine's outdoor worlds have exactly one mood each.

	What a condition is here: a set of target values for the sky, the
	atmosphere and the particle layer, plus how long it takes to get there.
	Nothing snaps. A storm that arrives instantly reads as a bug in the
	lighting; a storm that takes forty seconds reads as weather.

		Weather.define("storm", {
			rain = 1, wind = 0.8,
			fog = { density = 0.4, colour = Color3.fromRGB(120, 128, 140) },
			brightness = 0.5, transition = 45,
		})

		Weather.set("storm")
		Weather.cycle({ "clear", "overcast", "rain" })

	--- Client-side, deliberately -------------------------------------------

	Lighting replicates from the server, so a server that drives weather fights
	every client's own atmosphere and loses the race half the time — this
	project has already spent an afternoon on exactly that with the day cycle.
	The server decides *which* condition is in force and tells clients; each
	client renders it. That also means rain is one client's particle budget
	rather than the server's replication budget.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Capability = require(script.Parent.Capability)

local Weather = {}

export type Condition = {
	rain: number?,
	snow: number?,
	wind: number?,
	brightness: number?,
	fog: { density: number?, colour: Color3?, start: number?, ending: number? }?,
	cloudCover: number?,
	cloudDensity: number?,
	transition: number?,
}

Weather.config = {
	transition = 30,
	--: Particles are the expensive half; this caps what any condition can ask.
	maxRainRate = 900,
	holderName = "ForgeWeather",
}

local conditions: { [string]: Condition } = {}
local current: string? = nil
local target: Condition? = nil
local blend = { rain = 0, snow = 0, wind = 0, brightness = 1, density = 0 }
local goal = { rain = 0, snow = 0, wind = 0, brightness = 1, density = 0 }
local rate = 1 / 30
local conn: RBXScriptConnection? = nil
local emitter: ParticleEmitter? = nil

-- ================================== define ==================================
function Weather.define(name: string, condition: Condition)
	conditions[name] = condition
end

function Weather.defineMany(table_: { [string]: Condition })
	for name, condition in table_ do
		conditions[name] = condition
	end
end

function Weather.names(): { string }
	local out = {}
	for name in conditions do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

--[[
	A starting set, so a world has weather before anybody authors any.

	Deliberately mild. A default that ships a thunderstorm makes every game
	built on this engine look like the same game, which is the failure this
	project exists to avoid — these are the neutral ends of a range, not a
	style.
]]
function Weather.installDefaults()
	Weather.defineMany({
		clear = { rain = 0, wind = 0.1, brightness = 1, cloudCover = 0.25,
			fog = { density = 0.08 } },
		overcast = { rain = 0, wind = 0.35, brightness = 0.78, cloudCover = 0.7,
			fog = { density = 0.18, colour = Color3.fromRGB(168, 174, 184) } },
		rain = { rain = 0.7, wind = 0.5, brightness = 0.6, cloudCover = 0.85,
			fog = { density = 0.3, colour = Color3.fromRGB(140, 148, 160) } },
		storm = { rain = 1, wind = 0.9, brightness = 0.45, cloudCover = 1,
			fog = { density = 0.45, colour = Color3.fromRGB(112, 120, 134) } },
		snow = { snow = 0.7, wind = 0.3, brightness = 0.85, cloudCover = 0.8,
			fog = { density = 0.35, colour = Color3.fromRGB(206, 212, 222) } },
	})
end

-- ================================ particles =================================
local function ensureEmitter(): ParticleEmitter?
	if emitter and emitter.Parent then
		return emitter
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	--[[
		Precipitation follows the camera, and is one emitter.

		The obvious implementation puts rain over the map; the map is large and
		the player sees ten studs of it. One emitter parented above the camera
		covers everything anybody can see, costs one instance, and does not
		care how big the world is.
	]]
	local holder = camera:FindFirstChild(Weather.config.holderName)
	if not holder then
		local part = Instance.new("Part")
		part.Name = Weather.config.holderName
		part.Size = Vector3.new(60, 1, 60)
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Parent = camera
		holder = part
	end

	local attachment = holder:FindFirstChildOfClass("Attachment")
		or Instance.new("Attachment", holder)

	local existing = attachment:FindFirstChildOfClass("ParticleEmitter")
	if existing then
		emitter = existing
		return emitter
	end

	local made = Instance.new("ParticleEmitter")
	made.Name = "Precipitation"
	made.Rate = 0
	made.Lifetime = NumberRange.new(0.7, 1.1)
	made.Speed = NumberRange.new(70, 90)
	made.SpreadAngle = Vector2.new(6, 6)
	made.EmissionDirection = Enum.NormalId.Bottom
	made.Size = NumberSequence.new(0.12)
	made.Transparency = NumberSequence.new(0.35)
	made.LightInfluence = 1
	made.Color = ColorSequence.new(Color3.fromRGB(190, 205, 225))
	made.Parent = attachment
	emitter = made
	return emitter
end

-- ================================== drive ===================================
local function applyBlend()
	local drop = ensureEmitter()
	if drop then
		local wet = math.max(blend.rain, blend.snow)
		drop.Rate = wet * Weather.config.maxRainRate
		if blend.snow > blend.rain then
			drop.Speed = NumberRange.new(8, 14)
			drop.Size = NumberSequence.new(0.22)
			drop.Color = ColorSequence.new(Color3.fromRGB(238, 242, 250))
			drop.SpreadAngle = Vector2.new(28, 28)
		else
			drop.Speed = NumberRange.new(70, 90)
			drop.Size = NumberSequence.new(0.12)
			drop.Color = ColorSequence.new(Color3.fromRGB(190, 205, 225))
			drop.SpreadAngle = Vector2.new(6 + blend.wind * 22, 6)
		end
	end

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		Capability.set(atmosphere, "Density", blend.density)
	end

	local clouds = Workspace.Terrain:FindFirstChildOfClass("Clouds")
	if clouds and target then
		Capability.set(clouds, "Cover", target.cloudCover or 0.4)
	end
end

local function step(dt: number)
	local moved = false
	for key, want in goal do
		local have = blend[key]
		if math.abs(want - have) > 1e-3 then
			--[[
				A fixed rate, not an exponential ease.

				Exponential approach never arrives, so a condition that asked
				for forty seconds would still be visibly changing two minutes
				later. Weather has to finish, because the next condition is
				waiting behind it.
			]]
			local stepSize = rate * dt * math.max(1, math.abs(want - have))
			blend[key] = have + math.clamp(want - have, -stepSize, stepSize)
			moved = true
		else
			blend[key] = want
		end
	end
	if moved then
		applyBlend()
	end
end

--[[
	Put a condition in force.

	`immediate` skips the transition, which is for loading into a world that is
	already raining rather than for gameplay: a cut between conditions is the
	one thing that makes weather look scripted.
]]
function Weather.set(name: string, options: any?): boolean
	local condition = conditions[name]
	if not condition then
		warn(string.format("[Weather] no condition named '%s'", tostring(name)))
		return false
	end
	local opts = options or {}

	current = name
	target = condition
	goal.rain = condition.rain or 0
	goal.snow = condition.snow or 0
	goal.wind = condition.wind or 0
	goal.brightness = condition.brightness or 1
	goal.density = condition.fog and condition.fog.density or 0.1

	local seconds = opts.transition or condition.transition or Weather.config.transition
	rate = 1 / math.max(0.1, seconds)

	if opts.immediate then
		for key, want in goal do
			blend[key] = want
		end
		applyBlend()
		return true
	end

	if not conn then
		conn = RunService.Heartbeat:Connect(step)
	end
	return true
end

function Weather.current(): string?
	return current
end

--[[
	Move through a sequence of conditions.

	Weather that changes on a timer is the cheapest way to make a world feel
	like it exists independently of the player, and the whole cost is one
	coroutine that sleeps.
]]
function Weather.cycle(sequence: { string }, everySeconds: number?)
	if #sequence == 0 then
		return
	end
	task.spawn(function()
		local index = 0
		while true do
			index = (index % #sequence) + 1
			Weather.set(sequence[index])
			task.wait(everySeconds or 180)
		end
	end)
end

function Weather.stop()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	goal.rain, goal.snow = 0, 0
	blend.rain, blend.snow = 0, 0
	applyBlend()
end

function Weather.describe(): { [string]: any }
	return {
		context = RunService:IsServer() and "server" or "client",
		conditions = Weather.names(),
		current = current,
		blend = {
			rain = math.floor(blend.rain * 100) / 100,
			snow = math.floor(blend.snow * 100) / 100,
			wind = math.floor(blend.wind * 100) / 100,
			density = math.floor(blend.density * 100) / 100,
		},
		transitioning = conn ~= nil,
	}
end

return Weather
