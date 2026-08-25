--!strict
--[[
	Store — one place the session's state lives, changed only by named actions.

	Why a game wants this and `Data` is not it
	-----------------------------------------

	`Data` holds content — the balance tables, the enemy definitions, the things
	that are true before anybody joins. `Save` holds what persists. This holds
	the third thing, and it is the one that usually ends up scattered across
	twelve modules as private tables: **who is in which room, what the score is,
	whose turn it is, what the countdown says** — the state of the session,
	which is gone when the server is.

	Scattered, that state has no single truth. The HUD reads one module's copy,
	the scoring reads another's, and they disagree at the moment somebody dies
	during a round transition. Held here, there is one copy and one way to
	change it.

		Store.reducer("score", function(state, action)
			if action.type == "scored" then
				local next_ = table.clone(state or {})
				next_[action.player] = (next_[action.player] or 0) + action.points
				return next_
			end
			return state or {}
		end)

		Store.dispatch({ type = "scored", player = "1", points = 10 })
		Store.get("score")

	The rules, and why each one earns its place
	------------------------------------------

	**Reducers are pure and return new tables.** Not because purity is a virtue
	in itself but because it makes "what changed" answerable: comparing the
	table before and after is how replication knows what to send and how a
	subscriber knows whether to re-render. Mutating in place destroys that.

	**Actions are data with a `type`.** So they can be logged, replayed,
	filtered and sent over a wire. A function call cannot be any of those.

	**Middleware wraps dispatch.** Which is what makes replication, logging and
	rate limiting things you add rather than things every reducer remembers to
	do.
]]

local Signal = require(script.Parent.Parent.Core.Signal)

local Store = {}

export type Action = { type: string, [any]: any }
export type Reducer = (state: any, action: Action) -> any
export type Middleware = (nextDispatch: (Action) -> any, store: any) -> ((Action) -> any)

local reducers: { [string]: Reducer } = {}
local state: { [string]: any } = {}
local middleware: { Middleware } = {}
local subscribers: { [string]: { (new: any, old: any) -> () } } = {}
local dispatchChain: ((Action) -> any)? = nil
local dispatched = 0

Store.changed = Signal.new() -- (slice, new, old, action)

-- ================================= reducers =================================
--[[
	Register the reducer for one slice of state.

	Slices rather than one big reducer, because a single reducer over the whole
	tree means every module's state lives in one function and every change to
	it is a merge conflict. A slice is owned by the system that understands it.

	Registering rebuilds the dispatch chain, so reducers may be added at any
	time — which matters for a game whose systems start in an order nobody
	wants to be strict about.
]]
function Store.reducer(slice: string, reducer: Reducer)
	reducers[slice] = reducer
	-- Seed the slice by asking the reducer what it does with nothing. That is
	-- the same convention Redux uses, and it means a slice's initial value
	-- lives with its reducer rather than in a second table somewhere else.
	if state[slice] == nil then
		state[slice] = reducer(nil, { type = "@@init" })
	end
	dispatchChain = nil
end

--[[
	Add a wrapper around every dispatch.

	Order is the order added: the first added is the outermost, so it sees the
	action first and the result last. Replication goes last (innermost) so it
	only sees actions that survived everything before it.
]]
function Store.use(fn: Middleware)
	table.insert(middleware, fn)
	dispatchChain = nil
end

-- ================================= dispatch =================================
local function bareDispatch(action: Action): Action
	if typeof(action) ~= "table" or typeof(action.type) ~= "string" then
		error("[Store] an action must be a table with a string `type`", 3)
	end

	dispatched += 1
	for slice, reducer in reducers do
		local before = state[slice]
		local after = reducer(before, action)
		if after ~= before then
			state[slice] = after
			for _, subscriber in subscribers[slice] or {} do
				-- Each on its own thread: a subscriber that errors must not
				-- stop the others from hearing about a change they need.
				task.spawn(subscriber, after, before)
			end
			Store.changed:Fire(slice, after, before, action)
		end
	end
	return action
end

local function build(): (Action) -> any
	local chain = bareDispatch
	-- Applied in reverse so the first registered ends up outermost.
	for index = #middleware, 1, -1 do
		chain = middleware[index](chain, Store)
	end
	return chain
end

--[[
	Change the state.

	A function may be dispatched instead of an action — the thunk convention.
	It receives `dispatch` and `getState`, which is how anything asynchronous
	(a DataStore read, a wait, a chain of steps) participates without reducers
	ever becoming impure.
]]
function Store.dispatch(action: any): any
	if typeof(action) == "function" then
		return action(Store.dispatch, Store.getState)
	end
	if not dispatchChain then
		dispatchChain = build()
	end
	return (dispatchChain :: (Action) -> any)(action)
end

-- ================================= reading ==================================
function Store.get(slice: string): any
	return state[slice]
end

function Store.getState(): { [string]: any }
	-- A shallow copy, so a caller that mutates what it reads corrupts its own
	-- copy rather than the store. Shallow rather than deep because reducers
	-- already return fresh tables for anything that changed.
	return table.clone(state)
end

--[[
	Hear about changes to one slice.

	Returns an unsubscribe. Per slice rather than global because a global
	subscription fires on every action in the game and every subscriber then
	starts with `if action.type ~= mine then return end`, which is a filter
	written thirty times.
]]
function Store.subscribe(slice: string, fn: (new: any, old: any) -> ()): () -> ()
	local list = subscribers[slice]
	if not list then
		list = {}
		subscribers[slice] = list
	end
	table.insert(list, fn)

	return function()
		local index = table.find(list, fn)
		if index then
			table.remove(list, index)
		end
	end
end

--[[
	Load state directly, bypassing reducers.

	For rehydrating a client from a server snapshot, and for tests. Deliberately
	not called `setState`: it is a restore, and using it as a shortcut for a
	change is how a game ends up with state nothing can explain.
]]
function Store.hydrate(slices: { [string]: any })
	for slice, value in slices do
		local before = state[slice]
		state[slice] = value
		for _, subscriber in subscribers[slice] or {} do
			task.spawn(subscriber, value, before)
		end
	end
end

function Store.describe(): { [string]: any }
	local slices = {}
	for slice in reducers do
		table.insert(slices, slice)
	end
	table.sort(slices)

	local watchers: { [string]: number } = {}
	for slice, list in subscribers do
		watchers[slice] = #list
	end

	return {
		slices = slices,
		middleware = #middleware,
		dispatched = dispatched,
		subscribers = watchers,
	}
end

function Store.reset()
	table.clear(reducers)
	table.clear(state)
	table.clear(middleware)
	table.clear(subscribers)
	dispatchChain = nil
	dispatched = 0
end

return Store
