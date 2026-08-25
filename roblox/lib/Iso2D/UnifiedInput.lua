--!strict
--[[
	UnifiedInput — one movement vector from keyboard, gamepad or touch.

	Every device speaks the same language here: a normalized move vector
	plus action edges. Schemes map key tokens; gamepad/touch provide an
	analog vector directly. The game logic never sees a device.
]]

local UnifiedInput = {}

export type Vec2 = { x: number, y: number }

type Scheme = {
	up: { string },
	down: { string },
	left: { string },
	right: string,
}

type Self = {
	scheme: Scheme,
	held: { [string]: boolean },
	moveVector: Vec2?,
}

UnifiedInput.__index = UnifiedInput

local DEFAULT_SCHEME: Scheme = {
	up = { "W", "Up" },
	down = { "S", "Down" },
	left = { "A", "Left", "DPadLeft" },
	right = "D",
}

function UnifiedInput.new(scheme: Scheme?): Self
	return setmetatable({
		scheme = scheme or DEFAULT_SCHEME,
		held = {},
		moveVector = nil,
	}, UnifiedInput)
end

-- Keyboard/gamepad buttons: set held state per token each input event.
function UnifiedInput.setHeld(self: Self, token: string, isDown: boolean): ()
	self.held[token] = isDown
end

-- Analog source (thumbstick/touch joystick) overrides button composition.
function UnifiedInput.setAnalog(self: Self, vector: Vec2?): ()
	self.moveVector = vector
end

local function anyHeld(self: Self, tokens: { string }): boolean
	for _, token in tokens do
		if self.held[token] then
			return true
		end
	end
	return false
end

-- Composes the final move vector; analog wins when present and non-zero.
function UnifiedInput.getMoveVector(self: Self): Vec2
	if self.moveVector then
		local len = math.sqrt(self.moveVector.x ^ 2 + self.moveVector.y ^ 2)
		if len > 0.15 then
			return self.moveVector :: Vec2
		end
	end
	local right = (if anyHeld(self, { (self.scheme.right :: any) }) then 1 else 0)
		- (if anyHeld(self, self.scheme.left) then 1 else 0)
	local down = (if anyHeld(self, self.scheme.down) then 1 else 0)
		- (if anyHeld(self, self.scheme.up) then 1 else 0)
	return { x = right, y = down }
end

return UnifiedInput
