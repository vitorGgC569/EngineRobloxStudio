--!strict
--[[
	Rewards — the daily calendar, server-side and authoritative.

	This exists to make one loop real end to end, because a system verified
	only at its own function call is a system nobody has watched work:

		player joins -> HUD -> a claim is available -> panel -> Claim
		  -> server checks the calendar -> grants cash -> attribute changes
		  -> HUD number moves -> a notice is sent -> the profile is written

	Every step above is a place it can break, and only two of them are inside
	`DailyRewardCalendar`. The interesting failures live in the joins.

	Two things the client is not trusted with
	-----------------------------------------

	**Whether a reward is owed.** `dailyClaim` carries no payload. The streak,
	the day and the amount are all read from the profile the server holds; a
	claim that is not due is refused with a reason, not silently ignored,
	because a button that does nothing is indistinguishable from a bug.

	**How much it is worth.** The table below is the only source of the number.

	Persistence, which was defined and dead
	---------------------------------------

	`Gameplay.systems.save` was declared with a template and never loaded from,
	written to, or saved. Nothing noticed, because nothing asked it for
	anything. A daily streak is the first thing here that is meaningless
	without persistence -- a streak that resets when the server does is not a
	streak -- so this loads a profile on join and writes on claim and on leave.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Wire = require(ReplicatedStorage.Shared.Wire)

local DailyRewardCalendar = Forge.Progression.DailyRewardCalendar

local Rewards = {}

--[[
	What each day of the cycle pays.

	Rising, with the seventh a visible jump. A calendar whose days are all
	worth the same gives a player no reason to come back tomorrow rather than
	next week, which is the only thing a login streak is for.
]]
local CYCLE = {
	[1] = { cash = 150, label = "Day 1" },
	[2] = { cash = 250, label = "Day 2" },
	[3] = { cash = 400, label = "Day 3" },
	[4] = { cash = 600, label = "Day 4" },
	[5] = { cash = 900, label = "Day 5" },
	[6] = { cash = 1400, label = "Day 6" },
	[7] = { cash = 3000, label = "Day 7" },
}
local CYCLE_LENGTH = 7

local calendar = DailyRewardCalendar.new({
	milestones = CYCLE,
	cycleLength = CYCLE_LENGTH,
})

local systems: any = nil

--: In-memory mirror of what the profile holds, keyed by player. The profile is
--: the record; this is what the hot path reads so a claim does not wait on a
--: DataStore round trip to decide whether a button was legal.
local state: { [Player]: any } = {}

local function blank(): any
	return { lastClaimDay = nil, streak = 0 }
end

local function profileOf(player: Player): any
	if not systems or not systems.save then
		return nil
	end
	return systems.save:get(player)
end

local function load(player: Player)
	state[player] = blank()
	if not systems or not systems.save then
		return
	end
	local profile = systems.save:load(player)
	if not profile then
		--: A profile that would not load is not an empty profile. Claiming
		--: against `blank()` here would hand a returning player day one and
		--: overwrite a real streak on the next save.
		state[player] = nil
		Forge.Debug.warn("rewards: no profile for " .. player.Name
			.. "; daily disabled for this session")
		return
	end
	local stored = profile.data.daily
	if type(stored) == "table" then
		state[player] = {
			lastClaimDay = tonumber(stored.lastClaimDay),
			streak = tonumber(stored.streak) or 0,
		}
	end
	Rewards.publish(player)
end

local function persist(player: Player)
	local profile = profileOf(player)
	if not profile then
		return false
	end
	profile.data.daily = state[player]
	return systems.save:save(player)
end

--[[
	What the client is allowed to know, and what the HUD badges from.

	Published as an attribute rather than answered on request, because the HUD
	needs it the instant the player joins and a request costs a round trip
	before the first frame is drawn.
]]
function Rewards.publish(player: Player)
	local mine = state[player]
	if not mine then
		player:SetAttribute("dailyReady", false)
		return
	end
	--: Day arithmetic, not a trial `claim`. `claim` is pure and returns a new
	--: state rather than mutating, so calling it to *ask* would have worked --
	--: but a function named claim, called where nothing is being claimed, is
	--: one refactor away from consuming the streak on every HUD refresh.
	player:SetAttribute("dailyReady",
		mine.lastClaimDay ~= math.floor(os.time() / 86400))
	player:SetAttribute("dailyStreak", mine.streak)
end

function Rewards.snapshot(player: Player): any
	local mine = state[player]
	if not mine then
		return { available = false, streak = 0, cycle = CYCLE,
			cycleLength = CYCLE_LENGTH, reason = "profile unavailable" }
	end
	local today = math.floor(os.time() / 86400)
	local available = mine.lastClaimDay ~= today
	local nextStreak = if mine.lastClaimDay == today - 1 then mine.streak + 1 else 1
	return {
		available = available,
		streak = mine.streak,
		nextStreak = nextStreak,
		nextDay = ((nextStreak - 1) % CYCLE_LENGTH) + 1,
		cycle = CYCLE,
		cycleLength = CYCLE_LENGTH,
	}
end

--[[
	The claim. Refuses with a reason rather than returning nothing.

	A refusal the UI can print is the difference between "the button is broken"
	and "you already claimed today", and those look identical from the client
	when the answer is `nil`.
]]
function Rewards.claim(player: Player): any
	local mine = state[player]
	if not mine then
		return { ok = false, reason = "Your save could not be loaded." }
	end

	local today = math.floor(os.time() / 86400)
	if mine.lastClaimDay == today then
		return { ok = false, reason = "Already claimed today. Come back tomorrow." }
	end

	local updated, reward, info = calendar:claim(mine, os.time())
	state[player] = updated

	local payout = 0
	if type(reward) == "table" and tonumber(reward.cash) then
		payout = tonumber(reward.cash) or 0
	end

	if payout > 0 and systems and systems.economy then
		local balance = systems.economy:grant(player, "cash", payout, "daily")
		--: The attribute is what the HUD reads. Setting it here rather than
		--: waiting for the income tick is what makes the number move on the
		--: same frame the button was pressed.
		player:SetAttribute("cash", balance)
	end

	persist(player)
	Rewards.publish(player)

	local day = info and info.cycleDay or 1
	Forge.Net.fire(player, "notice", {
		kind = "daily",
		text = string.format("Day %d streak — +%d cash", updated.streak, payout),
	})

	return {
		ok = true,
		payout = payout,
		streak = updated.streak,
		day = day,
	}
end

function Rewards.start(gameplay: any)
	--: `Gameplay.systems` is a *function*, not a field. `gameplay.systems or
	--: gameplay` read as a sensible fallback and was not one: a function is
	--: truthy, so `systems` became the getter itself and every use of it threw
	--: "attempt to index function with 'save'" -- inside a `task.spawn`, which
	--: meant the server kept running and the daily calendar was simply absent.
	systems = if type(gameplay.systems) == "function"
		then gameplay.systems()
		else gameplay.systems or gameplay

	Forge.Net.on("dailyState", function(player: Player)
		return Rewards.snapshot(player)
	end)

	Forge.Net.on("dailyClaim", function(player: Player)
		return Rewards.claim(player)
	end)

	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(load, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		--: Written before the profile is released, or a streak claimed in the
		--: last minute of a session is lost -- which is the failure a player
		--: notices and reports as "it forgot my progress".
		persist(player)
		state[player] = nil
	end)

	Forge.Debug.probe("rewards", function()
		local live = 0
		for _ in state do
			live += 1
		end
		return { tracked = live, cycleLength = CYCLE_LENGTH }
	end)

	return Rewards
end

return Rewards
