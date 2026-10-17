--!strict
--[[
	FishVisual — the fish you can actually see.

	Fishing used to be an absence: a line, a bobber, and a minigame, with the
	animal itself only implied somewhere down in the dark. This module draws
	it from parts, in three acts:

	  shadow()  the cast has landed: a dark silhouette circles slowly under
	            the bobber — something is down there, and it is not saying what
	  bite()    the fight starts: the silhouette tightens and darts at the bait
	  land()    the catch: the real fish, in species colour with rarity fins,
	            leaps out of the water toward the angler, spins, splashes,
	            sparkles, and fades

	It is a renderer and nothing else. Which fish it is, how heavy, and
	whether it was even caught arrive in the payload the server already
	sends (`CatchResult`); this file never asks for anything and never
	decides anything. Every entry point is a safe no-op when the bobber is
	not there — somebody else's cast, streamed out, already destroyed — and
	clear() can arrive at any time, including twice, without ever erroring.

	Geometry is deliberately primitive: parts the engine already draws.
	Nothing is welded; one anchored hub carries the pose each frame and
	every piece follows it from a stored offset CFrame, so one destroyed
	part can never drag the rest of the fish along. The only names this
	module leaves in the world are `FishFx_<userId>` and its children, all
	of which die together.

	The one judgement call worth writing down: a leap that is already
	airborne survives a clear(). CatchResult and CastEnd fire one frame
	apart on a catch, so a clear() wired to CastEnd would otherwise cut the
	payoff off before it rendered. The leap owns its own fade-and-destroy —
	about two seconds, guaranteed — and everything else is torn down on the
	spot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local FishCatalog = require(Shared.FishCatalog)

local FishVisual = {}

local player = Players.LocalPlayer

--: The sea surface every other system measures from; fish live below it.
local SEA = Config.waterLevel

--: How deep the silhouette rides, and how visible it is. The bite pulls it
--: a little more solid — enough to read as "awake", not enough to name it.
local SHADOW_DEPTH = 3
local SHADOW_ALPHA = 0.55
local BITE_ALPHA = 0.42
local SILHOUETTE = Color3.fromRGB(30, 48, 62)

--: What a species wears when its rarity cannot be matched.
local NEUTRAL_ACCENT = Color3.fromRGB(168, 196, 206)

--: Zone water colours — the body before the species has a say. Two fish from
--: one zone are then pulled apart by the hash of their id (below), which is
--: the cheapest way to make a catalogue of sixty read as sixty animals.
local ZONE_TINT: { [string]: Color3 } = {
	shallows = Color3.fromRGB(96, 184, 156),
	kelp = Color3.fromRGB(92, 164, 104),
	coral = Color3.fromRGB(224, 140, 122),
	storm = Color3.fromRGB(122, 150, 174),
	abyss = Color3.fromRGB(74, 82, 172),
}
local DEFAULT_TINT = Color3.fromRGB(118, 168, 188)

--: Legendary-class fish are meant to be events, not fish. One multiplier
--: keeps that decision in one place.
local LEGEND_SCALE = 1.32

local SPLASH_COLOR = Color3.fromRGB(214, 236, 244)

type Piece = { part: BasePart, offset: CFrame }

type Skin = {
	body: Color3,
	fin: Color3,
	eye: Color3,
	alpha: number,
}

type AddFn = (
	kind: string,
	name: string,
	size: Vector3,
	pos: Vector3,
	rot: CFrame?,
	color: Color3,
	material: Enum.Material?,
	alpha: number?
) -> ()

type Fx = {
	phase: string, -- "shadow" | "bite" | "leap"
	pieces: { Piece },
	root: BasePart,
	anchor: Vector3,
	bobber: BasePart?,
	clock: number,
	biteClock: number,
	leapT: number,
	leapDur: number,
	done: boolean,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	sparkles: ParticleEmitter?,
	sparkleColor: Color3,
}

--: One fish at a time. `fx` is nil whenever nothing is drawn, and the render
--: connection lives exactly as long as there is something to move.
local folder: Folder? = nil
local fx: Fx? = nil
local renderConn: RBXScriptConnection? = nil

--: Bumped by clear() and land(): a pending shadow search from an older cast
--: checks this and quietly stops.
local token = 0

--: The phase a freshly built silhouette should start in. A retry that was
--: waiting for the bobber to replicate adopts whatever was asked for last,
--: so a slow bobber still becomes a bite, not a stale shadow.
local desired = "shadow"

--: The landing spot has to be remembered while the bobber is still in the
--: water — the server destroys it the moment the reel is won, one beat
--: before CatchResult arrives.
local lastWater: Vector3? = nil

-- ================================ lookups ===================================
local function findBobber(): BasePart?
	local holder = Workspace:FindFirstChild("Bobbers")
	if not holder then
		return nil
	end
	local part = holder:FindFirstChild("Bobber_" .. tostring(player.UserId), true)
	if part and part:IsA("BasePart") then
		return part
	end
	return nil
end

local function rootPosition(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local made = Instance.new("Folder")
	made.Name = "FishFx_" .. tostring(player.UserId)
	made.Parent = Workspace
	folder = made
	return made
end

-- ============================== lifecycle ===================================
local function stopLoop()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
end

--: The immediate teardown: no fade, no goodbye. Used to make room for the
--: next act and by the leap once its own fade has finished.
local function hardTeardown()
	stopLoop()
	fx = nil
	if folder then
		folder:Destroy()
		folder = nil
	end
end

-- ============================== one part ====================================
local function placePart(
	parent: Instance,
	kind: string,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material,
	alpha: number?
): BasePart
	local part: BasePart
	if kind == "ball" then
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball
		part = ball
	elseif kind == "wedge" then
		part = Instance.new("WedgePart")
	else
		part = Instance.new("Part")
	end
	part.Name = name
	part.Size = size
	part.CFrame = offset
	part.Color = color
	part.Material = material
	part.Transparency = alpha or 0
	--: The house rules for anything that is only ever a picture: it may not
	--: be touched, collided with, queried, weighed or shadowed.
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.Parent = parent
	return part
end

-- ============================== particles ===================================
--[[
	A splash or a sparkle: one invisible host part, one emitter, one Emit, and
	a delayed cleanup that outlives the particles but not the folder they
	were born in. Two splashes and a burst per catch is not worth a pool.
]]
local function burst(position: Vector3, color: Color3, count: number, kind: string)
	local host = folder or Workspace
	local part = Instance.new("Part")
	part.Name = if kind == "sparkle" then "Sparkle" else "Splash"
	part.Size = Vector3.one * 0.1
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.CFrame = CFrame.new(position)
	part.Parent = host

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = kind
	emitter.Color = ColorSequence.new(color)
	emitter.LightInfluence = 1
	if kind == "sparkle" then
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.LightEmission = 0.85
		emitter.Speed = NumberRange.new(3, 9)
		emitter.Lifetime = NumberRange.new(0.4, 0.8)
		emitter.Size = NumberSequence.new(0.34, 0)
		emitter.Transparency = NumberSequence.new(0.1, 1)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-120, 120)
		emitter.Acceleration = Vector3.new(0, -8, 0)
	else
		emitter.LightEmission = 0.2
		emitter.Speed = NumberRange.new(10, 22)
		emitter.Lifetime = NumberRange.new(0.32, 0.62)
		emitter.Size = NumberSequence.new(0.3, 0)
		emitter.Transparency = NumberSequence.new(0.15, 1)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.SpreadAngle = Vector2.new(34, 34)
		emitter.Acceleration = Vector3.new(0, -30, 0)
	end
	emitter.Parent = part
	emitter:Emit(count)

	task.delay(1.6, function()
		if part.Parent then
			part:Destroy()
		end
	end)
end

--: The trail that runs while a caught fish is airborne: spray and sparkle
--: falling off it, tinted by the rarity so a mythic's arc announces itself.
local function addSparkTrail(root: BasePart, color: Color3, rate: number): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Spark"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(color)
	emitter.Rate = rate
	emitter.LightEmission = 0.85
	emitter.LightInfluence = 1
	emitter.Lifetime = NumberRange.new(0.25, 0.5)
	emitter.Speed = NumberRange.new(0.5, 2)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, -3, 0)
	emitter.Size = NumberSequence.new(0.3, 0)
	emitter.Transparency = NumberSequence.new(0.1, 1)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-120, 120)
	emitter.Parent = root
	return emitter
