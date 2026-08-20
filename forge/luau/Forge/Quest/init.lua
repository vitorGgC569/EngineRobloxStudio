--!strict
--[[
	Quest — objectives as event filters.

	The design decision that makes this generic: an objective does not have a
	*kind*. It has an event name and a match. "Kill five orcs", "collect eight
	pelts", "reach the summit" and "survive three nights" are the same mechanism
	with different data, so adding a new objective type is adding a line of
	content, not a branch in a tracker.

		Quest.define("q_wolves", {
			name = "Teeth in the Fields",
			objectives = {
				{ id = "kill", label = "Cull the wolves", count = 8,
				  event = "enemy.killed", match = { kind = "wolf" } },
				{ id = "pelts", label = "Recover pelts", count = 4,
				  event = "inventory.added", match = { item = "wolf_pelt" }, useAmount = true },
			},
			rewards = { xp = 320, currency = { gold = 90 } },
			next = "q_bandits",
		})

		Quest.accept("player:1", "q_wolves")

	`useAmount` counts the payload's `amount` rather than one per event, which
	is the difference between "picked up 4 pelts at once" counting as 4 or as 1.
]]

local Events = require(script.Parent.Events)

local Quest = {}

type Objective = {
	id: string,
	label: string?,
	count: number?,
	event: string,
	match: { [string]: any }?,
	useAmount: boolean?,
	amountKey: string?,
}

type Definition = {
	name: string,
	summary: string?,
	objectives: { Objective },
	rewards: { [string]: any }?,
	requires: { string }?, -- quest ids that must be complete first
	level: number?,
	repeatable: boolean?,
	next: string?,
	giver: string?,
}

local definitions: { [string]: Definition } = {}
local states: { [string]: any } = {} -- subject -> { active = {}, completed = {} }
local wired = false

function Quest.define(id: string, definition: Definition)
	assert(type(definition.objectives) == "table" and #definition.objectives > 0,
		string.format("[Quest] '%s' needs at least one objective", id))
	for _, objective in definition.objectives do
		assert(type(objective.event) == "string",
			string.format("[Quest] '%s' objective '%s' needs an event name", id, tostring(objective.id)))
		objective.count = objective.count or 1
	end
	definitions[id] = definition
	Quest.wire()
end

function Quest.defineMany(table_: { [string]: Definition })
	for id, definition in table_ do
		Quest.define(id, definition)
	end
end

function Quest.get(id: string): Definition?
	return definitions[id]
end

-- ================================== state ===================================
local function stateFor(subject: string): any
	local state = states[subject]
	if not state then
		state = { active = {}, completed = {} }
		states[subject] = state
	end
	return state
end

Quest.stateFor = stateFor

function Quest.isComplete(subject: string, questId: string): boolean
	return stateFor(subject).completed[questId] == true
end

function Quest.isActive(subject: string, questId: string): boolean
	return stateFor(subject).active[questId] ~= nil
end

--[[
	Can this subject take this quest right now? Checks prerequisites and the
	repeat rule, so callers never have to re-derive the chain logic.
]]
function Quest.available(subject: string, questId: string): boolean
	local definition = definitions[questId]
	if not definition then
		return false
	end
	local state = stateFor(subject)
	if state.active[questId] then
		return false
	end
	if state.completed[questId] and not definition.repeatable then
		return false
	end
	for _, required in (definition.requires or {}) do
		if not state.completed[required] then
			return false
		end
	end
	return true
end

function Quest.availableFor(subject: string, giver: string?): { string }
	local out = {}
	for id, definition in definitions do
		if giver and definition.giver ~= giver then
			continue
		end
		if Quest.available(subject, id) then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

function Quest.accept(subject: string, questId: string): boolean
	if not Quest.available(subject, questId) then
		return false
	end
	local definition = definitions[questId]
	local progress = {}
	for _, objective in definition.objectives do
		progress[objective.id] = 0
	end

	stateFor(subject).active[questId] = { progress = progress, startedAt = os.time() }
	Events.emit("quest.accepted", { subject = subject, quest = questId })
	return true
end

function Quest.abandon(subject: string, questId: string)
	local state = stateFor(subject)
	if state.active[questId] then
		state.active[questId] = nil
		Events.emit("quest.abandoned", { subject = subject, quest = questId })
	end
end

-- =============================== the tracker ================================
local function matches(objective: Objective, payload: any): boolean
	if not objective.match then
		return true
	end
	for field, expected in objective.match do
		if payload[field] ~= expected then
			return false
		end
	end
	return true
