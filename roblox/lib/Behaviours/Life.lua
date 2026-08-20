--!strict
--- Things that act: spawners, guards, turrets, health, teams.
---
--- Anything with intent, or anything that produces things with intent. Written
--- to be read: a spawner you disagree with is forty lines you can take and
--- rewrite, not a configuration puzzle.

local Players = game:GetService("Players")
local Teams = game:GetService("Teams")

local Core = require(script.Parent.Parent.Core)
local Events, Actions = Core.Events, Core.Actions
local Trove, Timer, Curve = Core.Trove, Core.Timer, Core.Curve
local Signal, Spatial, Pool = Core.Signal, Core.Spatial, Core.Pool

local Life = {}

-- -- health ---------------------------------------------------------------------

--- Health for something that is not a Humanoid.
---
--- `WorldKit.Threat` and most stylised enemies are anchored models with no
--- Humanoid, so `humanoid.Health` does not exist for them. This is the
--- attribute-based convention the rest of the engine reads.
function Life.health(subject: Instance, maximum: number, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local damaged, died = Signal.new("damaged"), Signal.new("died")
	trove:add(damaged)
	trove:add(died)

	Actions.set(subject, "MaxHealth", maximum)
	Actions.set(subject, "Health", maximum)
	local alive = true

	local function hurt(amount: number, source: any?)
		if not alive then
			return
		end
		local left = Actions.add(subject, "Health", -amount, { min = 0 })
		damaged:fire(amount, left, source)
		if left <= 0 then
			alive = false
			died:fire(source)
			if opts.destroyOnDeath ~= false then
				Actions.destroy(subject, tonumber(opts.linger) or 0.5)
			end
		end
	end

	return {
		damaged = damaged,
		died = died,
		hurt = hurt,
		heal = function(amount: number)
			if alive then
				Actions.add(subject, "Health", amount, { min = 0, max = maximum })
			end
		end,
		fraction = function(): number
			return (Actions.get(subject, "Health", 0) :: number) / math.max(maximum, 1)
		end,
		isAlive = function() return alive end,
		destroy = function() trove:clean() end,
	}
end

-- -- spawning -----------------------------------------------------------------------

--- Waves of things, on a budget.
---
--- The shape most games need and few get right: a wave has a size, waves get
--- harder, and there is a ceiling on how many exist at once so a stalled player
--- does not accumulate two hundred enemies.
function Life.spawner(make: (number) -> Instance?, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local waveStarted, waveCleared = Signal.new("wave.started"), Signal.new("wave.cleared")
	trove:add(waveStarted)
	trove:add(waveCleared)

	local wave = 0
	local alive: { Instance } = {}
	local cap = tonumber(opts.cap) or 40
	local running = false

	local function prune()
		for index = #alive, 1, -1 do
			if alive[index].Parent == nil then
				table.remove(alive, index)
			end
		end
	end

	local function startWave()
		wave += 1
		running = true
		local count = math.floor(Curve.geometric(
			tonumber(opts.first) or 4, tonumber(opts.growth) or 1.25, wave))
		waveStarted:fire(wave, count)

		local made = 0
		trove:add(Timer.every(tonumber(opts.gap) or 1.2, function()
			prune()
			if made >= count then
				return
			end
			if #alive >= cap then
				-- Not an error: the wave simply waits. A spawner that ignores
				-- its cap is how a place hits the part limit mid-session.
				return
			end
			made += 1
			local thing = make(wave)
			if thing ~= nil then
				table.insert(alive, thing)
			end
		end, "spawner.make"), "cancel")

		trove:add(Timer.every(1, function()
			prune()
			if running and made >= count and #alive == 0 then
				running = false
				waveCleared:fire(wave)
				if opts.autoNext ~= false then
					trove:add(Timer.after(tonumber(opts.between) or 6, startWave), "cancel")
				end
			end
		end, "spawner.watch"), "cancel")
	end

	return {
		waveStarted = waveStarted,
		waveCleared = waveCleared,
		start = startWave,
		wave = function() return wave end,
		alive = function() prune() return #alive end,
		clearAll = function()
			for _, thing in ipairs(alive) do
				thing:Destroy()
			end
			table.clear(alive)
		end,
		destroy = function() trove:clean() end,
	}
end

-- -- guards -----------------------------------------------------------------------------

--- Something that watches, chases when it sees you, and gives up when it loses
--- you. The commonest enemy in every genre.
function Life.guard(model: Model, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local GameKit = require(script.Parent.Parent.GameKit)

	local sightRange = tonumber(opts.sight) or 80
	local giveUp = tonumber(opts.giveUp) or 6
	local lostAt: number? = nil
	local chasing = false

	local function home()
		if opts.post ~= nil then
			GameKit.Pursuit.start(model, {
				mode = "patrol", speed = tonumber(opts.patrolSpeed) or 8,
				points = opts.route or { opts.post },
			})
		else
			GameKit.Pursuit.stop(model)
		end
	end

	trove:add(Timer.every(tonumber(opts.beat) or 0.4, function()
		if model.Parent == nil then
			trove:clean()
			return
		end
		local from = model:GetPivot().Position
		local target = Spatial.nearestPlayer(from, sightRange)
		local visible = target ~= nil
			and Spatial.sees(from, target:GetPivot().Position,
				{ caster = model, target = target })

		if visible then
			lostAt = nil
			if not chasing then
				chasing = true
				GameKit.Pursuit.start(model, {
					mode = "chase", speed = tonumber(opts.chaseSpeed) or 16,
				}, function()
					return Spatial.nearestPlayer(model:GetPivot().Position, sightRange * 1.5)
				end)
				GameKit.Motion.play(model, { gait = opts.gait or "walk", rate = 1.8 })
				if opts.onSpotted ~= nil then
					opts.onSpotted(target)
				end
			end
		elseif chasing then
			-- A guard that forgets the instant you break line of sight is
			-- trivial to beat; one that never forgets is unfair. The delay is
			-- the whole design.
			lostAt = lostAt or os.clock()
			if os.clock() - lostAt > giveUp then
				chasing = false
				lostAt = nil
				home()
				if opts.onLost ~= nil then
					opts.onLost()
				end
			end
		end
	end, "guard"), "cancel")

	home()
	return {
		isChasing = function() return chasing end,
		destroy = function()
			GameKit.Pursuit.stop(model)
			GameKit.Motion.stop(model)
			trove:clean()
		end,
	}
end

-- -- shooting ---------------------------------------------------------------------------------

--- A turret that fires at whatever comes into range.
function Life.turret(mount: BasePart, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local fired = Signal.new("turret.fired")
	trove:add(fired)

	local range = tonumber(opts.range) or 60
	local damage = tonumber(opts.damage) or 10
	local canFire = Timer.cooldown(tonumber(opts.reload) or 1.2)

	-- Pooled, because a turret firing every 1.2s for ten minutes is 500
	-- projectiles and the churn is the cost, not the geometry.
	local bolts = Pool.new(function()
		local bolt = Instance.new("Part")
		bolt.Size = opts.boltSize or Vector3.new(0.4, 0.4, 2)
		bolt.Color = opts.boltColour or Color3.fromRGB(255, 190, 90)
		bolt.Material = Enum.Material.Neon
		bolt.Anchored = true
		bolt.CanCollide = false
		bolt.Parent = workspace
		return bolt
	end, function(bolt: BasePart)
		bolt.Transparency = 0
		bolt.Parent = nil
	end, { parent = workspace })

	trove:add(function() bolts:clear() end)

	trove:add(Timer.every(tonumber(opts.beat) or 0.2, function()
		if mount.Parent == nil then
			trove:clean()
			return
		end
		local target = Spatial.nearestPlayer(mount.Position, range)
		if target == nil then
			return
		end
		local at = target:GetPivot().Position
		if not Spatial.sees(mount.Position, at, { caster = mount, target = target }) then
			return
		end
		if opts.face ~= false then
			mount.CFrame = CFrame.lookAt(mount.Position, at)
		end
		if not canFire() then
			return
		end

		local bolt = bolts:get()
		bolt.CFrame = CFrame.lookAt(mount.Position, at)
		local travelled = 0
		local distance = (at - mount.Position).Magnitude
		local speed = tonumber(opts.boltSpeed) or 120
		trove:add(Timer.each(function(delta)
			travelled += speed * delta
			if travelled >= distance or bolt.Parent == nil then
				bolts:give(bolt)
				return true
			end
			bolt.CFrame = bolt.CFrame + bolt.CFrame.LookVector * (speed * delta)
			return false
		end, "bolt"), "cancel")

		Actions.damage(target, damage)
		fired:fire(target, damage)
	end, "turret"), "cancel")

	return {
		fired = fired,
		destroy = function() trove:clean() end,
	}
end

-- -- sides ----------------------------------------------------------------------------------------

--- Teams that balance themselves as people join.
function Life.teams(declared: { { name: string, colour: string } })
	local trove = Trove.new()
	local seen: { [string]: boolean } = {}
	for _, entry in ipairs(declared) do
		local colour = BrickColor.new(entry.colour)
		if seen[colour.Name] then
			-- Roblox keys teams by BrickColor: a collision merges them and
			-- every player on the second lands on the first, silently.
			warn(("[teams] %s reuses colour %s; the teams would merge")
				:format(entry.name, colour.Name))
		end
		seen[colour.Name] = true
		local team = Instance.new("Team")
		team.Name = entry.name
		team.TeamColor = colour
		team.AutoAssignable = false
		team.Parent = Teams
		trove:add(team)
	end

	trove:add(Events.onPlayer(function(player)
		local smallest, fewest = nil, math.huge
		for _, team in ipairs(Teams:GetTeams()) do
			local size = #team:GetPlayers()
			if size < fewest then
				smallest, fewest = team, size
			end
		end
		if smallest ~= nil then
			player.Team = smallest
		end
	end))

	return {
		balance = function()
			local all = Players:GetPlayers()
			local teams = Teams:GetTeams()
			for index, player in ipairs(all) do
				player.Team = teams[((index - 1) % #teams) + 1]
			end
		end,
		destroy = function() trove:clean() end,
	}
end

return Life
