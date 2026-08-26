--!strict
--[[
	Weapon — the layer between "the player pressed fire" and "something took
	damage".

	Combat already knows how to fly a projectile and how to apply damage. What
	was missing is everything in between: how often a weapon may fire, where the
	shot actually goes when the barrel is not perfectly still, how many rounds
	are left, and what happens while reloading. Those rules are the same for
	every shooter ever made, which is exactly why they belong here and not in
	the game.

	What this module does NOT decide: what a weapon is called, what it costs,
	who may hold it, what it looks like, or whether your game even has guns.
	It gives you numbers and a verdict; the game decides what they mean.

		Weapon.define("longbow", {
			mode = "projectile",
			damage = 46, rpm = 55, range = 700,
			charge = { time = 0.85, minRatio = 0.3 },
			magazine = 1, reserve = math.huge, reloadTime = 0.55,
			projectile = { speed = 190, gravity = 42 },
		})

		Weapon.equip(character, "longbow")

		local shot = Weapon.fire(character, muzzle, aimDirection, {
			ignore = { character },
			onHit = function(model, position, normal) ... end,
		})
		if not shot.ok then
			-- shot.reason is "cooldown" | "empty" | "reloading" | "no-weapon"
		end

	--- Determinism, and why it matters -------------------------------------

	Spread is generated from a seed, not from `math.random`. `Weapon.fire`
	returns the seed it used, so a client that predicts a shot and the server
	that resolves it produce the *same* pellet pattern from the same number.
	Without that, every shotgun blast disagrees between the two machines and
	you get corrections on every trigger pull.

	--- No update loop ------------------------------------------------------

	Spread recovery, recoil decay and reload completion are all computed from
	timestamps when someone asks, never on a heartbeat. A hundred idle weapons
	cost nothing, because an idle weapon genuinely has nothing to do.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Combat owns flight and damage; Weapon owns the trigger. Required at the top
-- because Combat never requires back, so there is no cycle to be careful of.
local Combat = require(script.Parent.Combat)

local Weapon = {}

--[[
	Three things the trigger logic below does not do on its own.

	`Stance` is how posture scales the cone -- aiming narrows it, sprinting and
	jumping widen it -- which is what makes movement a decision rather than a
	free action. `Sway` is the walk bob, strafe lean and idle drift that make a
	held weapon read as held. `Validate` is for servers accepting a client's
	claim about where it fired from, and is the only one of the three that a
	single-player game can ignore.
]]
Weapon.Stance = require(script.Stance)
Weapon.Sway = require(script.Sway)
Weapon.Validate = require(script.Validate)

local defs: { [string]: any } = {}
local equipped: { [Model]: any } = {}

-- =================================== define =================================
local DEFAULTS = {
	mode = "hitscan",
	damage = 20,
	rpm = 400,
	pellets = 1,
	range = 900,
	magazine = 20,
	reserve = math.huge,
	reloadTime = 1.6,
	auto = false,
	-- Clip names the game may play. Stored here so a weapon carries its own
	-- animation vocabulary instead of the game keeping a parallel table.
	clip = "shoot",
	aimClip = "aim",
	reloadClip = "reload",
}

local SPREAD_DEFAULT = { min = 0.4, max = 6, perShot = 0.8, recover = 5 }
local RECOIL_DEFAULT = { pitch = 1.1, yaw = 0.35, recover = 9 }
local FALLOFF_DEFAULT = { start = 140, stop = 600, floor = 0.4 }

--[[
	Register a weapon. Definitions are data and are meant to be reloaded: call
	`define` again with the same id and every weapon already in someone's hands
	picks up the new numbers, which is what makes tuning a weapon a five-second
	loop instead of a restart.
]]
function Weapon.define(id: string, spec: any)
	local def = {}
	for key, value in DEFAULTS do
		def[key] = value
	end
	for key, value in spec do
		def[key] = value
	end

	def.spread = def.spread or {}
	for key, value in SPREAD_DEFAULT do
		if def.spread[key] == nil then
			def.spread[key] = value
		end
	end
	def.recoil = def.recoil or {}
	for key, value in RECOIL_DEFAULT do
		if def.recoil[key] == nil then
			def.recoil[key] = value
		end
	end
	if def.falloff ~= false then
		def.falloff = def.falloff or {}
		for key, value in FALLOFF_DEFAULT do
			if def.falloff[key] == nil then
				def.falloff[key] = value
			end
		end
	end

	def.id = id
	def.interval = 60 / math.max(1, def.rpm)
	defs[id] = def
	return def
end

function Weapon.definition(id: string): any?
	return defs[id]
end

function Weapon.ids(): { string }
	local list = {}
	for id in defs do
		table.insert(list, id)
	end
	table.sort(list)
	return list
end

-- ==================================== state =================================
--[[
	Bring a weapon's derived state up to the present moment.

	Everything time-based resolves here: a reload that has finished, spread that
	has settled, recoil that has decayed. Called by every public reader, so no
	caller can ever observe a stale weapon.
]]
local function resolve(state: any): any
	local def = defs[state.id]
	if not def then
		return state
	end
	local now = os.clock()

	if state.reloadingUntil and now >= state.reloadingUntil then
		local wanted = def.magazine - state.ammo
		local taken = math.min(wanted, state.reserve)
		state.ammo += taken
		state.reserve -= taken
		state.reloadingUntil = nil
	end

	local since = now - (state.lastFire or -math.huge)
	if state.spread > def.spread.min then
		-- Exponential settle. Linear recovery feels wrong: real recovery is
		-- fast at first and then creeps the last fraction of a degree.
		local settled = def.spread.min
			+ (state.spreadAtShot - def.spread.min) * math.exp(-def.spread.recover * since)
		state.spread = math.max(def.spread.min, settled)
	end

	local recoilSince = now - (state.recoilAt or -math.huge)
	if state.recoilPitch ~= 0 or state.recoilYaw ~= 0 then
		local decay = math.exp(-def.recoil.recover * recoilSince)
		state.recoilPitch = state.recoilPitchAt * decay
		state.recoilYaw = state.recoilYawAt * decay
		if math.abs(state.recoilPitch) < 0.01 then
			state.recoilPitch, state.recoilYaw = 0, 0
		end
	end

	return state
end

--[[
	Give a character a weapon. Equipping the same id twice is a no-op rather
	than a reset, so a game that calls this defensively every frame does not
	silently refill the magazine.
]]
function Weapon.equip(owner: Model, id: string): any
	local def = defs[id]
	if not def then
		error(string.format("[Weapon] no weapon defined as '%s'", tostring(id)), 2)
	end
	local current = equipped[owner]
	if current and current.id == id then
		return resolve(current)
	end

	local state = {
		id = id,
		owner = owner,
		ammo = def.magazine,
		reserve = def.reserve,
		spread = def.spread.min,
		spreadAtShot = def.spread.min,
		recoilPitch = 0,
		recoilYaw = 0,
		recoilPitchAt = 0,
		recoilYawAt = 0,
		recoilAt = 0,
		lastFire = -math.huge,
		reloadingUntil = nil,
		chargeStart = nil,
		shotsFired = 0,
		seq = 0,
	}
	equipped[owner] = state
	return state
end

function Weapon.unequip(owner: Model)
	equipped[owner] = nil
end

function Weapon.state(owner: Model): any?
	local state = equipped[owner]
	return state and resolve(state) or nil
end

function Weapon.equippedId(owner: Model): string?
	local state = equipped[owner]
	return state and state.id or nil
end

-- =================================== reload =================================
function Weapon.reload(owner: Model): boolean
	local state = Weapon.state(owner)
	if not state then
		return false
	end
	local def = defs[state.id]
	if state.reloadingUntil or state.ammo >= def.magazine or state.reserve <= 0 then
		return false
	end
	state.reloadingUntil = os.clock() + def.reloadTime
	return true
end

function Weapon.isReloading(owner: Model): boolean
	local state = Weapon.state(owner)
	return state ~= nil and state.reloadingUntil ~= nil
end

--[[
	How far through the reload we are, 0 to 1.

	Exists so a progress ring on the HUD does not have to duplicate the timing
	maths and drift out of sync with the weapon it is describing.
]]
function Weapon.reloadProgress(owner: Model): number
	local state = Weapon.state(owner)
	if not state or not state.reloadingUntil then
		return 1
	end
	local def = defs[state.id]
	local remaining = state.reloadingUntil - os.clock()
	return math.clamp(1 - remaining / math.max(0.01, def.reloadTime), 0, 1)
end

-- =================================== charge =================================
--[[
	Draw weapons — bows, railguns, anything where holding the button matters.

	A charge is just a timestamp. The ratio is read at the moment of release and
	multiplies damage and projectile speed, so a half-drawn bow is genuinely
	weaker rather than merely slower to animate.
]]
function Weapon.beginCharge(owner: Model)
	local state = Weapon.state(owner)
	if state then
		state.chargeStart = os.clock()
	end
end

function Weapon.cancelCharge(owner: Model)
	local state = Weapon.state(owner)
	if state then
		state.chargeStart = nil
	end
end

--[[
	How far the weapon is drawn, 0 to 1.

	Reports the truth, including zero. An earlier version floored this at
	`minRatio`, which quietly made the "undercharged" refusal in `fire`
	unreachable: a client that never started a draw got a 30% shot instead of
	nothing. The floor belongs at the gate, not in the measurement.
]]
function Weapon.chargeRatio(owner: Model): number
	local state = Weapon.state(owner)
	if not state then
		return 0
	end
	local def = defs[state.id]
	if not def.charge then
		return 1
	end
	if not state.chargeStart then
		return 0
	end
	local held = os.clock() - state.chargeStart
	return math.clamp(held / math.max(0.01, def.charge.time), 0, 1)
end

-- =================================== spread =================================
--[[
	Deterministic cone.

	The same seed and index always produce the same direction, which is what
	lets the client draw a tracer that lands where the server says it landed.
	`math.random` here would be a desync per pellet.
]]
function Weapon.spreadDirection(direction: Vector3, degrees: number, seed: number, index: number): Vector3
	if degrees <= 0 then
		return direction.Unit
	end
	local rng = Random.new(seed * 8191 + index * 131)
	-- Uniform over the cone's cap: sqrt keeps pellets from bunching at the
	-- centre, which is what a naive uniform angle does.
	local angle = math.rad(degrees) * math.sqrt(rng:NextNumber())
	local roll = rng:NextNumber() * math.pi * 2

	local forward = direction.Unit
	local reference = math.abs(forward.Y) > 0.99 and Vector3.new(1, 0, 0) or Vector3.new(0, 1, 0)
	local right = forward:Cross(reference).Unit
	local up = right:Cross(forward).Unit

	local offset = (right * math.cos(roll) + up * math.sin(roll)) * math.tan(angle)
	return (forward + offset).Unit
end

--[[
	The cone right now, in degrees.

	Pass a stance to include posture. Omitting it returns the bloom alone, which
	is what a HUD wants when the game has no aiming model -- and what every
	existing caller got before stance existed.
]]
function Weapon.currentSpread(owner: Model, stance: any?): number
	local state = Weapon.state(owner)
	if not state then
		return 0
	end
	local cone = state.spread or 0
	if stance then
		cone *= Weapon.Stance.multiplier(defs[state.id], stance)
	end
	return cone
end

-- =================================== damage =================================
local function falloffMultiplier(def: any, distance: number): number
	local f = def.falloff
	if not f then
		return 1
	end
	if distance <= f.start then
		return 1
	end
	if distance >= f.stop then
		return f.floor
	end
	local t = (distance - f.start) / math.max(0.01, f.stop - f.start)
	return 1 + (f.floor - 1) * t
end

-- ==================================== fire ==================================
local function hitModel(instance: Instance): Model?
	local model = instance:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") or model:GetAttribute("Health") then
			return model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

--[[
	Pull the trigger.

	Always returns a table. `ok = false` with a `reason` is the normal way a
	weapon says no — refusing by returning nil would make every caller write the
	same nil check and lose the reason, which is the part the HUD wants.

	Options:
	  ignore   instances the shot passes through (the shooter, usually)
	  seed     supply one to reproduce a shot exactly; omit and one is made
	  stance   {ads, moving, sprinting, airborne}; widens or narrows this shot
	  onHit    called per pellet that connects: (model?, position, normal, damage)
	  onSpawn  projectile mode only, called with each projectile made
	  filter   projectile mode only, forwarded to Combat
]]
function Weapon.fire(owner: Model, origin: Vector3, direction: Vector3, options: any?): any
	local state = Weapon.state(owner)
	if not state then
		return { ok = false, reason = "no-weapon" }
	end
	local def = defs[state.id]
	local opts = options or {}
	local now = os.clock()

	if state.reloadingUntil then
		return { ok = false, reason = "reloading", reloadProgress = Weapon.reloadProgress(owner) }
	end
	if now - state.lastFire < def.interval then
		return { ok = false, reason = "cooldown", readyIn = def.interval - (now - state.lastFire) }
	end
	if state.ammo <= 0 then
		return { ok = false, reason = "empty" }
	end

	local charge = Weapon.chargeRatio(owner)
	if def.charge and def.charge.minRatio and charge < def.charge.minRatio then
		return { ok = false, reason = "undercharged", charge = charge }
	end

	local seed = opts.seed or math.random(1, 2 ^ 30)
	--: Posture widens or narrows the cone this shot rolls in. Applied to the
	--: roll only, never written back to `state.spread`, so bloom and stance
	--: stay separable -- a player who stops sprinting is instantly accurate
	--: again, while the bloom they built up still has to recover.
	local spread = state.spread
	if opts.stance then
		spread *= Weapon.Stance.multiplier(def, opts.stance)
	end
	local shots = {}

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = opts.ignore or { owner }

	for pellet = 1, def.pellets do
		local dir = Weapon.spreadDirection(direction, spread, seed, pellet)
		local damage = def.damage * charge

		if def.mode == "hitscan" then
			local result = Workspace:Raycast(origin, dir * def.range, params)
			local position = result and result.Position or (origin + dir * def.range)
			local distance = (position - origin).Magnitude
			local model = result and hitModel(result.Instance) or nil
			local dealt = damage * falloffMultiplier(def, distance)

			table.insert(shots, {
				direction = dir,
				position = position,
				normal = result and result.Normal or -dir,
				distance = distance,
				target = model,
				damage = dealt,
			})
			if opts.onHit then
				task.spawn(opts.onHit, model, position, result and result.Normal or -dir, dealt)
			end
		else
			-- Projectile mode hands off to Combat, which owns flight. Damage is
			-- resolved at impact, not here, because distance is not known yet.
			local p = def.projectile or {}
			local proj = Combat.projectile({
				origin = origin,
				direction = dir,
				speed = (p.speed or 160) * (def.charge and (0.5 + 0.5 * charge) or 1),
				gravity = p.gravity or 0,
				life = p.life or 5,
				radius = p.radius or 0,
				pierce = p.pierce or 0,
				ignore = opts.ignore or { owner },
				filter = opts.filter,
				visual = p.visual,
				onHit = function(model, position, normal)
					local dealt = damage * falloffMultiplier(def, (position - origin).Magnitude)
					if opts.onHit then
						opts.onHit(model, position, normal, dealt)
					end
				end,
				onExpire = opts.onExpire,
			})
			table.insert(shots, { direction = dir, projectile = proj, damage = damage })
			if opts.onSpawn then
				task.spawn(opts.onSpawn, proj, dir)
			end
		end
	end

	state.ammo -= 1
	state.shotsFired += 1
	state.seq += 1
	state.lastFire = now
	state.chargeStart = nil

	state.spread = math.min(def.spread.max, state.spread + def.spread.perShot)
	state.spreadAtShot = state.spread

	-- Recoil is stored, never applied: the camera belongs to the client and a
	-- server that moves it is a server fighting the player's mouse.
	state.recoilPitchAt = def.recoil.pitch * (0.85 + math.random() * 0.3)
	state.recoilYawAt = def.recoil.yaw * (math.random() * 2 - 1)
	state.recoilPitch = state.recoilPitchAt
	state.recoilYaw = state.recoilYawAt
	state.recoilAt = now

	if state.ammo <= 0 and def.autoReload ~= false then
		Weapon.reload(owner)
	end

	return {
		ok = true,
		seed = seed,
		seq = state.seq,
		shots = shots,
		charge = charge,
		spread = spread,
		ammo = state.ammo,
		reserve = state.reserve,
		clip = def.clip,
	}
end

--[[
	The recoil the camera should be showing right now, in degrees.

	Read it every frame and add it to the aim angles; it decays on its own, so
	there is nothing to reset and nothing to leak if the player stops firing.
]]
function Weapon.recoil(owner: Model): (number, number)
	local state = Weapon.state(owner)
	if not state then
		return 0, 0
	end
	return state.recoilPitch, state.recoilYaw
end

function Weapon.ammo(owner: Model): (number, number)
	local state = Weapon.state(owner)
	if not state then
		return 0, 0
	end
	return state.ammo, state.reserve
end

-- What a validator reads to prove a shooting game actually has weapons.
function Weapon.describe(): { [string]: any }
	local held = 0
	for _ in equipped do
		held += 1
	end
	local list = {}
	for id, def in defs do
		list[id] = {
			mode = def.mode,
			damage = def.damage,
			rpm = def.rpm,
			pellets = def.pellets,
			magazine = def.magazine,
			charged = def.charge ~= nil,
		}
	end
	return {
		context = RunService:IsServer() and "server" or "client",
		defined = list,
		equippedCount = held,
		stance = Weapon.Stance.describe(),
		sway = Weapon.Sway.describe(),
		validate = Weapon.Validate.describe(),
	}
end

return Weapon
