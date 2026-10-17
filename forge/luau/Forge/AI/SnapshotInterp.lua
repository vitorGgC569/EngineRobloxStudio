--!strict
--[[
	SnapshotInterp — client-side pose interpolation between network
	snapshots.

	The server replicates poses at 12-20 Hz; rendering runs at 60+. The
	rule that keeps crowds smooth: always blend FROM the last rendered
	pose (never rewind), with a span that stretches for large jumps and
	clamps so lag can never freeze or snap the visual.
]]

local SnapshotInterp = {}

export type Pose = {
	x: number,
	y: number,
	z: number,
	yaw: number,
}

type Sample = {
	pose: Pose,
	t: number,
}

type EntityBuffer = {
	prev: Sample?,
	next: Sample?,
	rendered: Pose,
	span: number?,
}

type Self = {
	targetSpan: number,
	minSpan: number,
	maxSpan: number,
	buffers: { [string]: EntityBuffer },
}

SnapshotInterp.__index = SnapshotInterp

-- The caller reuses one pose table for the next snapshot. Storing that
-- table makes the previous sample move with it, so the blend has no start.
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

local function lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

local function shortestYawDelta(from: number, to: number): number
	local delta = (to - from) % (math.pi * 2)
	if delta > math.pi then
		delta -= math.pi * 2
	end
	if delta < -math.pi then
		delta += math.pi * 2
	end
	return delta
end

function SnapshotInterp.new(config: { targetSpan: number?, minSpan: number?, maxSpan: number? }): Self
	return setmetatable({
		targetSpan = config.targetSpan or 0.1,
		minSpan = config.minSpan or 1 / 120,
		maxSpan = config.maxSpan or 0.25,
		buffers = {},
	}, SnapshotInterp)
end

function SnapshotInterp.feed(self: Self, entityId: string, pose: Pose, recvTime: number): ()
	local buffer = self.buffers[entityId]
	if not buffer then
		buffer = { prev = nil, next = nil, rendered = { x = pose.x, y = pose.y, z = pose.z, yaw = pose.yaw } }
		self.buffers[entityId] = buffer
	end
	buffer.prev = if buffer.next then buffer.next else { pose = table.clone(buffer.rendered), t = recvTime - self.targetSpan }
	buffer.next = { pose = deepCopy(pose, {}), t = recvTime }

	local jump = math.sqrt(
		(pose.x - buffer.rendered.x) ^ 2 + (pose.y - buffer.rendered.y) ^ 2 + (pose.z - buffer.rendered.z) ^ 2
	)
	buffer.span = if jump > 10 then self.targetSpan * 1.5 else self.targetSpan
end

function SnapshotInterp.present(self: Self, entityId: string, now: number): Pose?
	local buffer = self.buffers[entityId]
	if not buffer then
		return nil
	end
	local prev, nextSample = buffer.prev, buffer.next
	if not nextSample then
		return deepCopy(buffer.rendered, {})
	end

	local span = buffer.span or self.targetSpan
	span = math.clamp(span, self.minSpan, self.maxSpan)

	local startPose = if prev then prev.pose else buffer.rendered
	local startTime = if prev then prev.t else nextSample.t - span
	local duration = math.max(nextSample.t - startTime, 1e-6)
	local alpha = math.clamp((now - startTime) / duration, 0, 1)

	buffer.rendered = {
		x = lerp(startPose.x, nextSample.pose.x, alpha),
		y = lerp(startPose.y, nextSample.pose.y, alpha),
		z = lerp(startPose.z, nextSample.pose.z, alpha),
		yaw = startPose.yaw + shortestYawDelta(startPose.yaw, nextSample.pose.yaw) * alpha,
	}
	if alpha >= 1 then
		buffer.prev = nextSample
		buffer.next = nil
	end
	return deepCopy(buffer.rendered, {})
end

function SnapshotInterp.remove(self: Self, entityId: string): ()
	self.buffers[entityId] = nil
end

return SnapshotInterp
