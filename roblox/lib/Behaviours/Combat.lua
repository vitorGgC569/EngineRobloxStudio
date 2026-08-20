--!strict
--- Hitting things, and being hit.
---
--- Combat is three questions the engine does not answer for you: what did the
--- swing touch, was it allowed to, and what does the player see happen. Get the
--- first wrong and attacks pass through enemies; get the second wrong and
--- people hit their own team; get the third wrong and a fight that works feels
--- broken because nothing acknowledges the hit.
---
--- **A hitbox is a query, not a part.** Spawning an invisible brick and waiting
--- for `Touched` is the usual first attempt, and it misses fast swings entirely
--- because the part never overlaps anything on a frame the physics engine
--- looked at. An overlap query at the moment of the swing does not miss.
---
--- **Every hit is acknowledged.** Damage numbers, a flash, a sound, a small
--- knock. None of it changes the arithmetic and all of it is why the fight
--- reads.

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local Core = require(script.Parent.Parent.Core)
local Events, Actions = Core.Events, Core.Actions
local Trove, Timer, Signal = Core.Trove, Core.Timer, Core.Signal
local Spatial, Curve, Pool = Core.Spatial, Core.Curve, Core.Pool

local Combat = {}

export type Weapon = {
	name: string,
	damage: number,
	--- Studs in front of the attacker the swing reaches.
	reach: number?,
	--- How wide the arc is, in studs across.
	width: number?,
	cooldown: number?,
	knockback: number?,
	--- A multiplier applied when the target is behind the attacker.
	backstab: number?,
}

local DEFAULT: Weapon = {
	name = "Fists", damage = 8, reach = 7, width = 6, cooldown = 0.55,
	knockback = 12, backstab = 1.0,
}

--- What is in front of somebody, right now.
---
--- The overlap runs at the instant of the swing rather than over a window, so
--- a fast attack cannot slip between frames.
function Combat.inFront(attacker: Instance, reach: number, width: number,
	options: { [string]: any }?): { Model }

	local opts = options or {}
	local ok, pivot = pcall(function()
		return attacker:GetPivot()
	end)
	if not ok then
		return {}
	end

	local centre = pivot.Position + pivot.LookVector * (reach * 0.5)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attacker }
	params.MaxParts = 60

	local seen: { [Model]: boolean } = {}
	local out: { Model } = {}
	local parts = workspace:GetPartBoundsInBox(
		CFrame.lookAt(centre, centre + pivot.LookVector),
		Vector3.new(width, math.max(width, 6), reach), params)

	for _, part in ipairs(parts) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model ~= nil and model ~= attacker and not seen[model] then
			local damageable = model:FindFirstChildOfClass("Humanoid") ~= nil
				or model:GetAttribute("Health") ~= nil
			if damageable then
				-- Line of sight, so a swing does not pass through a wall.
				local hitPoint = model:GetPivot().Position
				if opts.throughWalls == true
					or Spatial.sees(pivot.Position, hitPoint,
						{ caster = attacker, target = model }) then
					seen[model] = true
					table.insert(out, model)
				end
			end
		end
	end
	return out
end

--- Show that a hit landed. None of this changes the arithmetic.
function Combat.acknowledge(target: Instance, amount: number, options: { [string]: any }?)
	local opts = options or {}
	local ok, pivot = pcall(function()
		return target:GetPivot()
	end)
	if not ok then
		return
	end

	-- A number that rises and fades. The clearest possible signal that the
	-- swing connected, and the thing most often left out.
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.one
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.Anchored = true
	anchor.CFrame = CFrame.new(pivot.Position + Vector3.new(0, 3, 0))
	anchor.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(4, 2)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 120
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = tostring(math.floor(amount + 0.5))
	label.TextColor3 = opts.colour or Color3.fromRGB(255, 190, 120)
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = billboard

	local risen = 0
	Timer.each(function(delta)
		risen += delta
		local t = math.min(risen / 0.7, 1)
		anchor.CFrame = anchor.CFrame + Vector3.new(0, delta * 5, 0)
		label.TextTransparency = Curve.ease("quadIn", t)
		label.TextStrokeTransparency = 0.4 + 0.6 * t
		return t >= 1
	end, "damage.number")
	Debris:AddItem(anchor, 1.2)

	-- A flash on the body itself, so the hit reads even off-screen of the number.
	local highlight = target:FindFirstChildOfClass("Highlight")
	if highlight == nil then
		highlight = Instance.new("Highlight")
		highlight.FillColor = Color3.fromRGB(255, 120, 100)
		highlight.FillTransparency = 0.55
		highlight.OutlineTransparency = 1
		highlight.Parent = target
		Debris:AddItem(highlight, 0.18)
	end
end