end

function Quest.objectiveDone(questId: string, objectiveId: string, progress: number): boolean
	local definition = definitions[questId]
	for _, objective in definition.objectives do
		if objective.id == objectiveId then
			return progress >= (objective.count or 1)
		end
	end
	return false
end

function Quest.isFulfilled(subject: string, questId: string): boolean
	local entry = stateFor(subject).active[questId]
	if not entry then
		return false
	end
	local definition = definitions[questId]
	for _, objective in definition.objectives do
		if (entry.progress[objective.id] or 0) < (objective.count or 1) then
			return false
		end
	end
	return true
end

--[[
	One wildcard listener drives every quest for every subject.

	The alternative — one listener per active objective — means a server with
	fifty players running six quests each carries three hundred subscriptions
	that must be torn down exactly right on abandon, completion and disconnect.
	This costs one dispatch per event and cannot leak.
]]
function Quest.wire()
	if wired then
		return
	end
	wired = true

	Events.onAny(function(eventName, payload)
		if string.sub(eventName, 1, 6) == "quest." then
			return -- never let quest events drive quests: instant recursion
		end
		local subject = payload.subject or payload.by or payload.player
		if type(subject) ~= "string" then
			return
		end
		local state = states[subject]
		if not state then
			return
		end

		for questId, entry in state.active do
			local definition = definitions[questId]
			if not definition then
				continue
			end
			local advanced = false

			for _, objective in definition.objectives do
				if objective.event ~= eventName then
					continue
				end
				local target = objective.count or 1
				local current = entry.progress[objective.id] or 0
				if current >= target then
					continue
				end
				if not matches(objective, payload) then
					continue
				end

				local step = 1
				if objective.useAmount then
					step = tonumber(payload[objective.amountKey or "amount"]) or 1
				end
				entry.progress[objective.id] = math.min(target, current + step)
				advanced = true

				Events.emit("quest.progress", {
					subject = subject,
					quest = questId,
					objective = objective.id,
					progress = entry.progress[objective.id],
					target = target,
				})
			end

			if advanced and Quest.isFulfilled(subject, questId) then
				Events.emit("quest.fulfilled", { subject = subject, quest = questId })
			end
		end
	end)
end

--[[
	Hand in a fulfilled quest. Rewards are returned rather than granted: Quest
	does not know what gold is, or where a player's inventory lives. The caller
	applies them, which keeps this module free of every other system.
]]
function Quest.complete(subject: string, questId: string): (boolean, any?)
	if not Quest.isFulfilled(subject, questId) then
		return false, nil
	end
	local state = stateFor(subject)
	local definition = definitions[questId]

	state.active[questId] = nil
	state.completed[questId] = true

	Events.emit("quest.completed", { subject = subject, quest = questId })
	return true, definition.rewards
end

function Quest.progressOf(subject: string, questId: string): any
	local entry = stateFor(subject).active[questId]
	return entry and entry.progress or nil
end

--[[
	Everything a quest log needs, already shaped for display.
]]
function Quest.journal(subject: string): { any }
	local state = stateFor(subject)
	local out = {}
	for questId, entry in state.active do
		local definition = definitions[questId]
		if not definition then
			continue
		end
		local objectives = {}
		for _, objective in definition.objectives do
			table.insert(objectives, {
				id = objective.id,
				label = objective.label or objective.id,
				progress = entry.progress[objective.id] or 0,
				target = objective.count or 1,
			})
		end
		table.insert(out, {
			id = questId,
			name = definition.name,
			summary = definition.summary,
			objectives = objectives,
			fulfilled = Quest.isFulfilled(subject, questId),
		})
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- =============================== persistence ================================
function Quest.serialize(subject: string): any
	return stateFor(subject)
end

function Quest.deserialize(subject: string, data: any)
	states[subject] = {
		active = (data and data.active) or {},
		completed = (data and data.completed) or {},
	}
end

function Quest.describe(): { [string]: any }
	local activeTotal, completedTotal = 0, 0
	for _, state in states do
		for _ in state.active do
			activeTotal += 1
		end
		for _ in state.completed do
			completedTotal += 1
		end
	end
	local defined = {}
	for id in definitions do
		table.insert(defined, id)
	end
	table.sort(defined)
	return {
		defined = defined,
		subjects = (function()
			local n = 0
			for _ in states do
				n += 1
			end
			return n
		end)(),
		active = activeTotal,
		completed = completedTotal,
		wired = wired,
	}
end

return Quest
