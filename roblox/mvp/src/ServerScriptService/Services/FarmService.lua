--!strict
-- The farm: slots, production, collection and selling.
--
-- One authority for the whole idle economy. Slot state, production ticks,
-- box counts and sales all live here so an agent can ask a single question --
-- "what is this farm worth right now" -- and get an answer that cannot
-- disagree with itself.
--
-- Production is computed from elapsed time rather than accumulated per frame:
-- a frame-counting loop drifts, cannot be resumed after a rejoin, and gives
-- offline earnings nothing to be derived from.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CardCatalog = require(ReplicatedStorage.Shared.CardCatalog)
local FarmCatalog = require(ReplicatedStorage.Shared.FarmCatalog)

local FarmService = {}
FarmService.__index = FarmService

export type SlotState = {
	index: number,
	plotName: string,
	unlocked: boolean,
	cardId: string?,
	rarity: string?,
	mutation: string,
	upgradeLevel: number,
	slottedAt: number,
	lastTickAt: number,
	boxes: number,
}

function FarmService.new()
	local self = setmetatable({}, FarmService)
	self.farms = {}
	--- Per-farm production multiplier, set from active potions. Held here so
	--- every rate calculation reads one number instead of each caller
	--- remembering to apply it.
	self.productionMultiplier = {}
	return self
end

function FarmService:setProductionMultiplier(plotName: string, multiplier: number)
	self.productionMultiplier[plotName] = math.max(0, multiplier or 1)
end

function FarmService:multiplierFor(plotName: string): number
	return self.productionMultiplier[plotName] or 1
end

local function now(): number
	return os.clock()
end

--- Create a farm's slots, or restore them from saved data.
function FarmService:ensure(plotName: string, saved: { any }?): { SlotState }
	if self.farms[plotName] then
		return self.farms[plotName]
	end

	local slots: { SlotState } = {}
	for index = 1, FarmCatalog.MaxSlots do
		local restored = saved and saved[index]
		slots[index] = {
			index = index,
			plotName = plotName,
			unlocked = if restored then restored.unlocked == true else index <= FarmCatalog.StartingSlots,
			cardId = restored and restored.cardId or nil,
			rarity = restored and restored.rarity or nil,
			mutation = restored and restored.mutation or "none",
			upgradeLevel = restored and restored.upgradeLevel or 1,
			slottedAt = now(),
			lastTickAt = now(),
			boxes = restored and restored.boxes or 0,
		}
	end

	self.farms[plotName] = slots
	return slots
end

function FarmService:slots(plotName: string): { SlotState }
	return self.farms[plotName] or self:ensure(plotName)
end

function FarmService:slot(plotName: string, index: number): SlotState?
	local slots = self:slots(plotName)
	return slots[index]
end

--- Is this card active yet, and how long until it is?
function FarmService:activation(slot: SlotState): (boolean, number)
	if slot.cardId == nil or slot.rarity == nil then
		return false, 0
	end
	local required = FarmCatalog.activationSeconds(slot.rarity)
	local elapsed = now() - slot.slottedAt
	if elapsed >= required then
		return true, 0
	end
	return false, required - elapsed
end

--- Advance one slot's production up to the present moment.
function FarmService:tickSlot(slot: SlotState): number
	if slot.cardId == nil or slot.rarity == nil or not slot.unlocked then
		slot.lastTickAt = now()
		return 0
	end

	local active, _remaining = self:activation(slot)
	if not active then
		slot.lastTickAt = now()
		return 0
	end

	local elapsed = now() - slot.lastTickAt
	if elapsed <= 0 then
		return 0
	end
	slot.lastTickAt = now()

	local rate = FarmCatalog.slotRate(slot.rarity, slot.mutation, slot.upgradeLevel) * self:multiplierFor(slot.plotName or "")
	local produced = rate * elapsed
	local room = FarmCatalog.SlotCapacity - slot.boxes
	local gained = math.max(0, math.min(produced, room))
	slot.boxes += gained
	return gained
end

function FarmService:tickFarm(plotName: string): number
	local total = 0
	for _, slot in ipairs(self:slots(plotName)) do
		total += self:tickSlot(slot)
	end
	return total
end

--- Place a card. Returns the slot used, or why it could not be placed.
function FarmService:place(plotName: string, cardId: string, rarity: string, mutation: string, slotIndex: number?)
	local slots = self:slots(plotName)

	local target: SlotState? = nil
	if slotIndex then
		local candidate = slots[slotIndex]
		if candidate == nil then
			return { ok = false, reason = "no_such_slot" }
		end
		if not candidate.unlocked then
			return { ok = false, reason = "slot_locked", slot = slotIndex }
		end
		if candidate.cardId ~= nil then
			return { ok = false, reason = "slot_occupied", slot = slotIndex }
		end
		target = candidate
	else
		for _, candidate in ipairs(slots) do
			if candidate.unlocked and candidate.cardId == nil then
				target = candidate
				break
			end
		end
	end

	if target == nil then
		return { ok = false, reason = "no_free_slot" }
	end

	target.cardId = cardId
	target.rarity = rarity
	target.mutation = mutation or "none"
	target.upgradeLevel = 1
	target.slottedAt = now()
	target.lastTickAt = now()

	return {
		ok = true,
		slot = target.index,
		activationSeconds = FarmCatalog.activationSeconds(rarity),
		rate = FarmCatalog.slotRate(rarity, target.mutation, 1),
		income = FarmCatalog.slotIncome(rarity, target.mutation, 1),
	}
