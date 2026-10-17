--!strict
--- Things a world does: doors, lifts, platforms, hazards, day and night.
---
--- Each one attaches to geometry that already exists and returns a handle with
--- `destroy`. They are **written to be read and copied** — if a door needs to
--- behave differently, the honest move is to take this one and change it, not
--- to add a fourteenth option to the table.
---
--- Every one owns a `Trove`, so destroying the handle really does disconnect
--- everything it made.

local Core = require(script.Parent.Parent.Core)
local Events, Actions = Core.Events, Core.Actions
local Trove, Timer, Curve = Core.Trove, Core.Timer, Core.Curve
local StateMachine, Zone = Core.StateMachine, Core.Zone

local World = {}

-- -- doors -----------------------------------------------------------------------

--- A door that opens. Swing, slide, or lift.
---
--- `by` decides how it is triggered: "prompt", "click", "touch", or "none" for
--- a door you drive yourself with `handle.open()`.
function World.door(leaf: BasePart, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local closed = leaf.CFrame
	local style = opts.style or "swing"

	local opened = if style == "slide" then
			closed * CFrame.new(tonumber(opts.distance) or leaf.Size.X, 0, 0)
		elseif style == "lift" then
			closed * CFrame.new(0, tonumber(opts.distance) or leaf.Size.Y, 0)
		else
			-- Swing about the hinge edge, not the centre. A door rotated about
			-- its middle sweeps through the wall it is set into, which is the
			-- classic first attempt.
			closed * CFrame.new(-leaf.Size.X * 0.5, 0, 0)
				* CFrame.Angles(0, math.rad(tonumber(opts.angle) or 95), 0)
				* CFrame.new(leaf.Size.X * 0.5, 0, 0)

	local seconds = tonumber(opts.seconds) or 0.6
	--[[
		Forward-declared, because the states below refer to it.

		`local machine = StateMachine.new({ ... machine:to("open") ... })` reads as
		if it works and does not: in Lua a `local` enters scope *after* its own
		statement, so every `machine` inside the table constructor resolved to a
		global, which is nil. The door opened, the tween finished, and the call
		that should have moved it to `open` was an index of nil -- so a door could
		be opened once and then never closed or reopened, and nothing in the
		transition table was ever reached.

		`luau-analyze` names this in one second ("Unknown global 'machine'"), and
		it went unseen because the authoring check was pointed at `games/` while
		`roblox/lib` was never analysed by anything.
	]]
	local machine
	machine = StateMachine.new({
		closed = { to = { "opening" } },
		opening = {
			to = { "open" },
			enter = function()
				Actions.sound(opts.openSound or "0", { at = leaf, volume = 0.4 })
				local elapsed = 0
				trove:add(Timer.each(function(delta)
					elapsed += delta
					local t = math.min(elapsed / seconds, 1)
					leaf.CFrame = closed:Lerp(opened, Curve.ease("quadOut", t))
					if t >= 1 then
						machine:to("open")
						return true
					end
					return false
				end, "door.open"), "cancel")
			end,
		},
		open = {
			to = { "closing" },
			enter = function()
				if opts.autoClose ~= nil then
					trove:add(Timer.after(tonumber(opts.autoClose) or 4, function()
						machine:to("closing")
					end), "cancel")
				end
			end,
		},
		closing = {
			to = { "closed" },
			enter = function()
				local elapsed = 0
				trove:add(Timer.each(function(delta)
					elapsed += delta
					local t = math.min(elapsed / seconds, 1)
					leaf.CFrame = opened:Lerp(closed, Curve.ease("quadIn", t))
					if t >= 1 then
						machine:to("closed")
						return true
					end
					return false
				end, "door.close"), "cancel")
			end,
		},
	}, "closed")

	local function toggle(player: Player?)
		if opts.key ~= nil and player ~= nil then
			-- A locked door that says nothing is indistinguishable from a
			-- broken one, so refusal is always announced.
			if Actions.get(player, opts.key, 0) == 0 then
				Actions.notify(player, opts.lockedMessage or "It is locked.")
				return
			end
		end
		if machine:is("closed") then
			machine:to("opening")
		elseif machine:is("open") then
			machine:to("closing")
		end
	end

	local by = opts.by or "prompt"
	if by == "prompt" then
		trove:add(Events.onPrompt(leaf, function(player)
			toggle(player)
		end, { label = opts.label or "Door", action = opts.action or "Open" }))
	elseif by == "click" then
		trove:add(Events.onClick(leaf, function(player)
			toggle(player)
		end))
	elseif by == "touch" then
		trove:add(Events.onTouch(leaf, function(_, player)
			toggle(player)
		end))
	end

	trove:add(machine)
	return {
		state = machine,
		open = function() machine:to("opening") end,
		close = function() machine:to("closing") end,
		toggle = toggle,
		isOpen = function() return machine:is("open") end,
		destroy = function() trove:clean() end,
	}
end

-- -- moving things --------------------------------------------------------------

--- A platform that goes back and forth between points, forever.
function World.platform(part: BasePart, waypoints: { Vector3 }, options: { [string]: any }?)
	local opts = options or {}
	if #waypoints < 2 then
		error("a moving platform needs at least two waypoints", 2)
	end
	local trove = Trove.new()
	local speed = tonumber(opts.speed) or 8
	local pause = tonumber(opts.pause) or 1

	local index, target = 1, 2
	local waiting = 0

	trove:add(Timer.each(function(delta)
		if waiting > 0 then
			waiting -= delta
			return false
		end
		local goal = waypoints[target]
		local toward = goal - part.Position
		local step = speed * delta
		if toward.Magnitude <= step then
			part.CFrame = CFrame.new(goal) * (part.CFrame - part.Position)
			index = target
			target = if opts.loop == true
				then (target % #waypoints) + 1
				else (if target >= #waypoints then #waypoints - 1
					elseif index >= #waypoints then target - 1 else target + 1)
			-- Ping-pong when not looping: at either end, reverse.
			if opts.loop ~= true then
				if index == #waypoints then
					target = #waypoints - 1
				elseif index == 1 then
					target = 2
				end
			end
			waiting = pause
		else
			-- Carrying riders is what `AssemblyLinearVelocity` on an anchored
			-- part does not do. Moving the CFrame is enough for a player
			-- standing on it because Roblox re-grounds them each step.
			part.CFrame = part.CFrame + toward.Unit * step
		end
		return false
	end, "platform"), "cancel")

	return {
		pause = function() waiting = math.huge end,
		resume = function() waiting = 0 end,
		destroy = function() trove:clean() end,
	}
end

--- A lift between two heights, called by a prompt at each end.
function World.elevator(car: BasePart, low: number, high: number, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local speed = tonumber(opts.speed) or 10
	local going = false

	local function travel(to: number)
		if going then
			return
		end
		going = true
		trove:add(Timer.each(function(delta)
			local gap = to - car.Position.Y
			local step = speed * delta
			if math.abs(gap) <= step then
				car.Position = Vector3.new(car.Position.X, to, car.Position.Z)
				going = false
				return true
			end
			car.Position += Vector3.new(0, math.sign(gap) * step, 0)
			return false
		end, "elevator"), "cancel")
	end

	trove:add(Events.onPrompt(car, function()
		travel(if car.Position.Y > (low + high) * 0.5 then low else high)
	end, { label = opts.label or "Lift", action = "Call" }))

	return {
		up = function() travel(high) end,
		down = function() travel(low) end,
		destroy = function() trove:clean() end,
	}
end

-- -- hazards -----------------------------------------------------------------------

--- Anything that hurts on contact.
function World.hazard(part: BasePart, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local damage = tonumber(opts.damage) or 100

	trove:add(Events.onTouch(part, function(character, player)
		if character == nil then
			return
		end
		Actions.damage(character, damage)
		if opts.knockback ~= nil and character.PrimaryPart ~= nil then
			local away = (character:GetPivot().Position - part.Position)
			if away.Magnitude > 0.1 then
				Actions.push(character, away.Unit * tonumber(opts.knockback))
			end
		end
		if player ~= nil and opts.message ~= nil then
			Actions.notify(player, opts.message)
		end
	end, { debounce = tonumber(opts.rate) or 0.5 }))

	return { destroy = function() trove:clean() end }
end

--- Fall below this and you are dead. Every obby needs one and forgetting it is
--- how a player ends up falling for ever.
function World.killPlane(height: number, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	trove:add(Timer.every(tonumber(opts.beat) or 0.5, function()
		for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
			local character = player.Character
			if character ~= nil then
				local ok, pivot = pcall(function()
					return character:GetPivot().Position
				end)
				if ok and pivot.Y < height then
					if opts.respawnTo ~= nil then
						Actions.teleport(character, opts.respawnTo)
					else
						Actions.kill(character)
					end
				end
			end
		end
	end, "killPlane"), "cancel")
	return { destroy = function() trove:clean() end }
end

-- -- atmosphere ---------------------------------------------------------------------

--- A day that passes. `minutes` is how long a full cycle takes.
function World.dayNight(minutes: number, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local lighting = game:GetService("Lighting")
	local perSecond = 24 / (minutes * 60)

	trove:add(Timer.each(function(delta)
		lighting.ClockTime = (lighting.ClockTime + perSecond * delta) % 24
		if opts.onHour ~= nil then
			opts.onHour(lighting.ClockTime)
		end
		return false
	end, "dayNight"), "cancel")

	return {
		setHour = function(hour: number) lighting.ClockTime = hour % 24 end,
		hour = function() return lighting.ClockTime end,
		destroy = function() trove:clean() end,
	}
end

return World