--- Give something the ability to swing.
---
--- Returns a handle with `attack`, so a key, a prompt, an AI or a test can all
--- drive it the same way.
function Combat.attacker(model: Model, weapon: Weapon?, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local hit, missed = Signal.new("attack.hit"), Signal.new("attack.missed")
	trove:add(hit)
	trove:add(missed)

	local kit: Weapon = {
		name = (weapon and weapon.name) or DEFAULT.name,
		damage = (weapon and weapon.damage) or DEFAULT.damage,
		reach = (weapon and weapon.reach) or DEFAULT.reach,
		width = (weapon and weapon.width) or DEFAULT.width,
		cooldown = (weapon and weapon.cooldown) or DEFAULT.cooldown,
		knockback = (weapon and weapon.knockback) or DEFAULT.knockback,
		backstab = (weapon and weapon.backstab) or DEFAULT.backstab,
	}
	local ready = Timer.cooldown(kit.cooldown :: number)

	local function attack(): number
		if not ready() then
			return 0
		end
		if model.Parent == nil then
			return 0
		end

		local targets = Combat.inFront(model, kit.reach :: number, kit.width :: number)
		-- Filter by side *after* finding them, so a swing that touched only
		-- allies still reports as a swing rather than as nothing happening.
		local landed = 0
		for _, target in ipairs(targets) do
			if opts.hostileTo ~= nil and not opts.hostileTo(target) then
				continue
			end

			local amount = kit.damage :: number
			-- Behind counts for more. The one rule that makes positioning
			-- matter at all in a simple melee system.
			local facing = model:GetPivot().LookVector
			local theirs = target:GetPivot().LookVector
			if facing:Dot(theirs) > 0.4 then
				amount *= (kit.backstab :: number)
			end

			Actions.damage(target, amount)
			Combat.acknowledge(target, amount)
			if (kit.knockback :: number) > 0 then
				local away = target:GetPivot().Position - model:GetPivot().Position
				if away.Magnitude > 0.1 then
					Actions.push(target, away.Unit * (kit.knockback :: number))
				end
			end
			landed += 1
			hit:fire(target, amount)
		end

		if landed == 0 then
			missed:fire()
		end
		if opts.onSwing ~= nil then
			pcall(opts.onSwing, landed)
		end
		return landed
	end

	return {
		hit = hit,
		missed = missed,
		attack = attack,
		weapon = kit,
		retarget = function(other: Weapon)
			for key, value in pairs(other) do
				(kit :: any)[key] = value
			end
			ready = Timer.cooldown(kit.cooldown :: number)
		end,
		destroy = function() trove:clean() end,
	}
end

--- An enemy that closes the distance and swings when it is near enough.
---
--- Built on `Life.guard` for the approach and `Combat.attacker` for the swing,
--- which is the whole point of having both.
function Combat.enemy(model: Model, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local Life = require(script.Parent.Life)

	local health = Life.health(model, tonumber(opts.health) or 60, {
		destroyOnDeath = opts.destroyOnDeath ~= false,
		linger = tonumber(opts.linger) or 1.5,
	})
	trove:add(health)

	local swing = Combat.attacker(model, opts.weapon, {
		-- Enemies hit players and nothing else. Without this they beat each
		-- other to death in the spawn pile, which reads as the AI being broken.
		hostileTo = function(target: Instance): boolean
			return Players:GetPlayerFromCharacter(target) ~= nil
		end,
	})
	trove:add(swing)

	local guard = Life.guard(model, {
		sight = tonumber(opts.sight) or 70,
		chaseSpeed = tonumber(opts.speed) or 12,
		giveUp = tonumber(opts.giveUp) or 7,
		gait = opts.gait or "menace",
		post = opts.post,
		route = opts.route,
	})
	trove:add(guard)

	local reach = tonumber(opts.reach) or 8
	trove:add(Timer.every(0.3, function()
		if model.Parent == nil or not health.isAlive() then
			trove:clean()
			return
		end
		local target = Spatial.nearestPlayer(model:GetPivot().Position, reach)
		if target ~= nil then
			swing.attack()
		end
	end, "enemy.swing"), "cancel")

	health.died:connect(function()
		if opts.drops ~= nil then
			pcall(opts.drops, model:GetPivot().Position)
		end
		if opts.experience ~= nil then
			for _, player in ipairs(Players:GetPlayers()) do
				Actions.add(player, "Experience", tonumber(opts.experience) or 10)
			end
		end
	end)

	return {
		health = health,
		swing = swing,
		guard = guard,
		destroy = function() trove:clean() end,
	}
end

--- Levels, from experience, on a curve you can read before shipping it.
function Combat.progression(options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local levelled = Signal.new("levelled")
	trove:add(levelled)

	local base = tonumber(opts.base) or 100
	local ratio = tonumber(opts.ratio) or 1.4

	local function needed(level: number): number
		return math.floor(Curve.geometric(base, ratio, level))
	end

	trove:add(Events.onPlayer(function(player)
		Actions.set(player, "Level", Actions.get(player, "Level", 1))
		Actions.set(player, "Experience", Actions.get(player, "Experience", 0))
	end))

	trove:add(Timer.every(1, function()
		for _, player in ipairs(Players:GetPlayers()) do
			local level = Actions.get(player, "Level", 1) :: number
			local experience = Actions.get(player, "Experience", 0) :: number
			local bar = needed(level)
			if experience >= bar then
				Actions.set(player, "Experience", experience - bar)
				Actions.set(player, "Level", level + 1)
				Actions.notify(player, ("Level %d"):format(level + 1))
				levelled:fire(player, level + 1)
			end
		end
	end, "progression"), "cancel")

	return {
		levelled = levelled,
		needed = needed,
		ladder = function(levels: number): { number }
			local out = {}
			for level = 1, levels do
				table.insert(out, needed(level))
			end
			return out
		end,
		destroy = function() trove:clean() end,
	}
end

return Combat
