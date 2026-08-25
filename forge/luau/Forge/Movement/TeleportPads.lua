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
	assert(not self.pads[id], ("duplicate pad %q"):format(id))
	self.pads[id] = { id = id, targetPadId = targetPadId, cooldownSeconds = cooldownSeconds or 2, lastUsedAt = -math.huge }
end

-- Server calls when a character touches `padId`; returns destination or reason.
function TeleportPads.use(self: Self, padId: string): (string?, string?)
	local pad = self.pads[padId]
	if not pad then
		return nil, "unknown_pad"
	end
	local now = self.clock()
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