end

-- ================================ tinting ===================================
--: djb2 over the id bytes: stable across sessions, unlike anything seeded by
--: time, and small enough to read. Species in one zone come out a touch
--: lighter or darker than each other instead of identically coloured.
local function hashId(id: string): number
	local value = 5381
	for index = 1, #id do
		value = (value * 33 + string.byte(id, index)) % 4294967296
	end
	return value / 4294967296
end

local function tintBody(base: Color3, roll: number): Color3
	local amount = (roll - 0.5) * 0.36
	if amount >= 0 then
		return base:Lerp(Color3.fromRGB(255, 255, 255), amount)
	end
	return base:Lerp(Color3.fromRGB(6, 10, 16), -amount)
end

-- ============================== the bodies ==================================
--[[
	One builder per cclass, all in a unit where a plain fish is about two
	studs long, nose toward -Z. `add` applies the shared scale and records
	the piece's offset from the hub; nothing here knows about motion.

	Wedges are the engine's right-triangular prism — full height at +Z,
	sloping to nothing at -Z — which is why tails are rotated half a turn:
	the tall edge belongs against the body, not out in the water.
]]

local function buildFish(add: AddFn, skin: Skin)
	add("ball", "Body", Vector3.new(0.78, 0.72, 1.72), Vector3.new(0, 0, 0), nil, skin.body, Enum.Material.SmoothPlastic)
	add("wedge", "Tail", Vector3.new(0.08, 0.72, 0.6), Vector3.new(0, 0, 1.08), CFrame.Angles(0, math.pi, 0), skin.fin, Enum.Material.SmoothPlastic)
	add("wedge", "Dorsal", Vector3.new(0.09, 0.5, 0.72), Vector3.new(0, 0.46, 0.06), nil, skin.fin, Enum.Material.SmoothPlastic)
	add("wedge", "Pectoral.Left", Vector3.new(0.5, 0.08, 0.42), Vector3.new(-0.4, -0.12, 0.1), CFrame.Angles(0, 0.55, 0.3), skin.fin, Enum.Material.SmoothPlastic)
	add("wedge", "Pectoral.Right", Vector3.new(0.5, 0.08, 0.42), Vector3.new(0.4, -0.12, 0.1), CFrame.Angles(0, -0.55, -0.3), skin.fin, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Left", Vector3.new(0.15, 0.15, 0.15), Vector3.new(-0.24, 0.16, -0.56), nil, skin.eye, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Right", Vector3.new(0.15, 0.15, 0.15), Vector3.new(0.24, 0.16, -0.56), nil, skin.eye, Enum.Material.SmoothPlastic)
