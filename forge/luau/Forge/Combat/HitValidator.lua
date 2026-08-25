--!strict
--[[
	HitValidator — statistical sanity checks for client-reported hits.

	Server-side trust policy mined from vesteria's manager_damage: sample a
	few fixed points across the target's extents instead of trusting one
	client-claimed position (SAMPLE_POINTS = 5), forgive network jitter around
	action timestamps (LATENCY_FORGIVENESS = 0.125 s), and reject trajectories
	more than seven degrees off the predicted course (MAX_ANGLE_DEG = 7).

	Sampling walks a fixed golden-angle spiral — deterministic on every
	machine, never Random. Lockout adds per-pair hit-rate limiting so one
	swing cannot bill the same target twice inside its window.

	Pure data throughout: Vector3 in, Vector3 or boolean out.
]]

local HitValidator = {}

HitValidator.CONSTANTS = {
	SAMPLE_POINTS = 5,
	LATENCY_FORGIVENESS = 0.125,
	MAX_ANGLE_DEG = 7,
}

local GOLDEN_ANGLE = math.rad(137.50776405003785)

-- ============================== checks =======================================

-- Client clocks drift both ways, so the window is symmetric around now.
function HitValidator.withinLatencyWindow(actionTime: number, now: number, forgiveness: number?): boolean
	assert(type(actionTime) == "number", "HitValidator.withinLatencyWindow: actionTime must be a number")
	assert(type(now) == "number", "HitValidator.withinLatencyWindow: now must be a number")
	local limit = forgiveness or HitValidator.CONSTANTS.LATENCY_FORGIVENESS
	return math.abs(now - actionTime) <= limit
end

function HitValidator.pickSamplePoints(extentsCenter: Vector3, extentsSize: Vector3, count: number?): { Vector3 }
	local total = math.max(1, math.floor(count or HitValidator.CONSTANTS.SAMPLE_POINTS))
	local samples = table.create(total)
	for i = 0, total - 1 do
		local fraction = if i == 0 then 0 else math.sqrt(i / total)
		local angle = i * GOLDEN_ANGLE
		local offsetX = math.cos(angle) * fraction * extentsSize.X * 0.5
		local offsetZ = math.sin(angle) * fraction * extentsSize.Z * 0.5
		samples[i + 1] = Vector3.new(extentsCenter.X + offsetX, extentsCenter.Y, extentsCenter.Z + offsetZ)
	end
	return samples
end

function HitValidator.angleWithin(dirPredicted: Vector3, dirActual: Vector3, maxDeg: number?): boolean
	local limit = maxDeg or HitValidator.CONSTANTS.MAX_ANGLE_DEG
	local predictedMagnitude = dirPredicted.Magnitude
	local actualMagnitude = dirActual.Magnitude
	if predictedMagnitude <= 0 or actualMagnitude <= 0 then
		return false
	end
	local cosine = dirPredicted:Dot(dirActual) / (predictedMagnitude * actualMagnitude)
	local degreesOff = math.deg(math.acos(math.clamp(cosine, -1, 1)))
	return degreesOff <= limit
end

-- ============================== lockout ======================================

local Lockout = {}
Lockout.__index = Lockout

export type LockoutConfig = {
	maxHitsPerTarget: number?,
	window: number,
}

function Lockout.new(config: LockoutConfig)
	assert(type(config) == "table", "Lockout.new: config must be a table")
	assert(type(config.window) == "number" and config.window > 0, "Lockout.new: window must be a positive number")

	local maxHitsPerTarget = config.maxHitsPerTarget or 1
	assert(type(maxHitsPerTarget) == "number" and maxHitsPerTarget >= 1 and maxHitsPerTarget % 1 == 0, "Lockout.new: maxHitsPerTarget must be an integer >= 1")

	return setmetatable({
		_maxHitsPerTarget = maxHitsPerTarget,
		_window = config.window,
		_log = {} :: { [any]: { [any]: { number } } },
	}, Lockout)
end

-- Records a hit when allowed and returns true; rejected attempts are not
-- recorded, so spamming never extends a lockout.
function Lockout:register(attacker: any, target: any, now: number): boolean
	assert(type(now) == "number", "Lockout.register: now must be a number")

	local perAttacker = self._log[attacker]
	if perAttacker == nil then
		perAttacker = {}
		self._log[attacker] = perAttacker
	end

	local stamps = perAttacker[target] or {}
	local kept = {}
	for _, stamp in stamps do
		if now - stamp <= self._window then
			table.insert(kept, stamp)
		end
	end

	if #kept >= self._maxHitsPerTarget then
		perAttacker[target] = kept
		return false
	end

	table.insert(kept, now)
	perAttacker[target] = kept
	return true
end

function Lockout:clear(attacker: any, target: any?)
	if target ~= nil then
		local perAttacker = self._log[attacker]
		if perAttacker ~= nil then
			perAttacker[target] = nil
		end
	else
		self._log[attacker] = nil
	end
end

HitValidator.Lockout = Lockout

return HitValidator
