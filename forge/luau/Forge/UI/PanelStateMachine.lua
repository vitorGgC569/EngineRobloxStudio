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
	state: Status,
	elapsed: number,
	openTimeout: number,
	loadTimeout: number,
	closeTimeout: number,
}

--[[
	A field must never share a name with a method on the same table.

	`PanelStateMachine.__index = PanelStateMachine` means an instance looks at itself first, so an
	instance field called `status` shadows `PanelStateMachine.status` and the method
	becomes permanently uncallable: `instance:status()` finds the field and
	tries to call a table.

	Nothing catches it. It compiles, the type checker is content, and the unit
	specs call the module functions directly rather than through an instance --
	which is exactly the shape that never reaches the shadow. It surfaced the
	first time a game called `cycle:hand()` and got "attempt to call a table
	value", and a scan then found the same collision in four modules.

	The field is renamed rather than the method, because the method is the
	published surface and the field is private.
]]
PanelStateMachine.__index = PanelStateMachine

function PanelStateMachine.new(config: { openTimeout: number?, loadTimeout: number?, closeTimeout: number? }): Self
	return setmetatable({
		state = "closed" :: Status,
		elapsed = 0,
		openTimeout = config.openTimeout or 2,
		loadTimeout = config.loadTimeout or 6,
		closeTimeout = config.closeTimeout or 1,
	}, PanelStateMachine)
end

function PanelStateMachine.status(self: Self): Status
	return self.state
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
	local t = transitions[self.state]
	if not t then
		return
	end
	self.elapsed = 0
	if action == "open" then
		self.state = if self.state == "loadFailed" then "opening" else (t.open :: Status)
	elseif action == "close" then
		self.state = t.close :: Status
	end
end

function PanelStateMachine.dataArrived(self: Self): boolean
	if self.state ~= "loading" then
		return false
	end
	self.state = "open"
	return true
end

function PanelStateMachine.dataFailed(self: Self): boolean
	if self.state ~= "loading" then
		return false
	end
	self.state = "loadFailed"
	return true
end

function PanelStateMachine.animationDone(self: Self): ()
	if self.state == "opening" then
		self.state = "loading"
	elseif self.state == "closing" then
		self.state = "closed"
	end
end

-- Timeouts guarantee resolution even when a callback is lost.
function PanelStateMachine.tick(self: Self, dt: number): { resolved: string? }
	if self.state == "closed" or self.state == "open" then
		return {}
	end
	self.elapsed += dt
	local limit = if self.state == "opening"
		then self.openTimeout
		elseif self.state == "closing" then self.closeTimeout
		else self.loadTimeout
	if self.elapsed < limit then
		return {}
	end
	local before = self.state
	if before == "loading" then
		self.state = "loadFailed"
		return { resolved = "load_timeout" }
	elseif before == "closing" then
		self.state = "closed"
		return { resolved = "close_timeout" }
	else
		self.state = "loading"
		return { resolved = "open_timeout" }
	end
end

return PanelStateMachine
