--!strict
--[[
	StunController — stackable stun timers keyed by caller-chosen ids.

	Pure bookkeeping mined from Fighting-game's StunHandler: a fresh stun only
	extends an existing one when its duration exceeds the time still remaining,
	so chip-damage stuns never shrink a heavy slam's stun. No Humanoids, no
	attributes, no Heartbeat — the owner polls `isStunned` and drives `tick`.

	Deadlines live on an injectable clock so tests run deterministically;
	`tick` shifts deadlines directly, mixing cleanly with any time source.
]]

local StunController = {}
StunController.__index = StunController

export type Controller = typeof(setmetatable({} :: {
	_clock: () -> number,
	_deadlines: { [any]: number },
}, StunController))

function StunController.new(clock: (() -> number)?): Controller
	return setmetatable({
		_clock = clock or os.clock,
		_deadlines = {},
	}, StunController)
end

-- Returns false when the target is already stunned for at least this long.
function StunController:apply(targetId: any, seconds: number, now: number?): boolean
	assert(type(seconds) == "number" and seconds > 0, "StunController.apply: seconds must be positive")
	local at = now or self._clock()
	local deadline = self._deadlines[targetId]
	if deadline ~= nil and at < deadline and deadline - at >= seconds then
		return false
	end
	self._deadlines[targetId] = at + seconds
	return true
end

function StunController:tick(targetId: any, dt: number): number
	assert(type(dt) == "number" and dt >= 0, "StunController.tick: dt must be non-negative")
	local deadline = self._deadlines[targetId]
	if deadline == nil then
		return 0
	end
	deadline -= dt
	self._deadlines[targetId] = deadline
	return math.max(0, deadline - self._clock())
end

function StunController:remaining(targetId: any): number
	local deadline = self._deadlines[targetId]
	if deadline == nil then
		return 0
	end
	local left = deadline - self._clock()
	if left <= 0 then
		self._deadlines[targetId] = nil
		return 0
	end
	return left
end

function StunController:isStunned(targetId: any): boolean
	return self:remaining(targetId) > 0
end

function StunController:clear(targetId: any): boolean
	local had = self._deadlines[targetId] ~= nil
	self._deadlines[targetId] = nil
	return had
end

return StunController
