--!strict
--[[
	InteractionRules — shared cooldowns and input classification.

	The same cooldown number must govern the client's UX throttle and the
	server's security check, or one of them is lying. Input classification
	is by stable strings ("MouseButton1", "Touch", "GamepadButtonX") so
	rules stay testable without a device.
]]

local InteractionRules = {}

export type Cooldowns = { [string]: number }

type Self = {
	defaultCooldown: number,
	cooldowns: Cooldowns,
	lastActionAt: { [string]: number },
	clock: () -> number,
}

InteractionRules.__index = InteractionRules

function InteractionRules.new(config: {
	defaultCooldown: number?,
	cooldowns: Cooldowns?,
	clock: (() -> number)?,
}): Self
	return setmetatable({
		defaultCooldown = config.defaultCooldown or 0.25,
		cooldowns = config.cooldowns or {},
		lastActionAt = {},
		clock = config.clock or os.clock,
	}, InteractionRules)
end

-- One gate for both sides; key is "subject:action".
function InteractionRules.try(self: Self, key: string, action: string): (boolean, number?)
	local now = self.clock()
	local cooldown = self.cooldowns[action] or self.defaultCooldown
	local last = self.lastActionAt[key .. ":" .. action]
	if last and now - last < cooldown then
		return false, cooldown - (now - last)
	end
	self.lastActionAt[key .. ":" .. action] = now
	return true, nil
end

-- Device class from an input token; unknown tokens classify as touch so
-- mobile-first defaults win.
function InteractionRules.classify(inputToken: string): string
	if string.sub(inputToken, 1, 5) == "Mouse" then
		return "mouse"
	elseif string.sub(inputToken, 1, 7) == "Gamepad" then
		return "gamepad"
	elseif string.sub(inputToken, 1, 4) == "Key" then
		return "keyboard"
	end
	return "touch"
end

-- Panel answer timeout scaled by device class (touch users read slower).
local responseTimeoutByDevice: { [string]: number } = {
	mouse = 4,
	keyboard = 4,
	gamepad = 6,
	touch = 6,
}

function InteractionRules.responseTimeout(deviceClass: string): number
	return responseTimeoutByDevice[deviceClass] or 6
end

return InteractionRules
