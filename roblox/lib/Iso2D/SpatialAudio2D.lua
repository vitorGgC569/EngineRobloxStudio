--!strict
--[[
	SpatialAudio2D — 2D positions mapped onto 3D emitters/listeners.

	The new audio API is 3D; a 2D game fakes position by placing
	invisible parts at scaled world coordinates. This module computes the
	3D placement (with a distance factor) and the attenuation plan so two
	speaking objects actually get quieter with distance.
]]

local SpatialAudio2D = {}

export type Vec2 = { x: number, y: number }

type Self = {
	distanceFactor: number, -- world px -> studs
	fixedHeight: number,
	maxDistance: number,
}

SpatialAudio2D.__index = SpatialAudio2D

function SpatialAudio2D.new(config: { distanceFactor: number?, fixedHeight: number?, maxDistance: number? }): Self
	return setmetatable({
		distanceFactor = config.distanceFactor or 0.5,
		fixedHeight = config.fixedHeight or 10,
		maxDistance = config.maxDistance or 200,
	}, SpatialAudio2D)
end

-- Where to place the invisible emitter/listener part for a 2D position.
function SpatialAudio2D.toWorldPosition(self: Self, pos: Vec2): { x: number, y: number, z: number }
	return {
		x = pos.x * self.distanceFactor,
		y = self.fixedHeight,
		z = -pos.y * self.distanceFactor,
	}
end

-- Attenuation plan: volume 1 at same spot, fading linearly to 0 at max.
function SpatialAudio2D.attenuation(self: Self, listenerPos: Vec2, emitterPos: Vec2): { volume: number, withinRange: boolean }
	local dx = emitterPos.x - listenerPos.x
	local dy = emitterPos.y - listenerPos.y
	local distPx = math.sqrt(dx * dx + dy * dy)
	local distStuds = distPx * self.distanceFactor
	if distStuds >= self.maxDistance then
		return { volume = 0, withinRange = false }
	end
	return { volume = 1 - distStuds / self.maxDistance, withinRange = true }
end

return SpatialAudio2D
