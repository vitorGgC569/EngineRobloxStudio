--[[
	RollService — the summon loop: charge, draw, persist, reveal.

	The client asks for a batch and nothing else. Every cost and every outcome
	is decided here from Content through PlayerStore, because a price that
	arrives over the wire is a price somebody will eventually edit (Wire.lua
	says the same thing). The payload contributes a batch size, a card id, a
	slot number or a boolean — each one re-validated below.

	Draws run on a per-player seeded Rng stream, never the global RNG, so any
	reveal can be replayed from the same seed and stream name.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))

--: Net.on errors for a channel this VM never defined, and nothing in the
--: server bootstrap is guaranteed to have required Wire before systems start.
require(Shared:WaitForChild("Wire"))

local PlayerStore = require(script.Parent.PlayerStore)

local Net = Forge.Net
local Rng = Forge.Core.Rng
local Telemetry = Forge.Telemetry
local CrateRoll = Forge.Progression.CrateRoll
local Luck = Forge.LiveOps.Luck

local RollService = {}

--: The only batch sizes that exist. Re-checked in performRoll so a direct
--: caller cannot sidestep it, and 1.5 or "5" off the wire dies before any
--: charge: a rejected draw must be free, not partially paid for.
local function isBatchSize(count)
	return type(count) == "number" and (count == 1 or count == 5 or count == 20)
end

--: CrateRoll calls its rng as a plain function and a Stream is a table with
--: methods — passing the stream itself throws the first time somebody
--: summons. The stream is cached by name, so each player keeps one
--: deterministic sequence across batches.
local function rollStream(player)
	local stream = Rng.stream("aurarift.roll." .. player.UserId)
	return function()
		return stream:number()
	end
end

--: The pool a draw comes from. A gem summon is a guaranteed Legendary+ draw,
--: so the filter runs before the crate is built — a crate still holding
--: Commons would need a special case inside every roll. Pity stays live in
--: both beds: every gem drop outranks the pity floor, so a gem draw resets an
--: unlucky streak instead of extending it.
local function buildCrate(state, source)
	if source == "gem" then
		local drops = {}
		for _, drop in Content.drops() do
			if drop.rarity >= Content.roll.gemRollMinRarity then
				table.insert(drops, drop)
			end
		end
		return CrateRoll.new({
			drops = drops,
			pityThreshold = Content.roll.pityThreshold,
			minRarityForPity = Content.roll.pityMinRarity,
		})
	end
	return CrateRoll.new({
		drops = Luck.apply(Content.drops(), PlayerStore.luckMultiplier(state), Content.roll.pityMinRarity),
		pityThreshold = Content.roll.pityThreshold,
		minRarityForPity = Content.roll.pityMinRarity,
	})
end

--[[
	One charge, one crate, `count` draws. Answers whether anything happened.

	`source` picks the currency and the table: rift pays through PlayerStore
	(which owns the free-first-roll and the marginal price curve), gem pays
	gems for a guaranteed Legendary+, auto is the 1 Hz loop landing here.
]]
function RollService.performRoll(player, count, source)
	local state = PlayerStore.forPlayer(player)
	if state == nil then
		return false
	end
	if not isBatchSize(count) then
		return false
	end
	if source ~= "gem" and source ~= "auto" then
		source = "rift"
	end
	--: The upgrade is the gate. A player who never bought x5 cannot reach it
	--: through any path, including a hand-written packet — so the Notify here
	--: is one a human can actually cause.
	if count == 5 and (state.upgrades.batch5 or 0) < 1 then
		PlayerStore.notify(player, "Upgrade to x5 Summon first")
		return false
	end
	if count == 20 and (state.upgrades.batch20 or 0) < 1 then
		PlayerStore.notify(player, "Upgrade to x20 Summon first")
		return false
	end

	local cost
	if source == "gem" then
		cost = Content.roll.gemRollCost * count
		if not state.wallet:canAfford({ gems = cost }) then
			PlayerStore.notify(player, "Not enough Gems")
			return false
		end
		state.wallet:debit({ gems = cost })
	else
		cost = PlayerStore.rollCostFor(state, count)
		if not PlayerStore.payRift(state, cost) then
			PlayerStore.notify(player, "Not enough Rift")
			return false
		end
	end

	local crate = buildCrate(state, source)
	--: The pity counter lives on the profile, not on the crate: a crate built
	--: fresh per action would restart every player at zero pity forever.
	crate.pityCounter = state.pity
	local rng = rollStream(player)

	local results = {}
	for _ = 1, count do
		local drop = crate:roll(rng)
		local isNew, dupes = PlayerStore.addCard(state, drop.id)
		if isNew then
			PlayerStore.autoEquip(state, drop.id)
		end
		table.insert(results, {
			id = drop.id,
			name = Content.card(drop.id).name,
			rarity = drop.rarity,
			isNew = isNew,
			dupes = dupes,
		})
	end
	state.pity = crate.pityCounter
	state.rolls += count
	PlayerStore.write(state)

	--: The reveal is its own message, not a field on StateSync: a draw folded
	--: into a state broadcast reads as a number changing, and a number
	--: changing is not why anybody presses summon again.
	Net.fire(player, "Rolled", {
		results = results,
		batch = count,
		free = (cost == 0),
		gem = (source == "gem"),
	})
	PlayerStore.push(player)
	Telemetry.event("summon", { count = count, source = source })

	for _, result in results do
		if result.rarity >= Content.roll.announceRarity then
			PlayerStore.announce({
				name = player.DisplayName,
				userId = player.UserId,
				cardId = result.id,
				cardName = result.name,
				rarity = result.rarity,
			})
		end
	end
	return true
