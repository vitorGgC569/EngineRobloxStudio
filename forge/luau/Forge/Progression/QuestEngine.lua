--!strict
--[[
	QuestEngine — declarative multi-stage quests with count/time objectives.

	A quest is data: stages with either a counting objective (tag-scoped
	interactions validated against a max distance) or a timed objective
	(accumulate dt while a condition holds). The engine owns stage state
	and advancement; the server feeds events. Rewards and chaining ride on
	completion.
]]

local QuestEngine = {}

export type Objective =
	{ kind: "count", targetTag: string, goal: number, maxDistance: number? }
	| { kind: "time", conditionId: string, seconds: number }

export type Stage = { objective: Objective, rewardId: string? }

export type QuestDef = {
	id: string,
	stages: { Stage },
}

export type QuestState = {
	questId: string,
	stage: number,
	count: number,
	accumulated: number,
	done: boolean,
}

type Self = {
	defs: { [string]: QuestDef },
}

QuestEngine.__index = QuestEngine

function QuestEngine.new(): Self
	return setmetatable({ defs = {} }, QuestEngine)
end

function QuestEngine.register(self: Self, def: QuestDef): ()
	assert(not self.defs[def.id], ("duplicate quest %q"):format(def.id))
	assert(#def.stages > 0, ("quest %q needs stages"):format(def.id))
	for _, stage in def.stages do
		local obj = stage.objective
		if obj.kind == "count" then
			assert(obj.goal >= 1, "count goal >= 1")
			assert(#obj.targetTag > 0, "count targetTag required")
		elseif obj.kind == "time" then
			assert(obj.seconds > 0, "time seconds > 0")
			assert(#obj.conditionId > 0, "time conditionId required")
		else
			error("unknown objective kind")
		end
	end
	self.defs[def.id] = table.clone(def)
end

function QuestEngine.get(self: Self, questId: string): QuestDef?
	return self.defs[questId]
end

function QuestEngine.start(self: Self, questId: string): QuestState?
	if not self.defs[questId] then
		return nil
	end
	return { questId = questId, stage = 1, count = 0, accumulated = 0, done = false }
end

function QuestEngine.currentObjective(self: Self, state: QuestState): Objective?
	local def = self.defs[state.questId]
	if not def or state.done then
		return nil
	end
	return def.stages[state.stage].objective
end

-- Counting objective event; `inRange` is the server's distance verdict.
function QuestEngine.reportEvent(self: Self, state: QuestState, targetTag: string, inRange: boolean): (QuestState, boolean)
	local obj = self:currentObjective(state)
	if not obj or obj.kind ~= "count" or obj.targetTag ~= targetTag or not inRange then
		return state, false
	end
	state.count += 1
	return self:_maybeAdvance(state), true
end

-- Timed objective accumulation; conditionHeld comes from the server tick.
function QuestEngine.tick(self: Self, state: QuestState, dt: number, conditionHeld: boolean): (QuestState, boolean)
	local obj = self:currentObjective(state)
	if not obj or obj.kind ~= "time" or not conditionHeld then
		return state, false
	end
	state.accumulated += dt
	if state.accumulated >= obj.seconds then
		state.accumulated = 0
		return self:_maybeAdvance(state), true
	end
	return state, false
end

function QuestEngine._maybeAdvance(self: Self, state: QuestState): QuestState
	local def = self.defs[state.questId] :: QuestDef
	local obj = def.stages[state.stage].objective
	local reached = if obj.kind == "count" then state.count >= obj.goal else state.accumulated >= obj.seconds
	if not reached then
		return state
	end
	state.count = 0
	state.accumulated = 0
	if state.stage >= #def.stages then
		state.done = true
	else
		state.stage += 1
	end
	return state
end

return QuestEngine
