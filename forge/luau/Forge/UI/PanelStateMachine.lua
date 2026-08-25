--!strict
--[[
	PanelStateMachine — modal panel lifecycle that always resolves.

	Every panel eventually reaches a decided state: opening times out into
	open, a data load that never answers times out into an error state
	shown to the user, closing finishes. The classic bug — a spinner that
	spins forever because one callback never fired — cannot happen here.
]]

local PanelStateMachine = {}

export type Status = "closed" | "opening" | "open" | "closing" | "loading" | "loadFailed"

type Self = {
	status: Status,
	elapsed: number,
	openTimeout: number,
	loadTimeout: number,
	closeTimeout: number,
}

PanelStateMachine.__index = PanelStateMachine

function PanelStateMachine.new(config: { openTimeout: number?, loadTimeout: number?, closeTimeout: number? }): Self
	return setmetatable({
		status = "closed" :: Status,
		elapsed = 0,
		openTimeout = config.openTimeout or 2,
		loadTimeout = config.loadTimeout or 6,
		closeTimeout = config.closeTimeout or 1,
	}, PanelStateMachine)
end

function PanelStateMachine.status(self: Self): Status
	return self.status
end

local transitions: { [Status]: { open: Status, close: Status } } = {
	closed = { open = "opening", close = "closed" },
	opening = { open = "opening", close = "closing" },
	open = { open = "open", close = "closing" },
	closing = { open = "opening", close = "closing" },
	loading = { open = "loading", close = "closing" },
	loadFailed = { open = "opening", close = "closed" },
}

function PanelStateMachine.request(self: Self, action: string): ()
	local t = transitions[self.status]
	if not t then
		return
	end
	self.elapsed = 0
	if action == "open" then
		self.status = if self.status == "loadFailed" then "opening" else (t.open :: Status)
	elseif action == "close" then
		self.status = t.close :: Status
	end
end

function PanelStateMachine.dataArrived(self: Self): boolean
	if self.status ~= "loading" then
		return false
	end
	self.status = "open"
	return true
end

function PanelStateMachine.dataFailed(self: Self): boolean
	if self.status ~= "loading" then
		return false
	end
	self.status = "loadFailed"
	return true
end

function PanelStateMachine.animationDone(self: Self): ()
	if self.status == "opening" then
		self.status = "loading"
	elseif self.status == "closing" then
		self.status = "closed"
	end
end

-- Timeouts guarantee resolution even when a callback is lost.
function PanelStateMachine.tick(self: Self, dt: number): { resolved: string? }
	if self.status == "closed" or self.status == "open" then
		return {}
	end
	self.elapsed += dt
	local limit = if self.status == "opening"
		then self.openTimeout
		elseif self.status == "closing" then self.closeTimeout
		else self.loadTimeout
	if self.elapsed < limit then
		return {}
	end
	local before = self.status
	if before == "loading" then
		self.status = "loadFailed"
		return { resolved = "load_timeout" }
	elseif before == "closing" then
		self.status = "closed"
		return { resolved = "close_timeout" }
	else
		self.status = "loading"
		return { resolved = "open_timeout" }
	end
end

return PanelStateMachine
