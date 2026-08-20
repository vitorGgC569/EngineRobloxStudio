--!strict
-- A server-owned, event-driven first-session path.
--
-- An instruction on the HUD is not onboarding. Onboarding has to know which
-- effect the player produced, advance exactly once, and expose the next action
-- without trusting a client to declare success. This module deliberately does
-- not listen to remotes: game systems call `observe` only after their
-- authoritative mutation succeeded.
--
-- Steps describe semantic events, not instance paths. A build can move or
-- rename its purchase pad without invalidating the player's progress or the
-- black-box probe that reads the published attributes.

local Onboarding = {}

export type Step = {
	id: string,
	instruction: string,
	event: string,
	targetId: string?,
	accept: ((detail: { [string]: any }) -> boolean)?,
}

export type Definition = {
	id: string,
	steps: { Step },
}

export type State = {
	stepIndex: number,
	revision: number,
	started: boolean,
	finished: boolean,
	completed: { string },
	seenEffects: { [string]: boolean },
	lastEffectId: string?,
}

export type Store = {
	get: (userId: number) -> State?,
	set: (userId: number, state: State) -> (),
}

export type Snapshot = {
	id: string,
	revision: number,
	started: boolean,
	finished: boolean,
	stepIndex: number,
	stepCount: number,
	currentStepId: string?,
	instruction: string?,
	targetId: string?,
	expectedEvent: string?,
	completed: { string },
	lastEffectId: string?,
}

export type Receipt = {
	accepted: boolean,
	outcome: string,
	effectId: string?,
	previousStepId: string?,
	currentStepId: string?,
	revisionBefore: number,
	revisionAfter: number,
	snapshot: Snapshot,
}

export type Presenter = (player: Player, snapshot: Snapshot, receipt: Receipt?) -> ()

local function fail(message: string): never
	error("[Onboarding] " .. message, 3)
end

local function copyStrings(source: { string }): { string }
	local result = {}
	for _, value in ipairs(source) do
		table.insert(result, value)
	end
	return result
end

local function cloneState(source: State): State
	local effects = {}
	for id, seen in pairs(source.seenEffects) do
		effects[id] = seen
	end
	return {
		stepIndex = source.stepIndex,
		revision = source.revision,
		started = source.started,
		finished = source.finished,
		completed = copyStrings(source.completed),
		seenEffects = effects,
		lastEffectId = source.lastEffectId,
	}
end

function Onboarding.memoryStore(): Store
	local held: { [number]: State } = {}
	return {
		get = function(userId: number): State?
			local state = held[userId]
			return if state ~= nil then cloneState(state) else nil
		end,
		set = function(userId: number, state: State)
			held[userId] = cloneState(state)
		end,
	}
end

function Onboarding.validate(definition: Definition): { string }
	local problems = {}
	if type(definition.id) ~= "string" or definition.id == "" then
		table.insert(problems, "definition needs a non-empty id")
	end
	if type(definition.steps) ~= "table" or #definition.steps == 0 then
		table.insert(problems, "onboarding needs at least one observable step")
		return problems
	end

	local ids = {}
	for index, step in ipairs(definition.steps) do
		if type(step.id) ~= "string" or step.id == "" then
			table.insert(problems, string.format("step %d needs a non-empty id", index))
		elseif ids[step.id] then
			table.insert(problems, string.format("step id %q is declared twice", step.id))
		else
			ids[step.id] = true
		end
		if type(step.instruction) ~= "string" or step.instruction == "" then
			table.insert(problems, string.format("step %d needs a player-facing instruction", index))
		end
		if type(step.event) ~= "string" or step.event == "" then
			table.insert(problems, string.format("step %d needs an authoritative event", index))
		end
		if step.targetId ~= nil and (type(step.targetId) ~= "string" or step.targetId == "") then
			table.insert(problems, string.format("step %d targetId must be non-empty when present", index))
		end
	end
	return problems
end

