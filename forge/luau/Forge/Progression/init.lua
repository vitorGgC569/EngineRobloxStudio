--!strict
--[[
	Progression — levels, experience, points and unlocks, for any subject.

	"Subject" and not "player" on purpose: the same machinery levels a weapon, a
	settlement, a pet or a skill tree. A game that hard-codes progression to
	players has to write it again the first time a sword gains levels.

		Progression.define("hero", {
			maxLevel = 40,
			curve = function(level) return math.floor(72 * level ^ 1.55 + 28 * level) end,
			perLevel = { points = 3, health = 14 },
			unlocks = { [5] = { "ability.dash" }, [10] = { "zone.highlands" } },
		})

		local track = Progression.track("hero", "player:" .. userId)
		Progression.award(track, 320)

		Progression.totals(track).health   -- accumulated per-level grants
		Progression.unlocked(track, "ability.dash")
]]

local Events = require(script.Parent.Events)

local Progression = {}

type Definition = {
	maxLevel: number?,
	curve: ((level: number) -> number)?,
	perLevel: { [string]: number }?,
	unlocks: { [number]: { string } }?,
	startLevel: number?,
}

local definitions: { [string]: Definition } = {}
local tracks: { [string]: any } = {}

-- A sane default so `define` with no curve still behaves: quadratic-ish growth.
local function defaultCurve(level: number): number
	return math.floor(60 * level ^ 1.5 + 40 * level)
end

function Progression.define(kind: string, definition: Definition)
	definition.maxLevel = definition.maxLevel or 50
	definition.curve = definition.curve or defaultCurve
	definition.perLevel = definition.perLevel or {}
	definition.unlocks = definition.unlocks or {}
	definition.startLevel = definition.startLevel or 1
	definitions[kind] = definition
end

function Progression.track(kind: string, subject: string): any
	local key = kind .. "/" .. subject
	local existing = tracks[key]
	if existing then
		return existing
	end
	local definition = definitions[kind]
	assert(definition, string.format("[Progression] '%s' was never defined", kind))

	local track = {
		key = key,
		kind = kind,
		subject = subject,
		level = definition.startLevel,
		xp = 0,
		lifetimeXp = 0,
		unlocks = {},
		spent = {},
	}
	tracks[key] = track
	return track
end

function Progression.required(track: any): number
	local definition = definitions[track.kind]
	if track.level >= definition.maxLevel then
		return math.huge
	end
	return definition.curve(track.level)
end

--[[
	Grant experience. Handles multiple level-ups in one award, which a naive
	`if xp > needed then level += 1` does not — and that bug only shows up the
	first time a boss grants five levels at once.
]]
function Progression.award(track: any, amount: number): number
	local definition = definitions[track.kind]
	if amount <= 0 or track.level >= definition.maxLevel then
		return 0
	end

	track.xp += amount
	track.lifetimeXp += amount
	local gained = 0

	while track.level < definition.maxLevel do
		local needed = definition.curve(track.level)
		if track.xp < needed then
			break
		end
		track.xp -= needed
		track.level += 1
		gained += 1

		for _, unlock in (definition.unlocks[track.level] or {}) do
			track.unlocks[unlock] = true
			Events.emit("progression.unlocked", { track = track.key, unlock = unlock, level = track.level })
		end

		Events.emit("progression.levelup", {
			track = track.key,
			kind = track.kind,
			subject = track.subject,
			level = track.level,
		})
	end

	if track.level >= definition.maxLevel then
		track.xp = 0
	end

	Events.emit("progression.xp", { track = track.key, amount = amount, level = track.level })
	return gained
end

-- Everything the level grants, accumulated. `perLevel = { points = 3 }` at
-- level 7 gives 18 points (six level-ups past the first).
function Progression.totals(track: any): { [string]: number }
	local definition = definitions[track.kind]
	local out: { [string]: number } = {}
	local levelsGained = track.level - definition.startLevel
	for stat, perLevel in definition.perLevel do
		out[stat] = perLevel * levelsGained - (track.spent[stat] or 0)
	end
	return out
end

function Progression.spend(track: any, stat: string, amount: number): boolean
	local available = Progression.totals(track)[stat] or 0
	if available < amount then
		return false
	end
	track.spent[stat] = (track.spent[stat] or 0) + amount
	Events.emit("progression.spent", { track = track.key, stat = stat, amount = amount })
	return true
end

function Progression.unlocked(track: any, unlock: string): boolean
	return track.unlocks[unlock] == true
end

function Progression.grantUnlock(track: any, unlock: string)
	track.unlocks[unlock] = true
	Events.emit("progression.unlocked", { track = track.key, unlock = unlock, level = track.level })
end

function Progression.progressFraction(track: any): number
	local needed = Progression.required(track)
	if needed == math.huge or needed <= 0 then
		return 1
	end
	return math.clamp(track.xp / needed, 0, 1)
end

-- =============================== persistence ================================
function Progression.serialize(track: any): { [string]: any }
	return {
		kind = track.kind,
		subject = track.subject,
		level = track.level,
		xp = track.xp,
		lifetimeXp = track.lifetimeXp,
		unlocks = track.unlocks,
		spent = track.spent,
	}
end

function Progression.deserialize(data: any): any
	local track = Progression.track(data.kind, data.subject)
	track.level = data.level or track.level
	track.xp = data.xp or 0
	track.lifetimeXp = data.lifetimeXp or 0
	track.unlocks = data.unlocks or {}
	track.spent = data.spent or {}
	return track
end

function Progression.describe(): { [string]: any }
	local kinds = {}
	for kind, definition in definitions do
		kinds[kind] = { maxLevel = definition.maxLevel }
	end
	local sample: { [string]: any } = {}
	local total = 0
	for key, track in tracks do
		total += 1
		if total <= 12 then
			sample[key] = { level = track.level, xp = track.xp }
		end
	end
	return { kinds = kinds, tracks = total, sample = sample }
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.Progression.Achievements`
	was nil while `require(ReplicatedStorage.Forge.Progression.Achievements)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(Progression, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
