--!strict
--[[
	Perception — sight/hearing with a memory window.

	Real bots do not forget what they saw one frame ago. The sensor keeps
	a last-seen timestamp per key inside `memorySeconds`, merges fresh
	observations (FOV-filtered, LOS already resolved by the caller) with
	audible pings, and answers "who do I still believe is where?".
]]

local Perception = {}

export type Vec2 = { x: number, z: number }

type Memory = {
	key: string,
	pos: Vec2,
	lastSeen: number,
	heard: boolean,
}

type Self = {
	fovDeg: number,
	hearingRange: number,
	memorySeconds: number,
	facingX: number,
	facingZ: number,
	memories: { [string]: Memory },
	clock: () -> number,
}

Perception.__index = Perception

-- known() used to hand back the stored memory. Editing pos on that table
-- rewrote the position the next known() reported.
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

function Perception.new(config: { fovDeg: number?, hearingRange: number?, memorySeconds: number?, clock: (() -> number)? }): Self
	return setmetatable({
		fovDeg = config.fovDeg or 180,
		hearingRange = config.hearingRange or 0,
		memorySeconds = config.memorySeconds or 5,
		facingX = 0,
		facingZ = 1,
		memories = {},
		clock = config.clock or os.clock,
	}, Perception)
end

function Perception.setFacing(self: Self, dirX: number, dirZ: number): ()
	local len = math.sqrt(dirX * dirX + dirZ * dirZ)
	if len > 1e-6 then
		self.facingX = dirX / len
		self.facingZ = dirZ / len
	end
end

function Perception.observe(self: Self, selfPos: Vec2, others: { { key: string, pos: Vec2, visible: boolean? , audible: boolean? } }): ()
	local now = self.clock()
	local halfFov = math.rad(self.fovDeg) / 2
	for _, other in others do
		local dx, dz = other.pos.x - selfPos.x, other.pos.z - selfPos.z
		local dist = math.sqrt(dx * dx + dz * dz)
		local inSight = false
		if other.visible and dist <= math.huge then
			if self.fovDeg >= 360 or dist < 1e-6 then
				inSight = true
			else
				local dot = (dx / dist) * self.facingX + (dz / dist) * self.facingZ
				inSight = dot >= math.cos(halfFov)
			end
		end
		local heard = if other.audible ~= nil then other.audible else dist <= self.hearingRange and self.hearingRange > 0
		if not inSight and not heard then
			continue
		end
		self.memories[other.key] = {
			key = other.key,
			pos = { x = other.pos.x, z = other.pos.z },
			lastSeen = now,
			heard = heard and not inSight,
		}
	end
end

-- Everything remembered within the memory window; positions are as of
-- lastSeen (the brain extrapolates if it wants to).
function Perception.known(self: Self): { Memory }
	local now = self.clock()
	local out: { Memory } = {}
	for key, memory in self.memories do
		if now - memory.lastSeen > self.memorySeconds then
			self.memories[key] = nil
			continue
		end
		table.insert(out, deepCopy(memory, {}))
	end
	return out
end

function Perception.forget(self: Self, key: string): ()
	self.memories[key] = nil
end

return Perception