end

--[[
	The 1 Hz hook, called by the economy loop.

	Silent when broke: the HUD already says why nothing is happening, and a
	Notify here would fire once a second at every idle player. autoNextAt is
	rewritten on every path so a failed attempt retries on the cadence rather
	than on every tick.
]]
function RollService.tickAuto(state, now)
	if not state.autoRoll then
		return
	end
	--: Never summon mid-fight: the tower resolves against the loadout that
	--: entered it, and a draw changing power halfway through is a different
	--: fight than the one the player accepted.
	if state.battle ~= nil then
		return
	end
	if now < (state.autoNextAt or 0) then
		return
	end
	local cost = PlayerStore.rollCostFor(state, 1)
	if cost > 0 and not state.wallet:canAfford({ rift = cost }) then
		state.autoNextAt = now + 1.2
		return
	end
	RollService.performRoll(state.player, 1, "auto")
	state.autoNextAt = now + 1.2
end

--: The wire hands handlers a shape-checked payload; this narrows it to the
--: three batch sizes performRoll accepts before anything downstream sees it.
local function forwardBatch(player, payload, source)
	local count = payload and payload.count or 1
	if not isBatchSize(count) then
		return
	end
	RollService.performRoll(player, count, source)
end

local function validSlot(slot)
	return type(slot) == "number" and slot == math.floor(slot) and slot >= 1 and slot <= 3
end

function RollService.start()
	Net.on("Roll", function(player, payload)
		forwardBatch(player, payload, "rift")
	end)

	Net.on("GemRoll", function(player, payload)
		forwardBatch(player, payload, "gem")
	end)

	Net.on("Equip", function(player, payload)
		local state = PlayerStore.forPlayer(player)
		if state == nil then
			return
		end
		local cardId = payload.card
		local slot = payload.slot
		if type(cardId) ~= "string" or not validSlot(slot) then
			return
		end
		--: A slot the player has not unlocked is not a slot. The client is
		--: told how many exist, but the server is what decides.
		if slot > Content.equippedSlotsFor(state.bestFloor, state.life) then
			return
		end
		if (state.collection[cardId] or 0) <= 0 then
			return
		end

		local from = nil
		for index = 1, 3 do
			if state.equipped[index] == cardId then
				from = index
				break
			end
		end
		if from ~= nil and from ~= slot then
			--: Swap, never overwrite: the card being displaced keeps the slot
			--: the moved card came from, so aiming one card never silently
			--: unequips another.
			local displaced = state.equipped[slot]
			state.equipped[slot] = cardId
			state.equipped[from] = displaced
		else
			state.equipped[slot] = cardId
		end
		PlayerStore.recompute(state)
		PlayerStore.write(state)
		PlayerStore.push(player)
	end)

	Net.on("Unequip", function(player, payload)
		local state = PlayerStore.forPlayer(player)
		if state == nil then
			return
		end
		if not validSlot(payload.slot) then
			return
		end
		state.equipped[payload.slot] = ""
		PlayerStore.recompute(state)
		PlayerStore.write(state)
		PlayerStore.push(player)
	end)

	Net.on("SetAuto", function(player, payload)
		local state = PlayerStore.forPlayer(player)
		if state == nil then
			return
		end
		--: Auto summon is a purchase, and this is the only place that trusts
		--: the purchase flag rather than the client's claim about it.
		if (state.upgrades.autoroll or 0) < 1 then
			PlayerStore.notify(player, "Buy Auto Summon in the Dojo")
			return
		end
		state.autoRoll = payload.on == true
		PlayerStore.write(state)
		PlayerStore.push(player)
	end)
end

return RollService
