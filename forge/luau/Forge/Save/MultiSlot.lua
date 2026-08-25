--!strict
--[[
	MultiSlot — naming and selection rules for multi-slot saves.

	Slots let a player keep parallel profiles ("Slot 1..N") on one key family.
	The rules that are easy to get wrong live here, pure and testable: how slot
	keys are derived, which of several loaded entries is the real one, and how
	to summarize slots without paying for their payloads.

		local name = MultiSlot.slotName("Profile", 2) --> "Profile-two"
		local latest = MultiSlot.resolveLatest(entries)

	Suffixes spell out for the first ten slots (readable in the DataStore
	dashboard) and fall back to `-sN` beyond, so the scheme never runs out.
]]

local SUFFIXES = {
	"two",
	"three",
	"four",
	"five",
	"six",
	"seven",
	"eight",
	"nine",
	"ten",
}

export type SlotEntry = {
	timestamp: number?,
	data: any,
}

local MultiSlot = {}

-- Key name for `index` (1-based; slot 1 is the bare base name).
function MultiSlot.slotName(base: string, index: number): string
	local n = math.floor(tonumber(index) or 1)
	if n <= 1 then
		return base
	end
	if n <= #SUFFIXES + 1 then
		return base .. "-" .. SUFFIXES[n - 1]
	end
	return base .. "-s" .. n
end

-- The most recent entry, or nil when nothing usable was given.
--
-- Tie-break is stable: among equal timestamps the EARLIEST entry wins,
-- because scanning replaces only on a strictly greater timestamp. Same input
-- order, same winner — no dependence on hash order or wall-clock jitter.
function MultiSlot.resolveLatest(entries: { SlotEntry }?): SlotEntry?
	if typeof(entries) ~= "table" then
		return nil
	end
	local best: SlotEntry? = nil
	local bestTime = nil :: number?
	for _, entry in entries :: { SlotEntry } do
		if typeof(entry) ~= "table" then
			continue
		end
		local time = tonumber((entry :: any).timestamp)
		if time == nil then
			continue
		end
		if best == nil or time > (bestTime :: number) then
			best = entry
			bestTime = time
		end
	end
	return best
end

-- Per-slot metadata without loading payloads deeply.
--
-- Only the entry shells are inspected: timestamp passthrough plus whether
-- data exists and its TOP-LEVEL key count. Enough to show "Slot 2 — empty /
-- last played Tuesday" in a picker without walking (or even materializing)
-- the full profile.
function MultiSlot.peekSummary(entries: { SlotEntry }): { { index: number, timestamp: number?, populated: boolean, keys: number } }
	local summary = {}
	if typeof(entries) ~= "table" then
		return summary
	end
	for index, entry in entries :: { SlotEntry } do
		if typeof(entry) ~= "table" then
			continue
		end
		local data = (entry :: any).data
		local keys = 0
		if typeof(data) == "table" then
			for _ in data :: { [any]: any } do
				keys += 1
			end
		end
		table.insert(summary, {
			index = index,
			timestamp = tonumber((entry :: any).timestamp),
			populated = data ~= nil,
			keys = keys,
		})
	end
	return summary
end

return MultiSlot
