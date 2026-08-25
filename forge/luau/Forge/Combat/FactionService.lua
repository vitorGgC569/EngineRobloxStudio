--!strict
--[[
	FactionService — data-driven hostility resolution.

	Who can damage whom is content, not code: a stance matrix with
	defaults and pairwise overrides, plus context rules (PVP opt-in,
	party co-membership, pets). The resolver answers exactly one question
	with a stable reason string so probes can assert on it.
]]

local FactionService = {}

export type Stance = "hostile" | "friendly" | "neutral"

export type Context = {
	pvpOptIn: boolean?,
	sameParty: boolean?,
	isPet: boolean?,
}

type Self = {
	factions: { [string]: boolean },
	defaultStance: Stance,
	matrix: { [string]: { [string]: Stance } },
}

FactionService.__index = FactionService

local function normalize(stance: string): Stance?
	if stance == "hostile" or stance == "friendly" or stance == "neutral" then
		return stance :: Stance
	end
	return nil
end

function FactionService.new(config: { factions: { string }, defaultStance: Stance?, matrix: { [string]: { [string]: string } }? }): Self
	assert(#config.factions > 0, "need at least one faction")
	local known: { [string]: boolean } = {}
	for _, name in config.factions do
		known[name] = true
	end
	local matrix: { [string]: { [string]: Stance } } = {}
	for a, row in config.matrix or {} do
		assert(known[a], ("unknown faction %q in matrix"):format(a))
		matrix[a] = {}
		for b, stanceStr in row do
			assert(known[b], ("unknown faction %q in matrix"):format(b))
			local stance = normalize(stanceStr)
			assert(stance, ("invalid stance %q"):format(stanceStr))
			matrix[a][b] = stance
		end
	end
	return setmetatable({
		factions = known,
		defaultStance = config.defaultStance or "neutral" :: Stance,
		matrix = matrix,
	}, FactionService)
end

function FactionService.stance(self: Self, actorFaction: string, targetFaction: string): Stance
	if not self.factions[actorFaction] or not self.factions[targetFaction] then
		return "neutral"
	end
	if actorFaction == targetFaction then
		return "friendly"
	end
	local row = self.matrix[actorFaction]
	local direct = row and row[targetFaction]
	if direct then
		return direct
	end
	local reverseRow = self.matrix[targetFaction]
	local reverse = reverseRow and reverseRow[actorFaction]
	if reverse then
		return if reverse == "hostile" then "hostile" else "neutral"
	end
	return self.defaultStance
end

-- The only question combat asks. Stable reasons for probes.
function FactionService.canDamage(self: Self, actorFaction: string, targetFaction: string, ctx: Context?): (boolean, string?)
	local c = ctx or {}
	local stance = self:stance(actorFaction, targetFaction)
	if c.isPet and stance ~= "hostile" then
		return false, "pet_of_non_hostile"
	end
	if stance == "friendly" then
		return false, "friendly_fire"
	end
	if stance == "neutral" then
		return false, "not_hostile"
	end
	if c.sameParty then
		return false, "same_party"
	end
	if not c.pvpOptIn and actorFaction == "player" and targetFaction == "player" then
		return false, "pvp_not_opt_in"
	end
	return true, nil
end

return FactionService