end

--- Take a card out, freeing the slot. Any boxes it made are kept.
function FarmService:clear(plotName: string, slotIndex: number)
	local slot = self:slot(plotName, slotIndex)
	if slot == nil or slot.cardId == nil then
		return { ok = false, reason = "slot_empty" }
	end
	self:tickSlot(slot)
	local removed = slot.cardId
	slot.cardId = nil
	slot.rarity = nil
	slot.mutation = "none"
	return { ok = true, removed = removed, slot = slotIndex }
end

--- Collect every slot's boxes and turn them into cash.
function FarmService:sellAll(plotName: string)
	local slots = self:slots(plotName)
	local cash = 0
	local boxes = 0
	local byRarity: { [string]: number } = {}

	for _, slot in ipairs(slots) do
		self:tickSlot(slot)
		if slot.boxes > 0 and slot.rarity then
			local whole = math.floor(slot.boxes)
			if whole > 0 then
				cash += whole * FarmCatalog.boxValue(slot.rarity)
				boxes += whole
				byRarity[slot.rarity] = (byRarity[slot.rarity] or 0) + whole
				slot.boxes -= whole
			end
		end
	end

	return { ok = boxes > 0, cash = cash, boxes = boxes, byRarity = byRarity }
end

--- Buy the next slot.
function FarmService:unlockSlot(plotName: string, currency: number)
	local slots = self:slots(plotName)
	local nextIndex: number? = nil
	for _, slot in ipairs(slots) do
		if not slot.unlocked then
			nextIndex = slot.index
			break
		end
	end
	if nextIndex == nil then
		return { ok = false, reason = "all_slots_unlocked" }
	end

	local price = FarmCatalog.slotPrice(nextIndex)
	if currency < price then
		return { ok = false, reason = "insufficient_funds", price = price, slot = nextIndex }
	end

	slots[nextIndex].unlocked = true
	return { ok = true, slot = nextIndex, price = price }
end

--- What the farm is producing right now, for the HUD and for assertions.
function FarmService:summary(plotName: string)
	local slots = self:slots(plotName)
	local unlocked, filled, active, pending = 0, 0, 0, 0
	local boxes = 0
	local ratePerSecond = 0
	local cashPerSecond = 0
	local pendingValue = 0

	for _, slot in ipairs(slots) do
		self:tickSlot(slot)
		if slot.unlocked then
			unlocked += 1
		end
		if slot.cardId then
			filled += 1
			local isActive = (self:activation(slot))
			if isActive then
				active += 1
				ratePerSecond += FarmCatalog.slotRate(slot.rarity :: string, slot.mutation, slot.upgradeLevel)
				cashPerSecond += FarmCatalog.slotIncome(slot.rarity :: string, slot.mutation, slot.upgradeLevel)
			else
				pending += 1
			end
		end
		if slot.boxes > 0 and slot.rarity then
			boxes += slot.boxes
			pendingValue += slot.boxes * FarmCatalog.boxValue(slot.rarity)
		end
	end

	return {
		slots = #slots,
		unlockedSlots = unlocked,
		filledSlots = filled,
		activeSlots = active,
		warmingUp = pending,
		freeSlots = unlocked - filled,
		boxes = math.floor(boxes),
		pendingValue = math.floor(pendingValue),
		boxesPerSecond = math.round(ratePerSecond * 100) / 100,
		cashPerSecond = math.round(cashPerSecond * 100) / 100,
	}
end

--- Credit time spent away, from the same rate the live farm uses.
function FarmService:applyOffline(plotName: string, awaySeconds: number)
	if awaySeconds <= 0 then
		return { ok = false, reason = "no_time_away" }
	end
	local slots = self:slots(plotName)
	local boxes = 0
	local cash = 0

	for _, slot in ipairs(slots) do
		if slot.cardId and slot.rarity then
			local active = (self:activation(slot))
			if active then
				local rate = FarmCatalog.slotRate(slot.rarity, slot.mutation, slot.upgradeLevel)
				local gained = FarmCatalog.offlineBoxes(rate, awaySeconds)
				local room = FarmCatalog.SlotCapacity - slot.boxes
				gained = math.max(0, math.min(gained, room))
				slot.boxes += gained
				boxes += gained
				cash += gained * FarmCatalog.boxValue(slot.rarity)
			end
		end
	end

	return {
		ok = boxes > 0,
		boxes = boxes,
		estimatedCash = cash,
		awaySeconds = math.floor(awaySeconds),
		countedSeconds = math.floor(math.min(awaySeconds, FarmCatalog.OfflineCapSeconds)),
	}
end

--- Flatten for persistence.
function FarmService:serialize(plotName: string)
	local out = {}
	for index, slot in ipairs(self:slots(plotName)) do
		out[index] = {
			unlocked = slot.unlocked,
			cardId = slot.cardId,
			rarity = slot.rarity,
			mutation = slot.mutation,
			upgradeLevel = slot.upgradeLevel,
			boxes = slot.boxes,
		}
	end
	return out
end

function FarmService:release(plotName: string)
	self.farms[plotName] = nil
end

return FarmService
