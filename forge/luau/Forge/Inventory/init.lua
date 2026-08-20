--!strict
--[[
	Inventory — containers, stacks, equipment and transfers.

	A container is not "the player's bag". It is any container: a chest, a shop
	stock, a corpse, a crafting bench, a vending machine. Making them the same
	thing is what turns "loot a body" and "buy from a shop" into one operation
	(`Inventory.transfer`) instead of two systems that drift apart.

		Inventory.defineItem("iron_sword", { stack = 1, slot = "weapon", value = 40 })

		local bag = Inventory.create("player:" .. player.UserId, { slots = 30 })
		Inventory.add(bag, "iron_sword")
		Inventory.equip(bag, "weapon", uid)
		Inventory.transfer(chest, bag, uid)

	Every mutation emits an event, so quests, achievements and UI update without
	the inventory knowing they exist.
]]

local Events = require(script.Parent.Events)
local Signal = require(script.Parent.Core.Signal)

local Inventory = {}

Inventory.changed = Signal.new() -- (container)

type ItemDef = {
	stack: number?,
	slot: string?,
	value: number?,
	weight: number?,
	[string]: any,
}

local items: { [string]: ItemDef } = {}
local containers: { [string]: any } = {}
local uidCounter = 0

local function uid(): string
	uidCounter += 1
	return string.format("i%x%x", uidCounter, math.random(0, 65535))
end

-- ================================== items ===================================
function Inventory.defineItem(id: string, definition: ItemDef)
	definition.stack = definition.stack or 1
	items[id] = definition
end

function Inventory.defineItems(table_: { [string]: ItemDef })
	for id, definition in table_ do
		Inventory.defineItem(id, definition)
	end
end

function Inventory.itemDef(id: string): ItemDef?
	return items[id]
end

function Inventory.itemIds(): { string }
	local out = {}
	for id in items do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

-- ================================ containers ================================
export type ContainerOptions = {
	slots: number?,
	currencies: { [string]: number }?,
	equipment: { string }?, -- slot names this container can equip into
	infinite: boolean?, -- shops: never runs out, never fills up
}

function Inventory.create(key: string, options: ContainerOptions?): any
	local opts = options or {}
	local container = {
		key = key,
		slots = opts.slots or 24,
		infinite = opts.infinite == true,
		entries = {}, -- { uid, id, count, meta }
		equipped = {}, -- slotName -> uid
		equipSlots = opts.equipment or {},
		currencies = opts.currencies and table.clone(opts.currencies) or {},
	}
	containers[key] = container
	return container
end

function Inventory.get(key: string): any
	return containers[key]
end

function Inventory.destroy(key: string)
	containers[key] = nil
end

local function notify(container: any, event: string, payload: any)
	Inventory.changed:Fire(container)
	payload.container = container.key
	-- Quest tracking keys off `subject`. Containers are already keyed by the
	-- owner ("player:123"), so carrying it through means "collect eight pelts"
	-- works with no glue code in the game — which is the whole reason
	-- objectives are event filters.
	payload.subject = container.key
	Events.emit("inventory." .. event, payload)
end

-- ================================= queries ==================================
function Inventory.find(container: any, itemUid: string): any
	for index, entry in container.entries do
		if entry.uid == itemUid then
			return entry, index
		end
	end
	return nil
end

function Inventory.count(container: any, itemId: string): number
	local total = 0
	for _, entry in container.entries do
		if entry.id == itemId then
			total += entry.count
		end
	end
	return total
end

function Inventory.has(container: any, itemId: string, amount: number?): boolean
	return Inventory.count(container, itemId) >= (amount or 1)
end

function Inventory.used(container: any): number
	return #container.entries
end

function Inventory.free(container: any): number
	if container.infinite then
		return math.huge
	end
	return container.slots - #container.entries
end

function Inventory.list(container: any): { any }
	return table.clone(container.entries)
end

-- ================================ mutation ==================================
--[[
	Returns how many were actually added. A partial add is normal — a bag with
	two free slots takes two of the five you dropped — and pretending otherwise
	is how items get duplicated or vanish.
]]
function Inventory.add(container: any, itemId: string, amount: number?, meta: any?): number
	local definition = items[itemId]
	if not definition then
		warn(string.format("[Inventory] unknown item '%s'", itemId))
		return 0
	end
	local remaining = amount or 1
	local added = 0
	local maxStack = definition.stack or 1

	if maxStack > 1 then
		for _, entry in container.entries do
			if entry.id == itemId and entry.count < maxStack and not entry.meta then
				local room = maxStack - entry.count
				local take = math.min(room, remaining)
				entry.count += take
				remaining -= take
				added += take
				if remaining <= 0 then
					break
				end
			end
		end
	end

	while remaining > 0 do
		if not container.infinite and #container.entries >= container.slots then
			break
		end
		local put = math.min(maxStack, remaining)
		table.insert(container.entries, { uid = uid(), id = itemId, count = put, meta = meta })
		remaining -= put
		added += put
	end

	if added > 0 then
		notify(container, "added", { item = itemId, amount = added })
	end
	if remaining > 0 then
		notify(container, "full", { item = itemId, rejected = remaining })
	end
	return added
