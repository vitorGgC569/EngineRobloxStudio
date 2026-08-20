--!strict
-- L6: inventory.
--
-- Everything a player carries goes through one module, for the same reason
-- currency does: the failure modes are all silent.
--
-- **A full inventory must refuse loudly.** The tempting implementation adds what
-- fits and returns nothing, so a player who picks up ten ore and receives four
-- sees the four and assumes six never spawned. `add` returns how many were
-- actually taken, and the caller has to look at it.
--
-- **Removing more than is held must not go negative.** Check-then-remove written
-- in two services is how a quest consumes items the player does not have and
-- leaves a negative stack that displays as a huge number. `remove` is
-- all-or-nothing: a partial removal leaves a quest half-charged and the player
-- half-robbed, and neither side can tell which happened.
--
-- **"Carrying nothing" and "cannot carry anything" are different facts.** An
-- empty bag and a bag with no slots look identical in any report that counts
-- items, and they need opposite fixes.
--
-- Stacks live behind an injected store keyed by UserId, exactly like `Economy` --
-- persistence is `Save`'s problem, and an inventory can be simulated with a
-- plain table.

local Analytics = require(script.Parent.Analytics)

local Inventory = {}

export type ItemDefinition = {
	id: string,
	displayName: string,
	--- How many fit in one stack. A stack size of 1 means every unit takes a
	--- slot, which is what makes a tool inventory different from an ore one.
	stackSize: number?,
	--- Items nobody may drop or trade. Quest keys, mostly.
	bound: boolean?,
	tags: { string }?,
}

export type Stack = {
	itemId: string,
	count: number,
}

export type Store = {
	--- Keyed by UserId, like `Economy`'s. nil for a player who has never held
	--- anything: an empty table would make "never played" indistinguishable
	--- from "dropped everything", and the two are different in every report.
	get: (userId: number) -> { Stack }?,
	set: (userId: number, stacks: { Stack }) -> (),
}

export type Inventory = {
	items: { [string]: ItemDefinition },
	store: Store,
	--- Total slots. A slot holds one stack, whatever its size.
	slots: number,
	itemIds: (self: Inventory) -> { string },
	stacks: (self: Inventory, player: Player) -> { Stack },
	count: (self: Inventory, player: Player, itemId: string) -> number,
	usedSlots: (self: Inventory, player: Player) -> number,
	freeSlots: (self: Inventory, player: Player) -> number,
	room: (self: Inventory, player: Player, itemId: string) -> number,
	add: (self: Inventory, player: Player, itemId: string, amount: number, reason: string?) -> number,
	remove: (self: Inventory, player: Player, itemId: string, amount: number, reason: string?) -> boolean,
	has: (self: Inventory, player: Player, itemId: string, amount: number) -> boolean,
	clear: (self: Inventory, player: Player, reason: string?) -> (),
}

local function fail(message: string): never
	error("[Inventory] " .. message, 0)
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in pairs(map) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

--- An in-memory store, for simulation and tests.
---
--- The same shape the persistent one has, so a headless run of ten thousand
--- pickups exercises the code the game ships rather than a stand-in.
function Inventory.memoryStore(): Store
	local held: { [number]: { Stack } } = {}
	return {
		get = function(userId: number): { Stack }?
			return held[userId]
		end,
		set = function(userId: number, stacks: { Stack })
			held[userId] = stacks
		end,
	}
end