end

local function buildEel(add: AddFn, skin: Skin)
	add("ball", "Segment.Head", Vector3.new(0.34, 0.34, 1.3), Vector3.new(0, -0.02, -1.0), nil, skin.body, Enum.Material.SmoothPlastic)
	add("ball", "Segment.Mid", Vector3.new(0.38, 0.38, 1.4), Vector3.new(0, 0.05, 0.3), nil, skin.body, Enum.Material.SmoothPlastic)
	add("ball", "Segment.Tail", Vector3.new(0.3, 0.3, 1.3), Vector3.new(0, -0.02, 1.5), nil, skin.body, Enum.Material.SmoothPlastic)
	add("wedge", "TailFin", Vector3.new(0.07, 0.5, 0.42), Vector3.new(0, 0, 2.15), CFrame.Angles(0, math.pi, 0), skin.fin, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Left", Vector3.new(0.1, 0.1, 0.1), Vector3.new(-0.11, 0.1, -1.55), nil, skin.eye, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Right", Vector3.new(0.1, 0.1, 0.1), Vector3.new(0.11, 0.1, -1.55), nil, skin.eye, Enum.Material.SmoothPlastic)
end

local function buildRay(add: AddFn, skin: Skin)
	add("ball", "Disc", Vector3.new(2.3, 0.24, 1.9), Vector3.new(0, 0, 0), nil, skin.body, Enum.Material.SmoothPlastic)
	add("block", "Tail", Vector3.new(0.08, 0.08, 1.7), Vector3.new(0, 0.02, 1.65), nil, skin.body, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Left", Vector3.new(0.12, 0.12, 0.12), Vector3.new(-0.4, 0.16, -0.62), nil, skin.eye, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Right", Vector3.new(0.12, 0.12, 0.12), Vector3.new(0.4, 0.16, -0.62), nil, skin.eye, Enum.Material.SmoothPlastic)
