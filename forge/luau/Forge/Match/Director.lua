--!strict
--[[
	Director — match rotation with map voting and live admin override.

	The match director decides what runs next: a playlist of maps/modes,
	player voting in the intermission, and an admin force-next that wins
	over any vote. Pure decision layer over injected clock.
]]

local Director = {}

export type PlaylistEntry = { id: string, mode: string, weight: number? }

type Self = {
	playlist: { PlaylistEntry },
	votes: { [string]: string }, -- voterKey -> entryId
	forcedNext: string?,
	currentIndex: number,
	lastEntryId: string?,
	clock: () -> number,
}

Director.__index = Director

-- The playlist used to keep the caller's entry tables. Renaming an id after
-- `new`, or renaming the table `next` handed back, rewrote the stored map
-- and a later vote could no longer find it.
local function deepCopy(value: any, seen: { [any]: any }): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return seen[value]
	end
	local copy = {}
	seen[value] = copy
	for key, item in value :: { [any]: any } do
		copy[key] = deepCopy(item, seen)
	end
	return copy
end

function Director.new(playlist: { PlaylistEntry }, clock: (() -> number)?): Self
	assert(#playlist > 0, "director needs a playlist")
	return setmetatable({
		playlist = deepCopy(playlist, {}),
		votes = {},
		forcedNext = nil,
		currentIndex = 0,
		lastEntryId = nil,
		clock = clock or os.time,
	}, Director)
end

function Director.vote(self: Self, voterKey: string, entryId: string): boolean
	if self.forcedNext then
		return false
	end
	for _, entry in self.playlist do
		if entry.id == entryId then
			self.votes[voterKey] = entryId
			return true
		end
	end
	return false
end

-- Admin override; survives until consumed.
function Director.forceNext(self: Self, byAdminKey: string, entryId: string): boolean
	for _, entry in self.playlist do
		if entry.id == entryId then
			self.forcedNext = entryId
			self.votes = {} -- votes become moot
			return true
		end
	end
	return false
end

-- Resolves and advances; returns the chosen entry.
function Director.next(self: Self): PlaylistEntry
	local chosen: PlaylistEntry? = nil
	if self.forcedNext then
		for _, entry in self.playlist do
			if entry.id == self.forcedNext then
				chosen = entry
				break
			end
		end
		self.forcedNext = nil
	end

	if not chosen then
		local tally: { [string]: number } = {}
		local bestId, bestCount = nil :: string?, -1
		for _, entryId in self.votes do
			tally[entryId] = (tally[entryId] or 0) + 1
			if tally[entryId] > bestCount then
				bestCount = tally[entryId]
				bestId = entryId
			end
		end
		if bestId then
			for _, entry in self.playlist do
				if entry.id == bestId then
					chosen = entry
					break
				end
			end
		end
	end

	self.votes = {}

	if not chosen then
		-- Weighted round-robin fallback that avoids repeating the last map.
		local candidates: { number } = {}
		local weights: { number } = {}
		for index, entry in self.playlist do
			if entry.id ~= self.lastEntryId or #self.playlist == 1 then
				table.insert(candidates, index)
				table.insert(weights, entry.weight or 1)
			end
		end
		local total = 0
		for _, w in weights do
			total += w
		end
		local roll = math.random() * math.max(total, 1e-9)
		local acc = 0
		local pickIndex = candidates[#candidates] :: number
		for i, w in weights do
			acc += w
			if roll < acc then
				pickIndex = candidates[i]
				break
			end
		end
		chosen = self.playlist[pickIndex]
	end

	self.lastEntryId = chosen.id
	return deepCopy(chosen, {})
end

return Director
