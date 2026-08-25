--!strict
--[[
	NotificationKit — queued player notifications and world floating text.

	Notifications stack (never overwrite), each with icon/text/color and
	an optional tween plan; floating text is a billboard plan anchored to
	a part with jitter so simultaneous popups do not overlap. Pure plans —
	the client renders them.
]]

local NotificationKit = {}

export type Notification = {
	id: number,
	icon: string?,
	text: string,
	color: { r: number, g: number, b: number }?,
	durationSeconds: number,
}

type Self = {
	queue: { [string]: { Notification } },
	nextId: number,
	maxPerPlayer: number,
}

NotificationKit.__index = NotificationKit

local function clamp01(v: number): number
	return math.clamp(v, 0, 1)
end

function NotificationKit.new(maxPerPlayer: number?): Self
	return setmetatable({ queue = {}, nextId = 1, maxPerPlayer = maxPerPlayer or 5 }, NotificationKit)
end

function NotificationKit.push(
	self: Self,
	playerKey: string,
	text: string,
	options: { icon: string?, color: { number }?, durationSeconds: number? }
): Notification
	local notification: Notification = {
		id = self.nextId,
		icon = options.icon,
		text = text,
		color = if options.color then { r = clamp01(options.color[1]), g = clamp01(options.color[2]), b = clamp01(options.color[3]) } else nil,
		durationSeconds = options.durationSeconds or 3,
	}
	self.nextId += 1
	local list = self.queue[playerKey] or {}
	table.insert(list, notification)
	while #list > self.maxPerPlayer do
		table.remove(list, 1)
	end
	self.queue[playerKey] = list
	return notification
end

function NotificationKit.drain(self: Self, playerKey: string): { Notification }
	local list = self.queue[playerKey]
	self.queue[playerKey] = nil
	return if list then list else {}
end

-- Floating text plan anchored to a part position; jitter spreads stacked
-- texts so they remain readable.
function NotificationKit.floatingText(anchorPos: { x: number, y: number, z: number }, text: string, stackIndex: number): {
	pos: { x: number, y: number, z: number },
	text: string,
	riseStuds: number,
	jitter: { x: number, z: number },
}
	return {
		pos = anchorPos,
		text = text,
		riseStuds = 3,
		jitter = {
			x = ((stackIndex * 37) % 11 - 5) / 10,
			z = ((stackIndex * 53) % 11 - 5) / 10,
		},
	}
end

return NotificationKit
