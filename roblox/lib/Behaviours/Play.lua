--!strict
--- Things a player does: pick up, unlock, respawn, buy, complete.
---
--- The loop pieces. Each attaches to geometry and returns a handle; each is
--- short enough to read in one sitting and is meant to be copied and changed
--- rather than configured into a corner.

local Players = game:GetService("Players")

local Core = require(script.Parent.Parent.Core)
local Events, Actions = Core.Events, Core.Actions
local Trove, Timer, Curve = Core.Trove, Core.Timer, Core.Curve
local Signal, Zone = Core.Signal, Core.Zone

local Play = {}

-- -- collecting -------------------------------------------------------------------

--- Something you walk into and gain. Respawns if told to.
function Play.pickup(part: BasePart, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local collected = Signal.new("pickup")
	trove:add(collected)

	local currency = opts.currency or "Coins"
	local amount = tonumber(opts.amount) or 1
	local respawn = tonumber(opts.respawn)
	local home = part.CFrame
	local available = true

	if opts.spin ~= false then
		trove:add(Timer.each(function(delta)
			if available then
				part.CFrame = part.CFrame * CFrame.Angles(0, delta * 2, 0)
			end
			return false
		end, "pickup.spin"), "cancel")
	end

	trove:add(Events.onTouch(part, function(character, player)
		if not available or player == nil then
			return
		end
		available = false
		Actions.add(player, currency, amount, { min = 0 })
		collected:fire(player, amount)
		if opts.sound ~= nil then
			Actions.sound(opts.sound, { at = part, volume = 0.4 })
		end

		if respawn == nil then
			part:Destroy()
			trove:clean()
			return
		end
		part.Transparency = 1
		part.CanCollide = false
		trove:add(Timer.after(respawn, function()
			part.Transparency = 0
			part.CFrame = home
			available = true
		end), "cancel")
	end, { debounce = 0.1 }))

	return {
		collected = collected,
		available = function() return available end,
		destroy = function() trove:clean() end,
	}
end

--- A container that gives once per player.
function Play.chest(part: BasePart, give: (Player) -> (), options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local opened: { [Player]: boolean } = {}

	trove:add(Events.onPrompt(part, function(player)
		if opened[player] then
			Actions.notify(player, opts.emptyMessage or "Already emptied.")
			return
		end
		opened[player] = true
		give(player)
		if opts.sound ~= nil then
			Actions.sound(opts.sound, { at = part, volume = 0.5 })
		end
		Actions.set(part, "OpenedBy", (Actions.get(part, "OpenedBy", 0) :: number) + 1)
	end, { label = opts.label or "Chest", action = opts.action or "Open",
		holdTime = tonumber(opts.holdTime) or 0.5 }))

	return {
		reset = function() table.clear(opened) end,
		destroy = function() trove:clean() end,
	}
end

-- -- switches -----------------------------------------------------------------------

--- A lever, button or plate. All the same idea with different triggers.
function Play.switch(part: BasePart, onFlip: (Player?, boolean) -> (), options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local on = opts.startOn == true
	local kind = opts.kind or "lever"

	local function flip(player: Player?, force: boolean?)
		local was = on
		on = if force ~= nil then force else not on
		if on ~= was then
			Actions.set(part, "On", on)
			onFlip(player, on)
		end
	end

	if kind == "plate" then
		local zone = Zone.new(part.Position + Vector3.new(0, part.Size.Y, 0),
			part.Size + Vector3.new(0, part.Size.Y * 2, 0), { ignore = { part } })
		trove:add(zone)
		zone.entered:connect(function(_, player)
			if zone:count() == 1 then
				flip(player, true)
			end
		end)
		zone.left:connect(function(_, player)
			if zone:count() == 0 then
				flip(player, false)
			end
		end)
	elseif kind == "button" then
		trove:add(Events.onPrompt(part, function(player)
			flip(player, true)
			-- A button springs back; a lever stays. Conflating them is why a
			-- door somewhere is stuck open.
			trove:add(Timer.after(tonumber(opts.springBack) or 0.5, function()
				flip(nil, false)
			end), "cancel")
		end, { label = opts.label or "Button", action = "Press" }))
	else
		trove:add(Events.onPrompt(part, function(player)
			flip(player)
		end, { label = opts.label or "Lever", action = "Pull" }))
	end

	Actions.set(part, "On", on)
	return {
		flip = flip,
		isOn = function() return on end,
		destroy = function() trove:clean() end,
	}
end

--- Several switches that together open one thing.
function Play.combination(switches: { any }, onComplete: () -> (), options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local satisfied = false

	local handle = Timer.every(tonumber(opts.beat) or 0.2, function()
		local all = true
		for _, item in ipairs(switches) do
			if not item.isOn() then
				all = false
				break
			end
		end
		if all and not satisfied then
			satisfied = true
			onComplete()
		elseif not all then
			satisfied = false
		end
	end, "combination")
	trove:add(handle, "cancel")

	return { destroy = function() trove:clean() end }
end

-- -- places to be ---------------------------------------------------------------------

--- Where you come back to. Remembers per player.
function Play.checkpoint(part: BasePart, options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local order = tonumber(opts.order) or 0
	local reached = Signal.new("checkpoint")
	trove:add(reached)

	trove:add(Events.onTouch(part, function(character, player)
		if player == nil then
			return
		end
		-- Never move a player backwards: touching an earlier checkpoint after
		-- a later one must not undo their progress.
		if (Actions.get(player, "CheckpointOrder", -1) :: number) >= order then
			return
		end
		Actions.set(player, "CheckpointOrder", order)
		Actions.set(player, "CheckpointX", part.Position.X)
		Actions.set(player, "CheckpointY", part.Position.Y + 4)
		Actions.set(player, "CheckpointZ", part.Position.Z)
		Actions.notify(player, opts.message or ("Checkpoint " .. order))
		reached:fire(player, order)
	end, { debounce = 1 }))

	return {
		reached = reached,
		destroy = function() trove:clean() end,
	}
end

--- Send everybody back to their last checkpoint when they die.
function Play.respawnAtCheckpoints()
	local trove = Trove.new()
	trove:add(Events.onCharacter(function(character, player)
		local x = Actions.get(player, "CheckpointX")
		if x == nil then
			return
		end
		task.defer(function()
			Actions.teleport(character, Vector3.new(
				x :: number,
				Actions.get(player, "CheckpointY", 4) :: number,
				Actions.get(player, "CheckpointZ", 0) :: number))
		end)
	end))
	return { destroy = function() trove:clean() end }
end

-- -- rounds and objectives ---------------------------------------------------------------

--- A round: intermission, play, results, repeat.
function Play.round(options: { [string]: any }?)
	local opts = options or {}
	local trove = Trove.new()
	local started, ended = Signal.new("round.started"), Signal.new("round.ended")
	trove:add(started)
	trove:add(ended)

	local playing = false
	local number = 0

	local function begin()
		number += 1
		playing = true
		started:fire(number)
		trove:add(Timer.after(tonumber(opts.length) or 180, function()
			if playing then
				playing = false
				ended:fire(number, "time")
			end
		end), "cancel")
	end

	local function loop()
		trove:add(Timer.after(tonumber(opts.intermission) or 15, function()
			begin()
		end), "cancel")
	end

	ended:connect(function()
		if opts.repeating ~= false then
			loop()
		end
	end)
	loop()

	return {
		started = started,
		ended = ended,
		finish = function(reason: string?)
			if playing then
				playing = false
				ended:fire(number, reason or "finished")
			end
		end,
		isPlaying = function() return playing end,
		number = function() return number end,
		destroy = function() trove:clean() end,
	}
end

--- Track a list of things that must be done.
function Play.objectives(list: { { id: string, text: string, count: number? } })
	local trove = Trove.new()
	local completed = Signal.new("objective")
	local allDone = Signal.new("objectives.done")
	trove:add(completed)
	trove:add(allDone)

	local progress: { [string]: number } = {}
	for _, entry in ipairs(list) do
		progress[entry.id] = 0
	end

	local function advance(id: string, by: number?)
		local entry
		for _, candidate in ipairs(list) do
			if candidate.id == id then
				entry = candidate
			end
		end
		if entry == nil then
			warn("[objectives] no objective " .. id)
			return
		end
		local target = entry.count or 1
		local was = progress[id]
		if was >= target then
			return
		end
		progress[id] = math.min(was + (by or 1), target)
		if progress[id] >= target then
			completed:fire(id, entry.text)
			for _, candidate in ipairs(list) do
				if progress[candidate.id] < (candidate.count or 1) then
					return
				end
			end
			allDone:fire()
		end
	end

	return {
		completed = completed,
		allDone = allDone,
		advance = advance,
		progress = function() return table.clone(progress) end,
		remaining = function(): { string }
			local left = {}
			for _, entry in ipairs(list) do
				if progress[entry.id] < (entry.count or 1) then
					table.insert(left, entry.text)
				end
			end
			return left
		end,
		destroy = function() trove:clean() end,
	}
end

-- -- shopping --------------------------------------------------------------------------------

--- A stand that sells things for an in-game currency.
function Play.shop(part: BasePart, stock: { { id: string, name: string, price: number,
	give: (Player) -> () } }, options: { [string]: any }?)

	local opts = options or {}
	local trove = Trove.new()
	local currency = opts.currency or "Coins"
	local sold = Signal.new("shop.sold")
	trove:add(sold)

	local function buy(player: Player, id: string): (boolean, string)
		for _, item in ipairs(stock) do
			if item.id == id then
				if not Actions.spend(player, currency, item.price) then
					return false, ("Not enough %s (%d needed)"):format(currency, item.price)
				end
				item.give(player)
				sold:fire(player, item.id, item.price)
				return true, item.name
			end
		end
		return false, "No such item"
	end

	trove:add(Events.onPrompt(part, function(player)
		-- Opening a shop is a UI concern; this records the intent so whatever
		-- screen exists can react, and works with no screen at all.
		Actions.set(player, "ShopOpen", part:GetFullName())
	end, { label = opts.label or "Shop", action = "Browse" }))

	return {
		sold = sold,
		buy = buy,
		stock = function() return stock end,
		destroy = function() trove:clean() end,
	}
end

return Play
