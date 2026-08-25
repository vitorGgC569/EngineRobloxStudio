--!strict
--[[
	Calc — letterbox-aware mapping between world and screen coordinates.

	A 2D game rendered on one ImageLabel lives in "world pixels": the
	original image's coordinate space. When the frame resizes with
	ScaleType.Fit, the world is scaled and centered with bars. Calc is the
	bidirectional map between those spaces — input picking depends on the
	inverse never drifting from the forward transform.
]]

local Calc = {}

export type Size = { width: number, height: number }
export type WorldPos = { x: number, y: number }

type View = {
	scale: number,
	offsetX: number,
	offsetY: number,
}

local function computeView(world: Size, screen: Size): View
	assert(world.width > 0 and world.height > 0 and screen.width > 0 and screen.height > 0, "invalid sizes")
	local scale = math.min(screen.width / world.width, screen.height / world.height)
	return {
		scale = scale,
		offsetX = (screen.width - world.width * scale) / 2,
		offsetY = (screen.height - world.height * scale) / 2,
	}
end

function Calc.view(worldSize: Size, screenSize: Size): View
	return computeView(worldSize, screenSize)
end

function Calc.worldToScreen(worldSize: Size, screenSize: Size, pos: WorldPos): { x: number, y: number }
	local view = computeView(worldSize, screenSize)
	return {
		x = view.offsetX + pos.x * view.scale,
		y = view.offsetY + pos.y * view.scale,
	}
end

function Calc.screenToWorld(worldSize: Size, screenSize: Size, pos: { x: number, y: number }): WorldPos
	local view = computeView(worldSize, screenSize)
	return {
		x = (pos.x - view.offsetX) / view.scale,
		y = (pos.y - view.offsetY) / view.scale,
	}
end

-- Scales a world-space size into screen pixels (uniform under Fit).
function Calc.scaleSize(worldSize: Size, screenSize: Size, size: Size): Size
	local view = computeView(worldSize, screenSize)
	return { width = size.width * view.scale, height = size.height * view.scale }
end

return Calc