end

local function buildShark(add: AddFn, skin: Skin)
	add("ball", "Body", Vector3.new(0.82, 0.78, 2.3), Vector3.new(0, 0, 0), nil, skin.body, Enum.Material.SmoothPlastic)
	add("wedge", "Dorsal", Vector3.new(0.1, 0.78, 1.05), Vector3.new(0, 0.56, 0.02), nil, skin.fin, Enum.Material.SmoothPlastic)
	add("wedge", "TailUpper", Vector3.new(0.09, 1.0, 0.85), Vector3.new(0, 0.42, 1.6), CFrame.Angles(0, math.pi, 0), skin.fin, Enum.Material.SmoothPlastic)
	add("wedge", "TailLower", Vector3.new(0.09, 0.6, 0.6), Vector3.new(0, -0.28, 1.55), CFrame.Angles(0, math.pi, 0), skin.fin, Enum.Material.SmoothPlastic)
	add("wedge", "Pectoral.Left", Vector3.new(0.62, 0.08, 0.5), Vector3.new(-0.46, -0.3, -0.2), CFrame.Angles(0, 0.7, 0.28), skin.fin, Enum.Material.SmoothPlastic)
	add("wedge", "Pectoral.Right", Vector3.new(0.62, 0.08, 0.5), Vector3.new(0.46, -0.3, -0.2), CFrame.Angles(0, -0.7, -0.28), skin.fin, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Left", Vector3.new(0.12, 0.12, 0.12), Vector3.new(-0.27, 0.2, -0.9), nil, skin.eye, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Right", Vector3.new(0.12, 0.12, 0.12), Vector3.new(0.27, 0.2, -0.9), nil, skin.eye, Enum.Material.SmoothPlastic)
end

local function buildSquid(add: AddFn, skin: Skin)
	add("ball", "Mantle", Vector3.new(0.72, 0.72, 1.4), Vector3.new(0, 0, 0.1), nil, skin.body, Enum.Material.SmoothPlastic)
	add("wedge", "Fin.Left", Vector3.new(0.5, 0.06, 0.5), Vector3.new(-0.45, 0.1, 0.62), CFrame.Angles(0, 0.3, 0), skin.body, Enum.Material.SmoothPlastic)
	add("wedge", "Fin.Right", Vector3.new(0.5, 0.06, 0.5), Vector3.new(0.45, 0.1, 0.62), CFrame.Angles(0, -0.3, 0), skin.body, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Left", Vector3.new(0.18, 0.18, 0.18), Vector3.new(-0.3, 0.05, -0.52), nil, skin.eye, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Right", Vector3.new(0.18, 0.18, 0.18), Vector3.new(0.3, 0.05, -0.52), nil, skin.eye, Enum.Material.SmoothPlastic)
	for index = 0, 5 do
		local spread = -0.26 + 0.104 * index
		local length = 0.95 + 0.2 * (index % 2)
		add(
			"block",
			"Tentacle." .. tostring(index),
			Vector3.new(0.09, 0.09, length),
			Vector3.new(spread, -0.28, -0.95),
			CFrame.Angles(-0.55, spread * 1.2, 0),
			skin.body,
			Enum.Material.SmoothPlastic
		)
	end
end