end

function Inventory.remove(container: any, itemId: string, amount: number?): number
	local wanted = amount or 1
	local removed = 0

	for index = #container.entries, 1, -1 do
		if removed >= wanted then
			break
		end
		local entry = container.entries[index]
		if entry.id ~= itemId then
			continue
		end
		local take = math.min(entry.count, wanted - removed)
		entry.count -= take
		removed += take
		if entry.count <= 0 then
			Inventory.unequipUid(container, entry.uid)
			table.remove(container.entries, index)
		end
	end

	if removed > 0 then
		notify(container, "removed", { item = itemId, amount = removed })
	end
	return removed
end

function Inventory.removeUid(container: any, itemUid: string, amount: number?): number
	local entry, index = Inventory.find(container, itemUid)
	if not entry then
		return 0
	end
	local take = math.min(entry.count, amount or entry.count)
	entry.count -= take
	if entry.count <= 0 then
		Inventory.unequipUid(container, itemUid)
		table.remove(container.entries, index)
	end
	notify(container, "removed", { item = entry.id, amount = take })
	return take
end

--[[
	Move between containers atomically: nothing is removed from the source
	unless the destination accepted it. Getting this backwards is how "loot a
	chest with a full bag" deletes the item.
]]
function Inventory.transfer(from: any, to: any, itemUid: string, amount: number?): number
	local entry = Inventory.find(from, itemUid)
	if not entry then
		return 0
	end
	local wanted = math.min(entry.count, amount or entry.count)

	local accepted = Inventory.add(to, entry.id, wanted, entry.meta)
	if accepted <= 0 then
		return 0
	end
	Inventory.removeUid(from, itemUid, accepted)

	Events.emit("inventory.transferred", {
		from = from.key,
		to = to.key,
		item = entry.id,
		amount = accepted,
	})
	return accepted
end

-- ================================ equipment =================================
function Inventory.equip(container: any, slot: string, itemUid: string): boolean
	local entry = Inventory.find(container, itemUid)
	if not entry then
		return false
	end
	local definition = items[entry.id]
	if not definition or definition.slot ~= slot then
		return false
	end
	container.equipped[slot] = itemUid
	notify(container, "equipped", { item = entry.id, slot = slot, uid = itemUid })
	return true
end

function Inventory.unequip(container: any, slot: string)
	local itemUid = container.equipped[slot]
	if not itemUid then
		return
	end
	container.equipped[slot] = nil
	notify(container, "unequipped", { slot = slot, uid = itemUid })
end

function Inventory.unequipUid(container: any, itemUid: string)
	for slot, equipped in container.equipped do
		if equipped == itemUid then
			container.equipped[slot] = nil
			notify(container, "unequipped", { slot = slot, uid = itemUid })
		end
	end
end

function Inventory.equippedItem(container: any, slot: string): (any?, ItemDef?)
	local itemUid = container.equipped[slot]
	if not itemUid then
		return nil, nil
	end
	local entry = Inventory.find(container, itemUid)
	return entry, entry and items[entry.id] or nil
end

-- ================================ currency ==================================
function Inventory.currency(container: any, kind: string): number
	return container.currencies[kind] or 0
end

function Inventory.addCurrency(container: any, kind: string, amount: number)
	container.currencies[kind] = math.max(0, (container.currencies[kind] or 0) + amount)
	notify(container, "currency", { kind = kind, amount = amount, total = container.currencies[kind] })
end

-- Returns false and changes nothing if there is not enough. Never let a
-- purchase path decide this for itself.
function Inventory.spend(container: any, kind: string, amount: number): boolean
	if (container.currencies[kind] or 0) < amount then
		return false
	end
	container.currencies[kind] -= amount
	notify(container, "currency", { kind = kind, amount = -amount, total = container.currencies[kind] })
	return true
end

-- =============================== persistence ================================
function Inventory.serialize(container: any): { [string]: any }
	return {
		slots = container.slots,
		entries = container.entries,
		equipped = container.equipped,
		currencies = container.currencies,
	}
end

function Inventory.deserialize(key: string, data: any, options: ContainerOptions?): any
	local container = Inventory.create(key, options)
	container.entries = data.entries or {}
	container.equipped = data.equipped or {}
	container.currencies = data.currencies or {}
	container.slots = data.slots or container.slots
	return container
end

function Inventory.describe(): { [string]: any }
	local report: { [string]: any } = {}
	local total = 0
	for key, container in containers do
		total += 1
		if total <= 20 then
			report[key] = { used = #container.entries, slots = container.slots }
		end
	end
	return { itemTypes = #Inventory.itemIds(), containers = total, sample = report }
end

return Inventory
