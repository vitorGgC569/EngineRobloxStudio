--!strict
--[[
	TeleportPads — pad-to-pad teleport bookkeeping with per-pad cooldown.

	Pads move characters between anchors; abuse comes from re-triggering
	the same pad instantly. Each pad has its own cooldown and a target
	pad id; the model validates the jump and reports the destination.
]]

local TeleportPads = {}

type Pad = {
	id: string,
	targetPadId: string,
	cooldownSeconds: number,
	lastUsedAt: number,
}

type Self = {
	pads: { [string]: Pad },
	clock: () -> number,
}

TeleportPads.__index = TeleportPads

function TeleportPads.new(clock: (() -> number)?): Self
	return setmetatable({ pads = {}, clock = clock or os.clock }, TeleportPads)
end

function TeleportPads.define(self: Self, id: string, targetPadId: string, cooldownSeconds: number?): ()
	assert(type(id) == "string" and #id > 0, "id must be a non-empty string")
	assert(type(targetPadId) == "string" and #targetPadId > 0, "targetPadId must be a non-empty string")
	assert(not self.pads[id], ("duplicate pad %q"):format(id))
	-- A negative cooldown is truthy, so `or 2` would keep it. After the first
	-- jump the elapsed time is 0, and 0 < -1 is false, so the pad never waits.
	local cooldown = if cooldownSeconds ~= nil then cooldownSeconds else 2
	-- math.huge is >= 0, and every finite elapsed time is still below it, so
	-- the pad would never open again after the first jump.
	assert(
		type(cooldown) == "number" and cooldown >= 0 and cooldown < math.huge,
		"cooldownSeconds must be a finite number >= 0"
	)
	self.pads[id] = { id = id, targetPadId = targetPadId, cooldownSeconds = cooldown, lastUsedAt = -math.huge }
end

-- Server calls when a character touches `padId`; returns destination or reason.
function TeleportPads.use(self: Self, padId: string): (string?, string?)
	local pad = self.pads[padId]
	if not pad then
		return nil, "unknown_pad"
	end
	local now = self.clock()
	-- NaN < seconds is false, so a bad clock would jump and then poison
	-- lastUsedAt. Every later real timestamp would also be NaN.
	if type(now) ~= "number" or now ~= now or now <= -math.huge or now >= math.huge then
		return nil, "bad_clock"
	end
	if now - pad.lastUsedAt < pad.cooldownSeconds then
		return nil, "pad_cooldown"
	end
	local target = self.pads[pad.targetPadId]
	if not target then
		return nil, "broken_link"
	end
	pad.lastUsedAt = now
	target.lastUsedAt = now -- both ends cool down to stop ping-ponging
	return pad.targetPadId, nil
end

return TeleportPads