local function buildCrab(add: AddFn, skin: Skin)
	add("ball", "Shell", Vector3.new(1.5, 0.55, 1.15), Vector3.new(0, -0.05, 0), nil, skin.body, Enum.Material.SmoothPlastic)
	add("wedge", "Claw.Left", Vector3.new(0.48, 0.38, 0.6), Vector3.new(-0.88, -0.18, -0.55), CFrame.Angles(0, 0.5, 0), skin.fin, Enum.Material.SmoothPlastic)
	add("wedge", "Claw.Right", Vector3.new(0.48, 0.38, 0.6), Vector3.new(0.88, -0.18, -0.55), CFrame.Angles(0, -0.5, 0), skin.fin, Enum.Material.SmoothPlastic)
	for index = 0, 2 do
		local z = -0.34 + 0.34 * index
		add("block", "Leg.Left." .. tostring(index), Vector3.new(0.1, 0.1, 0.9), Vector3.new(-0.72, -0.35, z), CFrame.Angles(0, 0.6, 0.18), skin.body, Enum.Material.SmoothPlastic)
		add("block", "Leg.Right." .. tostring(index), Vector3.new(0.1, 0.1, 0.9), Vector3.new(0.72, -0.35, z), CFrame.Angles(0, -0.6, -0.18), skin.body, Enum.Material.SmoothPlastic)
	end
	add("ball", "Eye.Left", Vector3.new(0.12, 0.12, 0.12), Vector3.new(-0.24, 0.28, -0.42), nil, skin.eye, Enum.Material.SmoothPlastic)
	add("ball", "Eye.Right", Vector3.new(0.12, 0.12, 0.12), Vector3.new(0.24, 0.28, -0.42), nil, skin.eye, Enum.Material.SmoothPlastic)
end

local function buildJelly(add: AddFn, skin: Skin)
	--: The bell is the one body that is meant to be seen through: a third of
	--: the jelly is water, and the engine's Neon does the rest.
	add("ball", "Bell", Vector3.new(1.3, 0.9, 1.3), Vector3.new(0, 0.25, 0), nil, skin.body, Enum.Material.Neon, 0.35)
	for index = 0, 4 do
		local x = -0.42 + 0.21 * index
		local sway = if index % 2 == 0 then 1 else -1
		add(
			"block",
			"Strand." .. tostring(index),
			Vector3.new(0.07, 1.0 + 0.14 * (index % 3), 0.07),
			Vector3.new(x, -0.62, 0.06 * sway),
			CFrame.Angles(0.08 * sway, 0, 0),
			skin.fin,
			Enum.Material.Neon,
			0.35
		)
	end
end

local function buildAngler(add: AddFn, skin: Skin)
	buildFish(add, skin)
	add("block", "Stalk", Vector3.new(0.06, 0.06, 0.8), Vector3.new(0, 0.62, -0.5), CFrame.Angles(0.9, 0, 0), skin.body, Enum.Material.SmoothPlastic)
	add("ball", "Lure", Vector3.new(0.18, 0.18, 0.18), Vector3.new(0, 0.98, -0.86), nil, skin.fin, Enum.Material.Neon)
end

local function buildLegend(add: AddFn, skin: Skin)
	buildFish(add, skin)
	add("wedge", "Crest", Vector3.new(0.09, 0.66, 0.6), Vector3.new(0, 0.5, 0.85), CFrame.Angles(0, math.pi, 0), skin.fin, Enum.Material.Neon)
	add("ball", "Glow", Vector3.new(0.22, 0.22, 0.22), Vector3.new(0, 0.52, -0.78), nil, skin.fin, Enum.Material.Neon)
end

local BUILDERS: { [string]: (AddFn, Skin) -> () } = {
	fish = buildFish,
	eel = buildEel,
	ray = buildRay,
	shark = buildShark,
	squid = buildSquid,
	crab = buildCrab,
	jelly = buildJelly,
	angler = buildAngler,
	legend = buildLegend,
}

