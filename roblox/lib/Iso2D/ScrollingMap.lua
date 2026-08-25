--!strict
--[[
	ScrollingMap — player-centred camera over a larger world image.

	The world moves, the player stays centred: camera position is the
	player's world position clamped to the map bounds (letterbox-aware),
	with a follow speed so the view eases instead of snapping.
]]

local Calc = require(script.Parent.Calc)

local ScrollingMap = {}

export type Vec2 = { x: number, y: number }

type Self = {
	worldSize: { width: number, height: number },
	viewSize: { width: number, height: number },
	followSpeed: number,
	camPos: Vec2,
}

ScrollingMap.__index = ScrollingMap

function ScrollingMap.new(config: {
	worldSize: { width: number, height: number },
	viewSize: { width: number, height: number },
	followSpeed: number?,
}): Self
	return setmetatable({
		worldSize = config.worldSize,
		viewSize = config.viewSize,
		followSpeed = config.followSpeed or 8,
		camPos = { x = config.worldSize.width / 2, y = config.worldSize.height / 2 },
	}, ScrollingMap)
end

-- Camera target follows the player; returns the world-image offset to apply
-- on screen (what the presentation sets as ImageLabel.Position delta).
function ScrollingMap.update(self: Self, playerWorldPos: Vec2, dt: number): Vec2
	local halfW = math.min(self.viewSize.width, self.worldSize.width) / 2
	local halfH = math.min(self.viewSize.height, self.worldSize.height) / 2

	local targetX = math.clamp(playerWorldPos.x, halfW / 1, math.max(halfW / 1, self.worldSize.width - 0))
	local targetY = math.clamp(playerWorldPos.y, halfH / 1, math.max(halfH / 1, self.worldSize.height - 0))
	targetX = math.clamp(playerWorldPos.x, 0, self.worldSize.width)
	targetY = math.clamp(playerWorldPos.y, 0, self.worldSize.height)

	local alpha = 1 - math.exp(-self.followSpeed * dt)
	self.camPos.x += (targetX - self.camPos.x) * alpha
	self.camPos.y += (targetY - self.camPos.y) * alpha

	local view = Calc.view(self.worldSize, self.viewSize)
	return {
		x = -(self.camPos.x * view.scale) + self.viewSize.width / 2,
		y = -(self.camPos.y * view.scale) + self.viewSize.height / 2,
	}
end

return ScrollingMap