function Onboarding.define(definition: Definition, store: Store?, presenter: Presenter?): any
	local problems = Onboarding.validate(definition)
	if #problems > 0 then
		fail("definition does not validate: " .. table.concat(problems, "; "))
	end
	local stateStore = store or Onboarding.memoryStore()
	if type(stateStore.get) ~= "function" or type(stateStore.set) ~= "function" then
		fail("store must provide get and set")
	end

	local self = {} :: any

	local function fresh(): State
		return {
			stepIndex = 1,
			revision = 0,
			started = false,
			finished = false,
			completed = {},
			seenEffects = {},
			lastEffectId = nil,
		}
	end

	local function stateFor(player: Player): State
		return stateStore.get(player.UserId) or fresh()
	end

	local function snapshotOf(state: State): Snapshot
		local step = if not state.finished then definition.steps[state.stepIndex] else nil
		return {
			id = definition.id,
			revision = state.revision,
			started = state.started,
			finished = state.finished,
			stepIndex = state.stepIndex,
			stepCount = #definition.steps,
			currentStepId = if step ~= nil then step.id else nil,
			instruction = if step ~= nil then step.instruction else nil,
			targetId = if step ~= nil then step.targetId else nil,
			expectedEvent = if step ~= nil then step.event else nil,
			completed = copyStrings(state.completed),
			lastEffectId = state.lastEffectId,
		}
	end

	local function publish(player: Player, snapshot: Snapshot, receipt: Receipt?)
		-- Player attributes are deliberately the black-box surface. They are
		-- server-written, stable across instance renames, and readable without
		-- requiring this module or peeking into its store.
		local writable = player :: any
		local setAttribute = writable.SetAttribute
		if type(setAttribute) == "function" then
			writable:SetAttribute("RQEOnboardingId", snapshot.id)
			writable:SetAttribute("RQEOnboardingRevision", snapshot.revision)
			writable:SetAttribute("RQEOnboardingStep", snapshot.currentStepId or "")
			writable:SetAttribute("RQEOnboardingTarget", snapshot.targetId or "")
			writable:SetAttribute("RQEOnboardingComplete", snapshot.finished)
			writable:SetAttribute("RQEOnboardingLastEffect", snapshot.lastEffectId or "")
		end
		if presenter ~= nil then
			presenter(player, snapshot, receipt)
		end
	end

	function self.start(player: Player): Receipt
		local state = stateFor(player)
		local before = state.revision
		local outcome = "ALREADY_STARTED"
		if not state.started then
			state.started = true
			state.revision += 1
			outcome = "STARTED"
			stateStore.set(player.UserId, state)
		end
		local snapshot = snapshotOf(state)
		local receipt: Receipt = {
			accepted = outcome == "STARTED",
			outcome = outcome,
			effectId = nil,
			previousStepId = nil,
			currentStepId = snapshot.currentStepId,
			revisionBefore = before,
			revisionAfter = state.revision,
			snapshot = snapshot,
		}
		publish(player, snapshot, receipt)
		return receipt
	end

	--- Observe one effect that already succeeded in a server-owned system.
	---
	--- `effectId` is mandatory and globally consumed even when the event is out
	--- of order. Without it, a retried purchase remote can complete two steps;
	--- without consuming out-of-order effects, an old action can be replayed
	--- later when it happens to match the current step.
	function self.observe(
		player: Player,
		event: string,
		effectId: string,
		detail: { [string]: any }?
	): Receipt
		if type(event) ~= "string" or event == "" then
			fail("observe needs a non-empty semantic event")
		end
		if type(effectId) ~= "string" or effectId == "" then
			fail("observe needs the unique id of an authoritative effect")
		end

		local state = stateFor(player)
		if not state.started then
			-- Starting here makes the first successful action count even when the
			-- PlayerAdded presenter was late. It does not grant client authority:
			-- only the server system owns this call.
			state.started = true
			state.revision += 1
		end
		local before = state.revision
		local current = definition.steps[state.stepIndex]
		local previousId = if current ~= nil then current.id else nil
		local accepted = false
		local outcome = "IGNORED"

		if state.seenEffects[effectId] then
			outcome = "DUPLICATE_EFFECT"
		elseif state.finished then
			state.seenEffects[effectId] = true
			state.lastEffectId = effectId
			outcome = "ALREADY_COMPLETE"
		else
			state.seenEffects[effectId] = true
			state.lastEffectId = effectId
			local matches = current ~= nil and current.event == event
			if matches and current.accept ~= nil then
				matches = current.accept(detail or {})
			end
			if matches and current ~= nil then
				accepted = true
				table.insert(state.completed, current.id)
				state.stepIndex += 1
				state.revision += 1
				if state.stepIndex > #definition.steps then
					state.finished = true
					outcome = "COMPLETED"
				else
					outcome = "ADVANCED"
				end
			else
				outcome = "OUT_OF_ORDER"
			end
		end

		stateStore.set(player.UserId, state)
		local snapshot = snapshotOf(state)
		local receipt: Receipt = {
			accepted = accepted,
			outcome = outcome,
			effectId = effectId,
			previousStepId = previousId,
			currentStepId = snapshot.currentStepId,
			revisionBefore = before,
			revisionAfter = state.revision,
			snapshot = snapshot,
		}
		publish(player, snapshot, receipt)
		return receipt
	end

	function self.snapshot(player: Player): Snapshot
		return snapshotOf(stateFor(player))
	end

	return self
end

return Onboarding