--: Skins a species from whatever the payload could say. The id is the exact
--: one: `CatchResult` carries `speciesId`, `name`, `cclass` and `rarity`
--: (FishingService:363); the catalogue is consulted for zone and, when the
--: payload is thin, for everything else. A name that matches nothing falls
--: back to a plain fish wearing its rarity — never to nothing.
local function resolveLand(payload: any): (string, Skin, number, Color3)
	local data = if type(payload) == "table" then payload else {}

	local species = nil
	if type(data.speciesId) == "string" then
		species = FishCatalog.byId[data.speciesId]
	end
	if not species and type(data.name) == "string" then
		for _, entry in FishCatalog.species do
			if entry.name == data.name then
				species = entry
				break
			end
		end
	end

	local cclass: any = data.cclass
	if type(cclass) ~= "string" or not BUILDERS[cclass] then
		cclass = if species then species.cclass else "fish"
	end
	if type(cclass) ~= "string" or not BUILDERS[cclass] then
		cclass = "fish"
	end

	local rarityId = data.rarity
	if type(rarityId) ~= "string" and species then
		rarityId = species.rarity
	end
	local tier = if type(rarityId) == "string" then FishCatalog.rarityById[rarityId] else nil
	local accent = if tier then tier.color else NEUTRAL_ACCENT
	local order = if tier then tier.order else 1

	local zoneId = if species then species.zone else nil
	local base = (type(zoneId) == "string" and ZONE_TINT[zoneId]) or DEFAULT_TINT
	local id = if type(data.speciesId) == "string" then data.speciesId
		elseif species then species.id
		elseif type(data.name) == "string" then data.name
		else "fish"

	local body = tintBody(base, hashId(id))
	local skin: Skin = {
		body = body,
		fin = accent,
		eye = Color3.fromRGB(14, 18, 22),
		alpha = 0,
	}
	if cclass == "angler" then
		--: The angler carries its own dark — the lure is the only bright
		--: thing on it, and both of those facts are the species.
		skin.body = body:Lerp(Color3.fromRGB(8, 10, 16), 0.5)
	end

	local scale = 1 + 0.05 * (math.clamp(order, 1, 6) - 1)
	if cclass == "legend" then
		scale *= LEGEND_SCALE
	end
	return cclass, skin, scale, accent
end

