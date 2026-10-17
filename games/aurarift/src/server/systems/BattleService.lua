--[[
	BattleService — the tower fight: one floor, one HP pool, one clock.

	A player's DPS is `state.power` — the sum of their equipped auras, owned
	by PlayerStore. This service adds the three things that make a fight a
	fight: the floor's HP pool, the 20-second window, and a win/lose decision
	that pays out once, from the server.

	The client's entire input surface is an optional floor number. It never
	sends power, damage or a payout: a client that could name its damage is a
	client that clears every floor.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage.Shared.Content)
local Format = require(ReplicatedStorage.Shared.Format)
local PlayerStore = require(script.Parent.PlayerStore)

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Telemetry = Forge.Telemetry

local BattleService = {}

-- ================================ payload ==================================

--[[
	The one Battle shape the client ever receives.

	Flat by contract, and every field a number, a string or a boolean on
	purpose: the client is a renderer. A payload carrying a wallet or a
	BigNumber is a payload the client can disagree with the server about.
]]
function BattleService.payload(state)
	local battle = state.battle
	local floor = battle and battle.floor or 0
	return {
		active = battle ~= nil,
		floor = floor,
		progress = battle and math.clamp(battle.progress, 0, 1) or 0,
		timeLeft = battle and math.max(0, battle.timeLeft) or 0,
		phase = battle and battle.phase or "idle",
		reward = battle and battle.rewardText or nil,
		firstClear = battle and battle.firstClear or nil,
		boss = Content.isBoss(floor),
		nextFloor = state.bestFloor + 1,
		maxFloor = state.bestFloor,
	}
end

-- ================================= start ===================================

function BattleService.start()
	Net.on("BattleStart", function(player, payload)
		local state = PlayerStore.forPlayer(player)
		if state == nil then
			return
		end

		--: One fight at a time. A second start would overwrite a live fight
		--: mid-way, and the old floor's HP with it.
		if state.battle ~= nil then
			return
		end

		local floor = payload and payload.floor or nil
		if floor == nil then
			--: The default is the only forward step: the next floor.
			floor = state.bestFloor + 1
		else
			--[[
				A named floor is a replay, and it is checked against the
				server's own bestFloor — never trusted. The window is the
				replayWindow floors behind the best plus the next one: enough
				to refarm a boss, not enough to skip the ladder.
			]]
			local lowest = math.max(1, state.bestFloor - Content.battle.replayWindow)
			local highest = state.bestFloor + 1
			if floor % 1 ~= 0 or floor < lowest or floor > highest then
				PlayerStore.notify(player, "That floor is out of range")
				return
			end
		end

		state.battle = {
			floor = floor,
			hp = Content.floorHp(floor),
			progress = 0,
			timeLeft = Content.battle.timeLimit,
			phase = "fight",
			phaseUntil = nil,
		}
		Net.fire(player, "Battle", BattleService.payload(state))
		Telemetry.event("battle_start", { floor = floor })
	end)

	Net.on("BattleStop", function(player)
		local state = PlayerStore.forPlayer(player)
		if state == nil then
			return
		end
		if state.battle ~= nil and state.battle.phase == "fight" then
			--: Walking away forfeits the fight. Rewards are paid only by the
			--: win branch in tick, so there is nothing to claw back — but the
			--: client has to be told, and active = false is how it closes.
			state.battle = nil
			Net.fire(player, "Battle", BattleService.payload(state))
			PlayerStore.push(player)
		end
	end)

	--[[
		One heartbeat for the whole server, not one per player: fights share a
		clock, and a loop per player is a loop per player to leak.

		The wait is the loop's first statement. A `while true do` that does
		anything before yielding is the shortest way to hang the server it
		runs on.
	]]
	task.spawn(function()
		while true do
			task.wait(0.25)
			BattleService.tick(0.25)
		end
	end)
end

-- ================================== tick ===================================

--[[
	One step of every live fight, called at 4 Hz by the loop above. Nothing in
	here reads the wire: a client's only influence on a fight was the floor it
	asked for, and that was range-checked before the fight ever existed.
]]
function BattleService.tick(dt)
	PlayerStore.forEach(function(state)
		local battle = state.battle
		if battle == nil then
			return
		end

		if battle.phase == "fight" then
			--[[
				Crit jitter. Without it every fight is a bar filling at exactly
				the player's power, and a win is arithmetic arriving on time;
				with it the bar surges and stalls and the last second is a
				moment. One draw per player per tick from a named stream — the
				stream is seeded, so the same fight replays the same way.
			]]
			local rng = Rng.stream("aurarift.battle." .. state.player.UserId)
			local factor = 1 + (rng:number() * 2 - 1) * Content.battle.critVariance

			battle.progress += (state.power * factor * dt) / battle.hp
			battle.timeLeft -= dt

			if battle.progress >= 1 then
				battle.progress = 1
				battle.phase = "won"
				--[[
					The result window: the finished fight stays in state for
					2.5s so the client can play its win moment before the panel
					resets. Clearing immediately would flash the result off the
					screen in the same frame it landed.
				]]
				battle.phaseUntil = os.clock() + 2.5

				local firstClear = battle.floor > state.bestFloor
				local reward = Content.floorReward(battle.floor, firstClear)
				local gems = Content.floorGems(battle.floor)
				PlayerStore.creditRift(state, reward)
				if gems > 0 then
					PlayerStore.creditGems(state, gems)
				end
				if firstClear then
					state.bestFloor = battle.floor
				end

				--: The formatted payout travels with the payload; the client
				--: never formats a number the server owns.
				battle.rewardText = Format.abbrev(reward)
				battle.firstClear = firstClear

				PlayerStore.write(state)
				PlayerStore.push(state.player)
				Net.fire(state.player, "Battle", BattleService.payload(state))
				Telemetry.event("battle_win", { floor = battle.floor, firstClear = firstClear })
			elseif battle.timeLeft <= 0 then
				battle.timeLeft = 0
				battle.phase = "lost"
				--: The same result window as a win, for the same reason: the
				--: loss is a moment too, not a silent panel swap.
				battle.phaseUntil = os.clock() + 2.5
				Net.fire(state.player, "Battle", BattleService.payload(state))
				Telemetry.event("battle_lose", { floor = battle.floor })
			else
				--: The fight is live: this is the 4 Hz progress bar the client
				--: draws. Tick is already 4 Hz, so every tick is one update.
				Net.fire(state.player, "Battle", BattleService.payload(state))
			end
		elseif battle.phaseUntil ~= nil and os.clock() >= battle.phaseUntil then
			--[[
				Build the final payload while the fight is still in state, then
				clear it and send it with active = false: the client closes the
				panel holding the result (phase, floor, reward) instead of an
				idle reset it cannot tell apart from a disconnect.
			]]
			local result = BattleService.payload(state)
			state.battle = nil
			result.active = false
			Net.fire(state.player, "Battle", result)
			PlayerStore.push(state.player)
		end
	end)
end

return BattleService
