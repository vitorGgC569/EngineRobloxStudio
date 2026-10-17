--!strict
--[[
	TutorialFlow — server-validated tutorial steps with telemetry hooks.

	The client can skip ahead all it wants: the step counter lives
	server-side, advances only when the server observed the required
	action, and every begin/finish of a step emits a mission event pair
	(attempts, duration) for analytics.
]]

local TutorialFlow = {}

export type Step = { id: string, missionId: string? }

type Session = {
	playerKey: string,
	stepIndex: number,
	startedAt: number,
	attempts: number,
	completedSteps: { [string]: boolean },
}

type Self = {
	steps: { Step },
	sessions: { [string]: Session },
	clock: () -> number,
}

TutorialFlow.__index = TutorialFlow

-- The caller can rewrite a step after registration. Sharing that table
-- makes currentStep follow the rewrite.
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

function TutorialFlow.new(steps: { Step }, clock: (() -> number)?): Self
	assert(#steps > 0, "tutorial needs steps")
	return setmetatable({
		steps = deepCopy(steps, {}),
		sessions = {},
		clock = clock or os.clock,
	}, TutorialFlow)
end

function TutorialFlow.begin(self: Self, playerKey: string, seen: boolean?): ()
	if seen then
		self.sessions[playerKey] = {
			playerKey = playerKey,
			stepIndex = #self.steps + 1,
			startedAt = 0,
			attempts = 0,
			completedSteps = {},
		}
		return
	end
	self.sessions[playerKey] = {
		playerKey = playerKey,
		stepIndex = 1,
		startedAt = self.clock(),
		attempts = 0,
		completedSteps = {},
	}
end

function TutorialFlow.currentStep(self: Self, playerKey: string): string?
	local session = self.sessions[playerKey]
	if not session or session.stepIndex > #self.steps then
		return nil
	end
	return self.steps[session.stepIndex].id
end

-- Server calls when it OBSERVED the action for the current step.
function TutorialFlow.completeStep(self: Self, playerKey: string): (boolean, { kind: string, stepId: string, attempts: number, seconds: number }?)
	local session = self.sessions[playerKey]
	if not session or session.stepIndex > #self.steps then
		return false, nil
	end
	local step = self.steps[session.stepIndex]
	session.attempts += 1
	session.completedSteps[step.id] = true
	local event = {
		kind = "step_complete",
		stepId = step.id,
		attempts = session.attempts,
		seconds = math.max(0, self.clock() - session.startedAt),
	}
	session.stepIndex += 1
	session.startedAt = self.clock()
	session.attempts = 0
	return true, event
end

function TutorialFlow.isFinished(self: Self, playerKey: string): boolean
	local session = self.sessions[playerKey]
	return session ~= nil and session.stepIndex > #self.steps
end

function TutorialFlow.forget(self: Self, playerKey: string): ()
	self.sessions[playerKey] = nil
end

return TutorialFlow
