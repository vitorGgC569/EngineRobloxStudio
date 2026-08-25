--!strict
--[[
	ComboSequencer — data-driven attack chains with input buffering.

	Steps are inert data ({name, damage, windup, recovery, nextWindow}); the
	sequencer owns none of their meaning. Late presses are buffered for
	`bufferWindow` seconds (Fighting-game waits out the current swing instead
	of dropping inputs) and chains decay after `resetTimeout` seconds without
	an accepted link — SwordDude resets its combo after 0.5 s. Passing the
	final step wraps to the first, matching ChangeCombo; set loop = false to
	end chains there instead.

	Timing of windup/recovery/nextWindow stays with the caller — it decides
	when to call advance; the sequencer only judges whether a press links.
]]

local ComboSequencer = {}
ComboSequencer.__index = ComboSequencer

export type Step = {
	name: string,
	damage: number,
	windup: number,
	recovery: number,
	nextWindow: number,
}

export type Config = {
	steps: { Step },
	resetTimeout: number?,
	bufferWindow: number?,
	loop: boolean?,
}

local DEFAULT_RESET_TIMEOUT = 0.5
local DEFAULT_BUFFER_WINDOW = 0.2

-- ============================== construction =================================

function ComboSequencer.new(config: Config)
	assert(type(config) == "table", "ComboSequencer.new: config must be a table")
	assert(type(config.steps) == "table" and #config.steps > 0, "ComboSequencer.new: steps must be a non-empty array")

	local steps: { Step } = {}
	local indexByName: { [string]: number } = {}

	for position, step in config.steps do
		assert(type(step) == "table", "ComboSequencer.new: step " .. position .. " must be a table")
		assert(type(step.name) == "string" and #step.name > 0, "ComboSequencer.new: step " .. position .. " needs a name")
		assert(indexByName[step.name] == nil, "ComboSequencer.new: duplicate step name '" .. step.name .. "'")
		assert(type(step.damage) == "number" and step.damage >= 0, "ComboSequencer.new: step '" .. step.name .. "' damage must be a non-negative number")
		assert(type(step.windup) == "number" and step.windup >= 0, "ComboSequencer.new: step '" .. step.name .. "' windup must be a non-negative number")
		assert(type(step.recovery) == "number" and step.recovery >= 0, "ComboSequencer.new: step '" .. step.name .. "' recovery must be a non-negative number")
		assert(type(step.nextWindow) == "number" and step.nextWindow >= 0, "ComboSequencer.new: step '" .. step.name .. "' nextWindow must be a non-negative number")

		indexByName[step.name] = position
		steps[position] = {
			name = step.name,
			damage = step.damage,
			windup = step.windup,
			recovery = step.recovery,
			nextWindow = step.nextWindow,
		}
	end

	return setmetatable({
		_steps = steps,
		_indexByName = indexByName,
		_resetTimeout = config.resetTimeout or DEFAULT_RESET_TIMEOUT,
		_bufferWindow = config.bufferWindow or DEFAULT_BUFFER_WINDOW,
		_loop = config.loop ~= false,
		_pendingAt = nil :: number?,
		_lastAdvance = nil :: number?,
	}, ComboSequencer)
end

-- ============================== chain state ==================================

function ComboSequencer:indexOf(currentStep: string | number): number
	if type(currentStep) == "number" then
		assert(currentStep >= 1 and currentStep % 1 == 0 and currentStep <= #self._steps, "ComboSequencer.advance: step index out of range")
		return currentStep :: number
	end
	local index = self._indexByName[currentStep :: string]
	assert(index ~= nil, "ComboSequencer.advance: unknown step '" .. tostring(currentStep) .. "'")
	return index :: number
end

function ComboSequencer:press(inputAt: number)
	assert(type(inputAt) == "number", "ComboSequencer.press: inputAt must be a number")
	self._pendingAt = inputAt
end

function ComboSequencer:buffered(now: number): boolean
	local pendingAt = self._pendingAt
	if pendingAt == nil then
		return false
	end
	return math.abs(now - pendingAt) <= self._bufferWindow
end

-- Resolves the buffered press against the step being performed. Returns the
-- next step table (read-only by convention), or nil when no press is pending,
-- the press sits outside the buffer window, or the chain timed out — in which
-- case the stale press is dropped too.
function ComboSequencer:advance(currentStep: string | number, now: number): Step?
	assert(type(now) == "number", "ComboSequencer.advance: now must be a number")

	local anchor = self._lastAdvance
	if anchor ~= nil and now - anchor > self._resetTimeout then
		self._pendingAt = nil
		self._lastAdvance = nil
		return nil
	end

	if not self:buffered(now) then
		return nil
	end

	local index = self:indexOf(currentStep)
	local nextIndex = index + 1
	if nextIndex > #self._steps then
		if not self._loop then
			self._pendingAt = nil
			self._lastAdvance = nil
			return nil
		end
		nextIndex = 1
	end

	self._pendingAt = nil
	self._lastAdvance = now
	return self._steps[nextIndex]
end

function ComboSequencer:reset()
	self._pendingAt = nil
	self._lastAdvance = nil
end

return ComboSequencer