function Inventory.define(items: { ItemDefinition }, store: Store, slots: number): Inventory
	if type(slots) ~= "number" or slots < 1 or slots % 1 ~= 0 then
		fail("an inventory needs a whole number of slots, at least one")
	end
	if type(store) ~= "table" or type(store.get) ~= "function" or type(store.set) ~= "function" then
		fail("store must provide get and set")
	end

	local definitions: { [string]: ItemDefinition } = {}
	for _, item in ipairs(items) do
		if type(item.id) ~= "string" or item.id == "" then
			fail("every item needs a non-empty id")
		end
		if definitions[item.id] ~= nil then
			fail(string.format("item %q is defined twice", item.id))
		end
		local stackSize = item.stackSize or 1
		if type(stackSize) ~= "number" or stackSize < 1 or stackSize % 1 ~= 0 then
			fail(string.format(
				"item %q has stackSize %s; it must be a whole number of at least 1",
				item.id, tostring(item.stackSize)))
		end
		definitions[item.id] = item
	end

	local self = {} :: any
	self.items = definitions
	self.store = store
	self.slots = slots

	local function requireItem(itemId: string): ItemDefinition
		local definition = self.items[itemId]
		if definition == nil then
			fail(string.format("unknown item %q; defined: %s",
				itemId, table.concat(sortedKeys(self.items), ", ")))
		end
		return definition
	end

	local function requirePlayer(player: Player): number
		if typeof(player) ~= "Instance" or player.UserId == nil then
			fail("inventory operations need a Player; the store is keyed by UserId")
		end
		return player.UserId
	end

	local function requireAmount(amount: number)
		if type(amount) ~= "number" or amount <= 0 or amount % 1 ~= 0 then
			fail("amount must be a whole number above zero")
		end
	end

	function self:itemIds(): { string }
		return sortedKeys(self.items)
	end

	function self:stacks(player: Player): { Stack }
		local held = self.store.get(requirePlayer(player))
		if held == nil then
			return {}
		end
		-- Copied on read. Handing out the stored table lets a caller mutate the
		-- inventory without going through `add` or `remove`, which is exactly
		-- the path every guarantee in this module depends on.
		local copy: { Stack } = {}
		for index, stack in ipairs(held) do
			copy[index] = { itemId = stack.itemId, count = stack.count }
		end
		return copy
	end

	function self:count(player: Player, itemId: string): number
		requireItem(itemId)
		local total = 0
		for _, stack in ipairs(self:stacks(player)) do
			if stack.itemId == itemId then
				total += stack.count
			end
		end
		return total
	end

	function self:usedSlots(player: Player): number
		return #self:stacks(player)
	end

	function self:freeSlots(player: Player): number
		return math.max(self.slots - self:usedSlots(player), 0)
	end

	--- How many more of this item would fit right now.
	---
	--- Room in partly-filled stacks plus room in empty slots. Callers use this
	--- to decide whether a pickup is worth spawning at all, which is cheaper
	--- than spawning it and taking it back.
	function self:room(player: Player, itemId: string): number
		local definition = requireItem(itemId)
		local stackSize = definition.stackSize or 1
		local held = self:stacks(player)
		local space = 0
		for _, stack in ipairs(held) do
			if stack.itemId == itemId then
				space += math.max(stackSize - stack.count, 0)
			end
		end
		return space + math.max(self.slots - #held, 0) * stackSize
	end

	--- Add up to `amount`, returning how many were actually taken.
	---
	--- The return value is the whole point. Adding what fits and returning
	--- nothing is how a player picks up ten ore, receives four, and concludes
	--- the other six never existed.
	function self:add(player: Player, itemId: string, amount: number, reason: string?): number
		local definition = requireItem(itemId)
		requireAmount(amount)
		local userId = requirePlayer(player)

		local stackSize = definition.stackSize or 1
		local held = self:stacks(player)
		local remaining = amount

		for _, stack in ipairs(held) do
			if remaining <= 0 then
				break
			end
			if stack.itemId == itemId and stack.count < stackSize then
				local taken = math.min(stackSize - stack.count, remaining)
				stack.count += taken
				remaining -= taken
			end
		end

		while remaining > 0 and #held < self.slots do
			local taken = math.min(stackSize, remaining)
			table.insert(held, { itemId = itemId, count = taken })
			remaining -= taken
		end

		local added = amount - remaining
		if added > 0 then
			self.store.set(userId, held)
			Analytics.custom(player, "inventory_add", added, {
				itemId = itemId,
				requested = tostring(amount),
				reason = reason or "unspecified",
			})
		end
		if added < amount then
			-- Emitted separately. A partially refused pickup is a capacity
			-- problem, and it is invisible in a log that only records what
			-- succeeded.
			Analytics.custom(player, "inventory_full", amount - added, {
				itemId = itemId,
				reason = reason or "unspecified",
			})
		end
		return added
	end

	function self:has(player: Player, itemId: string, amount: number): boolean
		return self:count(player, itemId) >= amount
	end

	--- Remove exactly `amount`, or nothing at all.
	function self:remove(player: Player, itemId: string, amount: number, reason: string?): boolean
		requireItem(itemId)
		requireAmount(amount)
		local userId = requirePlayer(player)

		if self:count(player, itemId) < amount then
			return false
		end

		local held = self:stacks(player)
		local remaining = amount
		local kept: { Stack } = {}
		for _, stack in ipairs(held) do
			if stack.itemId == itemId and remaining > 0 then
				local taken = math.min(stack.count, remaining)
				stack.count -= taken
				remaining -= taken
			end
			if stack.count > 0 then
				table.insert(kept, stack)
			end
		end

		self.store.set(userId, kept)
		Analytics.custom(player, "inventory_remove", amount, {
			itemId = itemId,
			reason = reason or "unspecified",
		})
		return true
	end

	function self:clear(player: Player, reason: string?)
		self.store.set(requirePlayer(player), {})
		Analytics.custom(player, "inventory_clear", 0, {
			reason = reason or "unspecified",
		})
	end

	return self :: Inventory
end

--- Problems with an inventory's shape, before a player ever holds anything.
---
--- Each of these ships a game that runs and frustrates: a capacity smaller than
--- the loop needs, or stack sizes that mean one pickup fills the bag.
function Inventory.problems(inventory: Inventory, policy: { [string]: any }?): { string }
	local settings = policy or {}
	local minimumSlots = settings.minimumSlots or 6
	local found: { string } = {}

	if inventory.slots < minimumSlots then
		table.insert(found, string.format(
			"%d slots is below the %d a loop needs; the player spends the session managing "
			.. "the bag instead of playing", inventory.slots, minimumSlots))
	end

	local ids = inventory:itemIds()
	local distinct = #ids
	if distinct > inventory.slots then
		table.insert(found, string.format(
			"%d item types against %d slots: a player cannot hold one of each, so some part "
			.. "of the game is unreachable while another is in the bag",
			distinct, inventory.slots))
	end

	local unstackable = 0
	for _, itemId in ipairs(ids) do
		local definition = inventory.items[itemId]
		if (definition.stackSize or 1) == 1 then
			unstackable += 1
		end
	end
	if unstackable > 0 and inventory.slots < unstackable * 2 then
		table.insert(found, string.format(
			"%d of %d item types do not stack, against %d slots; the bag fills before the "
			.. "loop closes", unstackable, distinct, inventory.slots))
	end

	return found
end

return Inventory