-- ============================== assembly ====================================
local function buildBody(host: Instance, pieces: { Piece }, cclass: string, skin: Skin, scale: number)
	local function add(
		kind: string,
		name: string,
		size: Vector3,
		pos: Vector3,
		rot: CFrame?,
		color: Color3,
		material: Enum.Material?,
		alpha: number?
	)
		local offset = CFrame.new(pos * scale) * (rot or CFrame.new())
		local part = placePart(host, kind, name, size * scale, offset, color, material or Enum.Material.SmoothPlastic, alpha or skin.alpha)
		pieces[#pieces + 1] = { part = part, offset = offset }
	end

	local builder = BUILDERS[cclass] or BUILDERS.fish
	builder(add, skin)
end

--: The invisible hub every piece is posed from. Anchored, so it can simply
--: be assigned a CFrame each frame; nothing is welded to anything.
local function makeRoot(parent: Instance): BasePart
	local root = Instance.new("Part")
	root.Name = "Hub"
	root.Size = Vector3.one * 0.2
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Massless = true
	root.CastShadow = false
	root.Parent = parent
	return root
end

-- =============================== the leap ===================================
local function concludeLeap(s: Fx)
	if s.done then
		return
	end
	s.done = true
	if s.sparkles then
		s.sparkles.Enabled = false
	end

	--: The arrival: one last splash where the fish meets the angler, and a
	--: burst in the rarity's colour — the card is about to say the same
	--: thing in words.
	burst(s.c, SPLASH_COLOR, 16, "splash")
	burst(s.c, s.sparkleColor, 18, "sparkle")

	local fade = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, piece in s.pieces do
		if piece.part.Parent then
			TweenService:Create(piece.part, fade, { Transparency = 1 }):Play()
		end
	end
	task.delay(0.85, function()
		if fx == s then
			hardTeardown()
		end
	end)
end

-- ============================== the loop ====================================
local function step(dt: number)
	local s = fx
	if not s then
		return
	end
	s.clock += dt

	--: Follow the bobber while it lives; freeze the anchor where it stood
	--: when it does not. A bobber destroyed mid-fight must not error, and a
	--: fish that keeps circling its last known spot is a smaller lie than a
	--: fish that vanishes.
	if s.bobber and s.bobber.Parent then
		s.anchor = Vector3.new(s.bobber.Position.X, SEA - SHADOW_DEPTH, s.bobber.Position.Z)
		lastWater = s.bobber.Position
	else
		s.bobber = nil
	end

	local pose: CFrame
	if s.phase == "leap" then
		s.leapT += dt
		local t = math.clamp(s.leapT / s.leapDur, 0, 1)
		local u = 1 - t
		local pos = s.a * (u * u) + s.b * (2 * u * t) + s.c * (t * t)
		local tangent = (s.b - s.a) * (2 * u) + (s.c - s.b) * (2 * t)
		if tangent.Magnitude < 0.05 then
			tangent = s.c - s.a
		end
		if tangent.Magnitude < 0.001 then
			tangent = Vector3.new(0, 1, 0)
		end
		--: End over end — a fish that left the water in a hurry.
		pose = CFrame.lookAt(pos, pos + tangent.Unit) * CFrame.Angles(s.leapT * 9, 0, 0)
		if t >= 1 then
			concludeLeap(s)
		end
	elseif s.phase == "bite" then
		s.biteClock += dt
		local tighten = math.min(1, s.biteClock / 0.7)
		local radius = 1.5 - 0.85 * tighten
		local angle = s.clock * 2.6
		local jitter = Vector3.new(math.sin(s.clock * 26), math.sin(s.clock * 31) * 0.45, math.cos(s.clock * 29)) * 0.3
		local pos = s.anchor + Vector3.new(math.cos(angle) * radius, math.sin(s.clock * 6) * 0.26, math.sin(angle) * radius) + jitter
		local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		pose = CFrame.lookAt(pos, pos + tangent)
	else
		local radius = 1.6 + math.sin(s.clock * 0.45) * 0.3
		local angle = s.clock * 0.85
		local pos = s.anchor + Vector3.new(math.cos(angle) * radius, math.sin(s.clock * 1.6) * 0.2, math.sin(angle) * radius)
		local tangent = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		pose = CFrame.lookAt(pos, pos + tangent) * CFrame.Angles(0, 0, math.sin(s.clock * 1.2) * 0.08)
	end

	s.root.CFrame = pose
	for _, piece in s.pieces do
		if piece.part.Parent then
			piece.part.CFrame = pose * piece.offset
		end
	end
end

local function ensureLoop()
	if renderConn then
		return
	end
	renderConn = RunService.RenderStepped:Connect(step)
end

-- ============================== the silhouette ==============================
--: The waiting fish: species unknown, so the shape is the plainest one there
--: is, and the colour is "something dark in dark water".
local function spawnSilhouette(): boolean
	local current = fx
	if current and current.phase == "leap" then
		return false
	end

	local bobber = findBobber()
	if not bobber then
		return false
	end

	hardTeardown()
	local host = ensureFolder()
	local root = makeRoot(host)
	local pieces: { Piece } = {}
	local phase = if desired == "bite" then "bite" else "shadow"
	local alpha = if phase == "bite" then BITE_ALPHA else SHADOW_ALPHA
	local skin: Skin = {
		body = SILHOUETTE,
		fin = SILHOUETTE,
		eye = SILHOUETTE,
		alpha = alpha,
	}
	buildBody(host, pieces, "fish", skin, 1.15)

	fx = {
		phase = phase,
		pieces = pieces,
		root = root,
		anchor = Vector3.new(bobber.Position.X, SEA - SHADOW_DEPTH, bobber.Position.Z),
		bobber = bobber,
		clock = 0,
		biteClock = 0,
		leapT = 0,
		leapDur = 1,
		done = false,
		a = Vector3.zero,
		b = Vector3.zero,
		c = Vector3.zero,
		sparkles = nil,
		sparkleColor = SILHOUETTE,
	}
	lastWater = bobber.Position
	ensureLoop()
	return true
end

--[[
	Build the silhouette now if the bobber replicates with us, and otherwise
	search briefly: the cast state can reach the client a beat before the
	part it announces does, and losing the whole visual to that reorder
	would be silly. Token-guarded, and it stands down at once if a leap is
	still airborne or the cast has since ended.
]]
local function buildSilhouetteSoon()
	local current = fx
	if current and current.phase ~= "leap" then
		return
	end
	local mine = token
	if spawnSilhouette() then
		return
	end
	task.spawn(function()
		for _ = 1, 16 do
			task.wait(0.08)
			if token ~= mine then
				return
			end
			local now = fx
			if now and now.phase ~= "leap" then
				return
			end
			if spawnSilhouette() then
				return
			end
		end
	end)
end

-- ============================== public API ==================================
--: A cast has landed: the silhouette starts its slow circle. Safe no-op when
--: the bobber is not on this client's side of the replication fence.
function FishVisual.shadow()
	desired = "shadow"
	buildSilhouetteSoon()
end

--: The bite: the same silhouette, tighter and darting. If it was never
--: built — the bobber was late — this builds one already mid-fight.
function FishVisual.bite()
	desired = "bite"
	local current = fx
	if current and current.phase ~= "leap" then
		current.phase = "bite"
		current.biteClock = 0
		for _, piece in current.pieces do
			--: A little less water over the body: the thing down there is
			--: awake now, and about to be named.
			piece.part.Transparency = BITE_ALPHA
		end
		return
	end
	buildSilhouetteSoon()
end

--: The catch. The payload is `CatchResult` exactly as served
--: (FishingService:363): the fish is rebuilt in its own colours and leaps
--: out of the water toward the angler, spins, splashes, and fades.
function FishVisual.land(payload: any)
	token += 1
	desired = "shadow"

	local cclass, skin, scale, accent = resolveLand(payload)

	local bobber = findBobber()
	local at = if bobber then bobber.Position else lastWater
	if not at then
		--: Nothing to leap out of — the cast was never watchable on this
		--: client. Whatever is on screen, take it down and say nothing.
		hardTeardown()
		return
	end
	lastWater = at

	local rootPos = rootPosition()
	local start = Vector3.new(at.X, SEA - 1.2, at.Z)
	local finish = if rootPos then rootPos + Vector3.new(0, 1.2, 0) else start + Vector3.new(0, 3, 0)
	local distance = (finish - start).Magnitude

	hardTeardown()
	local host = ensureFolder()
	local root = makeRoot(host)
	local pieces: { Piece } = {}
	buildBody(host, pieces, cclass, skin, scale)

	fx = {
		phase = "leap",
		pieces = pieces,
		root = root,
		anchor = at,
		bobber = nil,
		clock = 0,
		biteClock = 0,
		leapT = 0,
		leapDur = math.clamp(0.55 + distance / 55, 0.7, 1.15),
		done = false,
		a = start,
		b = Vector3.new(
			(start.X + finish.X) / 2,
			math.max(SEA + 3, (start.Y + finish.Y) / 2 + 1.5),
			(start.Z + finish.Z) / 2
		),
		c = finish,
		sparkles = addSparkTrail(root, accent, if cclass == "legend" then 26 else 9),
		sparkleColor = accent,
	}
	ensureLoop()

	--: Two splashes frame the arc: the breach at the water, the arrival at
	--: the angler. The first also covers the frame the fish is still under.
	burst(start, SPLASH_COLOR, 22, "splash")
end

--: Cast end / any abort: fade what is there and destroy it, idempotent and
--: quiet when there is nothing. A leap that is already airborne is the one
--: exception — see the header — and it ends itself within two seconds.
function FishVisual.clear()
	token += 1
	desired = "shadow"
	lastWater = nil

	local current = fx
	if current and current.phase == "leap" and not current.done then
		return
	end
	stopLoop()
	fx = nil

	if current then
		local fade = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		for _, piece in current.pieces do
			if piece.part.Parent then
				TweenService:Create(piece.part, fade, { Transparency = 1 }):Play()
			end
		end
	end

	local doomed = folder
	folder = nil
	if doomed then
		task.delay(0.24, function()
			if doomed.Parent then
				doomed:Destroy()
			end
		end)
	end
end

return FishVisual
