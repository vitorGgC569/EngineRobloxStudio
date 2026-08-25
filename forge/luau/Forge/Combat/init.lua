--!strict
--[[
	Combat — mechanism for hurting things. Never policy about what hurting means.

	The distinction is the whole design. Combat knows how to find what is in
	front of a sword, how to run a damage number through a chain of modifiers,
	how to keep a status effect ticking and how to fly a projectile. It does not
	know what armour is, whether crits exist, or how your game scales damage by
	level — you install those as modifiers, and they compose.

		Combat.addModifier("armor", 100, function(ctx)
			local armor = ctx.target:GetAttribute("Armor") or 0
			ctx.amount *= 100 / (100 + armor)
		end)

		Combat.addModifier("crit", 200, function(ctx)
			if ctx.rng and ctx.rng:bool(ctx.critChance or 0) then
				ctx.amount *= 1.85
				ctx.crit = true
			end
		end)

	Then a hit is:

		local hits = Combat.arc(root.Position, look, { range = 9, angle = 110 })
		for _, model in hits do
			Combat.damage(model, { amount = 24, source = player, critChance = 0.1 })
		end

	Modifiers run in ascending order. Order is explicit because "armour before
	or after crit" changes balance and should never be an accident of table
	iteration.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Signal = require(script.Parent.Core.Signal)
local Sched = require(script.Parent.Core.Sched)

local Combat = {}

-- (target: Model, result: table)
Combat.damaged = Signal.new()
-- (target: Model, killer: any)
Combat.killed = Signal.new()

-- ============================== health access ===============================
-- Works with a Humanoid, or with a plain Model carrying Health/MaxHealth
-- attributes. Nothing else in Forge cares which you chose.

function Combat.getHealth(model: Model): (number, number)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		return humanoid.Health, humanoid.MaxHealth
	end
	return model:GetAttribute("Health") or 0, model:GetAttribute("MaxHealth") or 0
end

function Combat.setHealth(model: Model, value: number)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = math.clamp(value, 0, humanoid.MaxHealth)
		return
	end
	local max = model:GetAttribute("MaxHealth") or 0
	model:SetAttribute("Health", math.clamp(value, 0, max))
end

function Combat.isAlive(model: Model?): boolean
	if not model or not model.Parent then
		return false
	end
	local health = Combat.getHealth(model)
	return health > 0
end

-- ========================== invulnerability windows =========================
local iframes: { [Model]: number } = {}

function Combat.grantIFrames(model: Model, seconds: number)
	iframes[model] = math.max(iframes[model] or 0, os.clock() + seconds)
end

function Combat.hasIFrames(model: Model): boolean
	local until_ = iframes[model]
	return until_ ~= nil and os.clock() < until_
end

function Combat.clearIFrames(model: Model)
	iframes[model] = nil
end

-- ============================== modifier chain ==============================
type Modifier = { name: string, order: number, fn: (ctx: any) -> () }

local modifiers: { Modifier } = {}

function Combat.addModifier(name: string, order: number, fn: (ctx: any) -> ())
	for i, existing in modifiers do
		if existing.name == name then
			modifiers[i] = { name = name, order = order, fn = fn }
			table.sort(modifiers, function(a, b)
				return a.order < b.order
			end)
			return
		end
	end
	table.insert(modifiers, { name = name, order = order, fn = fn })
	table.sort(modifiers, function(a, b)
		return a.order < b.order
	end)
end

function Combat.removeModifier(name: string)
	for i, existing in modifiers do
		if existing.name == name then
			table.remove(modifiers, i)
			return
		end
	end
end

function Combat.modifierNames(): { string }
	local out = {}
	for _, m in modifiers do
		table.insert(out, string.format("%d:%s", m.order, m.name))
	end
	return out
end

--[[
	spec fields Combat itself understands:
	  amount      base damage (required)
	  source      whatever dealt it — a Player, a Model, a string
	  position    where the hit landed, for effects
	  direction   for knockback and directional VFX
	  ignoreIFrames
	  kind        free-form tag your modifiers can branch on ("melee", "fire")

	Everything else is passed through untouched for modifiers to read.
	Returns the result context, or nil if the hit did not land.
]]
function Combat.damage(target: Model, spec: any): any?
	if not Combat.isAlive(target) then
		return nil
	end
	if not spec.ignoreIFrames and Combat.hasIFrames(target) then
		return nil
	end

	local ctx = table.clone(spec)
	ctx.target = target
	ctx.blocked = false
	ctx.crit = false
	ctx.cancelled = false
	ctx.amount = spec.amount or 0

	for _, modifier in modifiers do
		modifier.fn(ctx)
		if ctx.cancelled then
			return nil
		end
	end

	ctx.amount = math.max(0, ctx.amount)
	local before = Combat.getHealth(target)
	Combat.setHealth(target, before - ctx.amount)
	local after = Combat.getHealth(target)
	ctx.dealt = before - after
	ctx.remaining = after

	Combat.damaged:Fire(target, ctx)

	if after <= 0 then
		iframes[target] = nil
		Combat.killed:Fire(target, ctx.source, ctx)
	end
	return ctx
end

function Combat.heal(target: Model, amount: number, source: any?): number
	if not Combat.isAlive(target) then
		return 0
	end
	local before, max = Combat.getHealth(target)
	local healed = math.min(amount, max - before)
	Combat.setHealth(target, before + healed)
	return healed
end

-- ================================ hitboxes ==================================
-- All queries return Models (deduplicated), never parts, because gameplay
-- cares about creatures and parts are an implementation detail.

local function modelsFromParts(parts: { BasePart }, filter: ((Model) -> boolean)?): { Model }
	local seen: { [Model]: boolean } = {}
	local out: { Model } = {}
	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not seen[model] then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid or model:GetAttribute("Health") then
				if not filter or filter(model) then
					seen[model] = true
					table.insert(out, model)
				end
			end
		end
	end
	return out
end

local function paramsFrom(options: any): OverlapParams
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = options.ignore or {}
	params.MaxParts = options.maxParts or 60
	return params
end

--[[
	The melee workhorse: a cone in front of the attacker.

	`angle` is the full cone in degrees. 110 is a normal sword; 360 is a spin.
	Radius culling happens first because a box query is cheaper than a dot
	product over everything in the world.
]]
function Combat.arc(origin: Vector3, direction: Vector3, options: any?): { Model }
	local opts = options or {}
	local range = opts.range or 9
	local halfAngle = math.rad((opts.angle or 110) / 2)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.01 then
		return {}
	end
	local look = flat.Unit

	local parts = Workspace:GetPartBoundsInRadius(origin, range, paramsFrom(opts))
	local candidates = modelsFromParts(parts, opts.filter)

	local hits: { Model } = {}
	for _, model in candidates do
		local pivot = model:GetPivot().Position
		local toTarget = Vector3.new(pivot.X - origin.X, 0, pivot.Z - origin.Z)
		if toTarget.Magnitude < 0.01 then
			table.insert(hits, model)
			continue
		end
		-- vertical tolerance stops a sword hitting something on a roof
		if math.abs(pivot.Y - origin.Y) > (opts.height or 8) then
			continue
		end
		if look:Dot(toTarget.Unit) >= math.cos(halfAngle) then
			table.insert(hits, model)
		end
	end

	if opts.limit and #hits > opts.limit then
		table.sort(hits, function(a, b)
			return (a:GetPivot().Position - origin).Magnitude < (b:GetPivot().Position - origin).Magnitude
		end)
		local trimmed = {}
		for i = 1, opts.limit do
			trimmed[i] = hits[i]
		end
		return trimmed
	end
	return hits
end

function Combat.sphere(position: Vector3, radius: number, options: any?): { Model }
	local opts = options or {}
	return modelsFromParts(Workspace:GetPartBoundsInRadius(position, radius, paramsFrom(opts)), opts.filter)
end

function Combat.box(cframe: CFrame, size: Vector3, options: any?): { Model }
	local opts = options or {}
	return modelsFromParts(Workspace:GetPartBoundsInBox(cframe, size, paramsFrom(opts)), opts.filter)
end

-- Line of sight. Melee that hits through walls is the single most common
-- combat bug in a Roblox game, and this is the one line that prevents it.
function Combat.canSee(from: Vector3, target: Model, ignore: { Instance }?): boolean
	local pivot = target:GetPivot().Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list = ignore and table.clone(ignore) or {}
	table.insert(list, target)
	params.FilterDescendantsInstances = list

	local result = Workspace:Raycast(from, pivot - from, params)
	return result == nil
end

-- =============================== status effects =============================
type StatusDef = {
	interval: number?,
	onApply: ((target: Model, state: any) -> ())?,
	onTick: ((target: Model, state: any) -> ())?,
	onRemove: ((target: Model, state: any) -> ())?,
	stacks: boolean?,
	refresh: boolean?,
}

local statusDefs: { [string]: StatusDef } = {}
local active: { [Model]: { [string]: any } } = {}
local statusGroup = nil

function Combat.defineStatus(id: string, def: StatusDef)
	statusDefs[id] = def
end

function Combat.applyStatus(target: Model, id: string, options: any?)
	local def = statusDefs[id]
	if not def then
		warn(string.format("[Combat] unknown status '%s'", id))
		return
	end
	if not Combat.isAlive(target) then
		return
	end
	local opts = options or {}

	local onTarget = active[target]
	if not onTarget then
		onTarget = {}
		active[target] = onTarget
	end

	local existing = onTarget[id]
	if existing then
		if def.stacks then
			existing.stacks += (opts.stacks or 1)
		end
		if def.refresh ~= false then
			existing.expires = os.clock() + (opts.duration or 5)
		end
		existing.power = opts.power or existing.power
		return
	end

	local state = {
		id = id,
		power = opts.power or 1,
		stacks = opts.stacks or 1,
		source = opts.source,
		expires = os.clock() + (opts.duration or 5),
		nextTick = os.clock() + (def.interval or 1),
	}
	onTarget[id] = state
	if def.onApply then
		def.onApply(target, state)
	end
	Combat.startStatusLoop()
end

function Combat.removeStatus(target: Model, id: string)
	local onTarget = active[target]
	local state = onTarget and onTarget[id]
	if not state then
		return
	end
	local def = statusDefs[id]
	if def and def.onRemove then
		def.onRemove(target, state)
	end
	onTarget[id] = nil
end

function Combat.hasStatus(target: Model, id: string): boolean
	local onTarget = active[target]
	return onTarget ~= nil and onTarget[id] ~= nil
end

function Combat.statusesOn(target: Model): { [string]: any }
	return active[target] or {}
end

-- One loop for every status on every creature, not one per effect.
function Combat.startStatusLoop()
	if statusGroup then
		return
	end
	statusGroup = Sched.group(10)
	statusGroup:add("statuses", function()
		local now = os.clock()
		for target, onTarget in active do
			if not Combat.isAlive(target) then
				for id in onTarget do
					Combat.removeStatus(target, id)
				end
				active[target] = nil
				continue
			end
			for id, state in onTarget do
				local def = statusDefs[id]
				if not def then
					onTarget[id] = nil
					continue
				end
				if now >= state.expires then
					Combat.removeStatus(target, id)
					continue
				end
				if def.onTick and now >= state.nextTick then
					state.nextTick = now + (def.interval or 1)
					def.onTick(target, state)
				end
			end
		end
	end)
end

-- ================================ projectiles ===============================
local projectiles: { any } = {}
local projectileConn: RBXScriptConnection? = nil

--[[
	Server-authoritative projectile: it moves by raycast, so it cannot tunnel
	through a wall at high speed the way a Touched-based one does.

		Combat.projectile({
			origin = muzzle, direction = aim, speed = 110,
			gravity = 0, life = 4, radius = 0,
			ignore = { casterCharacter },
			filter = function(model) return model ~= casterCharacter end,
			onHit = function(model, position, normal) ... end,
			visual = { color = c, size = Vector3.new(0.4, 0.4, 2.4), trail = true },
		})
]]
function Combat.projectile(spec: any): any
	local proj = {
		position = spec.origin,
		velocity = spec.direction.Unit * (spec.speed or 90),
		gravity = spec.gravity or 0,
		life = spec.life or 5,
		radius = spec.radius or 0,
		filter = spec.filter,
		onHit = spec.onHit,
		onExpire = spec.onExpire,
		pierce = spec.pierce or 0,
		hitCount = 0,
		born = os.clock(),
		alive = true,
	}

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = spec.ignore or {}
	proj.params = params

	if spec.visual then
		proj.part = Combat.projectileVisual(spec.visual, proj.position, proj.velocity)
	end

	table.insert(projectiles, proj)
	Combat.startProjectileLoop()
	return proj
end

--[[
	The body of a shot, built on its own.

	Split out of `Combat.projectile` so the client can draw one without the
	server's simulation attached — see `Combat.tracer`.
]]
function Combat.projectileVisual(v: any, position: Vector3, velocity: Vector3): BasePart
	local part = Instance.new("Part")
	part.Size = v.size or Vector3.new(0.4, 0.4, 2.2)
	part.Color = v.color or Color3.fromRGB(255, 180, 90)
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = CFrame.lookAt(position, position + velocity)
	part.Parent = Workspace

	if v.light ~= false then
		local light = Instance.new("PointLight")
		light.Color = part.Color
		light.Range = 14
		light.Brightness = 2
		light.Parent = part
	end
	if v.trail then
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(0, 0, part.Size.Z / 2)
		a0.Parent = part
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(0, 0, -part.Size.Z / 2)
		a1.Parent = part
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = 0.25
		trail.LightEmission = 1
		trail.Color = ColorSequence.new(part.Color)
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Parent = part
	end
	return part
end

local function killProjectile(proj: any)
	proj.alive = false
	if proj.part then
	proj.part:Destroy()
	proj.part = nil
	end
end

function Combat.startProjectileLoop()
	if projectileConn then
	return
	end
	projectileConn = RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	for i = #projectiles, 1, -1 do
		local proj = projectiles[i]
		if not proj.alive then
			table.remove(projectiles, i)
			continue
		end
		if now - proj.born > proj.life then
			if proj.onExpire then
				task.spawn(proj.onExpire, proj.position)
			end
			killProjectile(proj)
			table.remove(projectiles, i)
			continue
		end

		proj.velocity += Vector3.new(0, -proj.gravity * dt, 0)
		local step = proj.velocity * dt
		local result = Workspace:Raycast(proj.position, step, proj.params)

		if result then
			local model = result.Instance:FindFirstAncestorOfClass("Model")
			local valid = model and (model:FindFirstChildOfClass("Humanoid") or model:GetAttribute("Health"))
			local passes = not valid or not proj.filter or proj.filter(model)

			if passes then
				if proj.onHit then
					task.spawn(proj.onHit, valid and model or nil, result.Position, result.Normal)
				end
				proj.hitCount += 1
				if proj.hitCount > proj.pierce then
					killProjectile(proj)
					table.remove(projectiles, i)
					continue
				end
				-- pierced: keep going, but do not re-hit the same thing
				local list = table.clone(proj.params.FilterDescendantsInstances)
				table.insert(list, model or result.Instance)
				proj.params.FilterDescendantsInstances = list
			end
			proj.position = result.Position
		else
			proj.position += step
		end

		if proj.part then
			proj.part.CFrame = CFrame.lookAt(proj.position, proj.position + proj.velocity)
		end
	end

	if #projectiles == 0 and projectileConn then
		projectileConn:Disconnect()
		projectileConn = nil
	end
	end)
end

function Combat.projectileCount(): number
	return #projectiles
end

-- ============================== client visuals ==============================
--[[
	A shot you can see immediately.

	The authoritative projectile lives on the server, which means its part
	arrives half a round trip after the trigger was pulled. At 120ms that is the
	difference between a weapon that fires and a weapon that hesitates.

	So the client draws its own. A tracer has no raycast, deals no damage and
	decides nothing — it flies the same arc from the same origin and is thrown
	away. If it disagrees with the server by a few centimetres, nobody can tell;
	if it were authoritative, that gap would be an exploit.

		Combat.tracer({
			origin = muzzle, direction = aim, speed = 190, gravity = 42,
			life = 3, stopAt = hitPosition,   -- optional, from the server
			visual = { color = c, trail = true },
		})
]]
local tracers: { any } = {}
local tracerConn: RBXScriptConnection? = nil

function Combat.tracer(spec: any): any
	local tracer = {
		origin = spec.origin,
		position = spec.origin,
		velocity = spec.direction.Unit * (spec.speed or 160),
		gravity = spec.gravity or 0,
		life = spec.life or 3,
		born = os.clock(),
		alive = true,
		stopAt = spec.stopAt,
		onEnd = spec.onEnd,
	}
	tracer.part = Combat.projectileVisual(spec.visual or {}, tracer.position, tracer.velocity)

	function tracer:stop()
		self.alive = false
	end

	table.insert(tracers, tracer)
	if not tracerConn then
		tracerConn = RunService.RenderStepped:Connect(function(dt)
			local now = os.clock()
			for i = #tracers, 1, -1 do
				local tr = tracers[i]
				local done = not tr.alive or now - tr.born > tr.life

				if not done then
					tr.velocity += Vector3.new(0, -tr.gravity * dt, 0)
					tr.position += tr.velocity * dt
					-- Given a hit point by the server, stop there rather than
					-- flying through it: the visual should agree with the
					-- damage the player just saw land.
					if tr.stopAt and (tr.position - tr.origin).Magnitude >= (tr.stopAt - tr.origin).Magnitude then
						tr.position = tr.stopAt
						done = true
					end
					if tr.part then
						tr.part.CFrame = CFrame.lookAt(tr.position, tr.position + tr.velocity)
					end
				end

				if done then
					if tr.onEnd then
						task.spawn(tr.onEnd, tr.position)
					end
					if tr.part then
						tr.part:Destroy()
					end
					tr.alive = false
					table.remove(tracers, i)
				end
			end
			if #tracers == 0 and tracerConn then
				tracerConn:Disconnect()
				tracerConn = nil
			end
		end)
	end
	return tracer
end

--[[
	A hitscan line, drawn and faded.

	Instant weapons have no projectile to watch, so the tracer *is* the whole
	feedback. Kept short-lived on purpose: a beam that lingers turns a firefight
	into a cat's cradle.
]]
function Combat.beam(from: Vector3, to: Vector3, options: any?)
	local o = options or {}
	local distance = (to - from).Magnitude
	if distance < 0.1 then
		return
	end

	local part = Instance.new("Part")
	part.Size = Vector3.new(o.width or 0.12, o.width or 0.12, distance)
	part.CFrame = CFrame.lookAt(from + (to - from) / 2, to)
	part.Color = o.color or Color3.fromRGB(255, 226, 160)
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = o.transparency or 0.25
	part.Parent = Workspace

	local life = o.life or 0.06
	local start = os.clock()
	local base = part.Transparency
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - start) / life
		if t >= 1 or not part.Parent then
			conn:Disconnect()
			part:Destroy()
			return
		end
		part.Transparency = base + (1 - base) * t
	end)
end

function Combat.tracerCount(): number
	return #tracers
end

-- What a validator reads to prove combat is wired, without knowing the game.
function Combat.describe(): { [string]: any }
	local statusCount = 0
	for _ in statusDefs do
		statusCount += 1
	end
	local afflicted = 0
	for _ in active do
		afflicted += 1
	end
	return {
		modifiers = Combat.modifierNames(),
		statusTypes = statusCount,
		afflictedTargets = afflicted,
		liveProjectiles = #projectiles,
		liveTracers = #tracers,
	}
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.Combat.AbilitySystem`
	was nil while `require(ReplicatedStorage.Forge.Combat.AbilitySystem)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(Combat, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
