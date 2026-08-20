--!strict
--- States, and the rules about moving between them.
---
--- Every game has these and most write them as a string plus a pile of `if`.
--- That works until two places set the string, or until something needs to run
--- on the way out of a state, and then it is a class of bug that reads as
--- randomness: a door that is `open` and closed, an enemy that is `dead` and
--- attacking.
---
--- A machine here is a table of states, each with `enter`, `exit`, `update` and
--- the transitions it allows. **An illegal transition is refused and reported,
--- not silently performed** -- because a machine that will go anywhere from
--- anywhere is a string with extra steps.
---
--- It is deliberately not a gate on the programmer. `force` exists, and says so.

local Signal = require(script.Parent.Signal)

local StateMachine = {}
StateMachine.__index = StateMachine

export type StateSpec = {
	enter: ((any, string?) -> ())?,
	exit: ((any, string?) -> ())?,
	update: ((any, number) -> ())?,
	--- Which states this one may move to. Absent means any.
	to: { string }?,
}

export type Class = {
	current: string,
	previous: string?,
	changed: any,
	refused: any,
	can: (Class, string) -> boolean,
	to: (Class, string, any?) -> boolean,
	force: (Class, string, any?) -> (),
	update: (Class, number) -> (),
	is: (Class, string) -> boolean,
	history: (Class) -> { string },
	destroy: (Class) -> (),
}

--- Build a machine. `initial` is entered immediately, so its `enter` runs.
function StateMachine.new(states: { [string]: StateSpec }, initial: string, context: any?): Class
	if states[initial] == nil then
		local names = {}
		for name in pairs(states) do
			table.insert(names, name)
		end
		table.sort(names)
		error(("no state %q; have %s"):format(initial, table.concat(names, ", ")), 2)
	end

	local self = setmetatable({
		_states = states,
		_context = context,
		_history = { initial },
		current = initial,
		previous = nil,
		changed = Signal.new("StateMachine.changed"),
		refused = Signal.new("StateMachine.refused"),
	}, StateMachine)

	local spec = states[initial]
	if spec.enter ~= nil then
		spec.enter(context, nil)
	end
	return (self :: any) :: Class
end

function StateMachine.can(self, target: string): boolean
	if self._states[target] == nil then
		return false
	end
	local allowed = self._states[self.current].to
	if allowed == nil then
		return true
	end
	for _, name in ipairs(allowed) do
		if name == target then
			return true
		end
	end
	return false
end

local function move(self, target: string, payload: any)
	local from = self.current
	local leaving = self._states[from]
	if leaving.exit ~= nil then
		local ok, err = pcall(leaving.exit, self._context, target)
		if not ok then
			warn(("[StateMachine] exit %s errored: %s"):format(from, tostring(err)))
		end
	end

	self.previous = from
	self.current = target
	table.insert(self._history, target)
	if #self._history > 64 then
		table.remove(self._history, 1)
	end

	local entering = self._states[target]
	if entering.enter ~= nil then
		local ok, err = pcall(entering.enter, self._context, from)
		if not ok then
			warn(("[StateMachine] enter %s errored: %s"):format(target, tostring(err)))
		end
	end
	self.changed:fire(target, from, payload)
end

--- Move, if the transition is allowed. Returns whether it happened.
function StateMachine.to(self, target: string, payload: any?): boolean
	if self._states[target] == nil then
		self.refused:fire(target, self.current, "no such state")
		return false
	end
	if target == self.current then
		return false
	end
	if not self:can(target) then
		-- Reported rather than raised: an illegal transition is usually a race,
		-- not a typo, and crashing the frame is a worse answer than saying so.
		self.refused:fire(target, self.current, "transition not allowed")
		return false
	end
	move(self, target, payload)
	return true
end

--- Move regardless. The escape hatch, named so it is visible in a diff.
function StateMachine.force(self, target: string, payload: any?)
	if self._states[target] == nil then
		error(("no state %q to force into"):format(target), 2)
	end
	if target ~= self.current then
		move(self, target, payload)
	end
end

function StateMachine.update(self, delta: number)
	local spec = self._states[self.current]
	if spec.update ~= nil then
		local ok, err = pcall(spec.update, self._context, delta)
		if not ok then
			warn(("[StateMachine] update %s errored: %s"):format(self.current, tostring(err)))
		end
	end
end

function StateMachine.is(self, name: string): boolean
	return self.current == name
end

function StateMachine.history(self): { string }
	return table.clone(self._history)
end

function StateMachine.destroy(self)
	self.changed:destroy()
	self.refused:destroy()
	table.clear(self._history)
end

return StateMachine
