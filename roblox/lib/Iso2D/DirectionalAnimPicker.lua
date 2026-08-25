--!strict
--[[
	DirectionalAnimPicker — animation name from movement direction.

	Animation names follow the production convention: prefix + optional
	direction suffixes ("Walk", "WalkUp", "WalkDownLeft"...). The picker
	uses the 20-degree dead-band so diagonals feel deliberate, not noisy.
]]

local DirectionalAnimPicker = {}

type Self = {
	prefix: string,
	suffixes: { up: string, down: string, left: string, right: string },
	deadBandDeg: number,
	idlePrefix: string,
}

DirectionalAnimPicker.__index = DirectionalAnimPicker

function DirectionalAnimPicker.new(config: { prefix: string?, idlePrefix: string?, deadBandDeg: number? }): Self
	return setmetatable({
		prefix = config.prefix or "Walk",
		idlePrefix = config.idlePrefix or "Stay",
		deadBandDeg = config.deadBandDeg or 20,
		suffixes = { up = "Up", down = "Down", left = "Left", right = "Right" },
	}, DirectionalAnimPicker)
end

-- dirX/dirY in screen space (y grows downward).
function DirectionalAnimPicker.pick(self: Self, dirX: number, dirY: number): string
	local len = math.sqrt(dirX * dirX + dirY * dirY)
	if len < 1e-6 then
		return self.idlePrefix
	end
	local angleDeg = math.deg(math.atan(dirX / len, -dirY / len)) -- 0 = up, clockwise

	local vertical: string?
	local horizontal: string?
	if angleDeg >= self.deadBandDeg and angleDeg <= 180 - self.deadBandDeg then
		horizontal = self.suffixes.right
	elseif angleDeg <= -self.deadBandDeg or angleDeg >= 180 + self.deadBandDeg then
		horizontal = self.suffixes.left
	end
	if math.abs(angleDeg) <= 90 - self.deadBandDeg then
		vertical = self.suffixes.up
	elseif math.abs(angleDeg) >= 90 + self.deadBandDeg then
		vertical = self.suffixes.down
	end

	if vertical and horizontal then
		return self.prefix .. vertical .. horizontal
	elseif vertical then
		return self.prefix .. vertical
	elseif horizontal then
		return self.prefix .. horizontal
	end
	return self.prefix
end

return DirectionalAnimPicker
