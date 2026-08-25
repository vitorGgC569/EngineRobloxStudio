--!strict
--[[
	Replication — sending state changes to the clients that are allowed them.

	The mistake this exists to prevent
	----------------------------------

	The obvious way to replicate a store is to send every action to everybody
	and let each client run the same reducers. It is one line of middleware, it
	works immediately, and it hands every player the whole server's state —
	other players' inventories, unrevealed cards, where the enemies are before
	they can be seen, the answer to the puzzle.

	Roblox clients can read anything they receive. There is no such thing as a
	value the client has and is not allowed to look at. So replication is not a
	transport problem, it is a **permission** problem, and the filter has to be
	decided per action and per player on the server.

		Replication.rule("inventory", function(action, player)
			return action.player == tostring(player.UserId)
		end)

		Store.use(Replication.middleware(function(action, player)
			Net.fire(player, "StoreAction", action)
		end))

	Actions, not state
	------------------

	Sending the action rather than the new state keeps the wire small — an
	action is a verb and a couple of fields, where a slice can be the whole
	room — and it lets the client's reducer produce the same result the server
	did. The cost is that the client must have the same reducers, which is a
	real constraint and the reason `snapshot` exists for the join case.
]]

local Players = game:GetService("Players")

local Replication = {}

export type Filter = (action: any, player: Player) -> boolean

local rules: { [string]: Filter } = {}
local publicTypes: { [string]: boolean } = {}
local sent = 0
local withheld = 0

--[[
	Whether an action nobody wrote a rule for is sent.

	False, and this is the important default in the module. An action type
	added next month with no rule is withheld rather than broadcast: the
	failure mode of forgetting a rule becomes "a client did not update", which
	somebody notices and fixes, instead of "everybody can read everything",
	which nobody notices at all.
]]
Replication.openByDefault = false

-- ================================== rules ===================================
--[[
	Decide who may see this kind of action.

	Keyed by action type. The filter gets the action and one player and answers
	yes or no — which is enough for the three cases that come up: everybody
	(return true), only the owner (compare an id), and only a group (look it
	up).
]]
function Replication.rule(actionType: string, filter: Filter)
	rules[actionType] = filter
end

function Replication.rules(table_: { [string]: Filter })
	for actionType, filter in table_ do
		Replication.rule(actionType, filter)
	end
end

--: Everyone may see this. Named rather than `rule(t, function() return true end)`
--: so that a public action is obviously a decision somebody made.
function Replication.public(...: string)
	for _, actionType in { ... } do
		publicTypes[actionType] = true
	end
end

function Replication.mayReceive(action: any, player: Player): boolean
	if publicTypes[action.type] then
		return true
	end
	local filter = rules[action.type]
	if not filter then
		return Replication.openByDefault
	end
	local ok, allowed = pcall(filter, action, player)
	if not ok then
		-- A filter that errors withholds. The alternative is a broken filter
		-- becoming an open door, which is exactly the wrong way for a
		-- permission check to fail.
		warn(string.format("[Replication] the rule for '%s' errored; withholding",
			tostring(action.type)))
		return false
	end
	return allowed == true
end

-- ================================ middleware ================================
--[[
	The store middleware that sends actions on.

	`send` is supplied rather than assumed, so this module never touches a
	RemoteEvent and stays testable: a test passes a function that records what
	it was given and asserts on who got what.

	Replication happens **after** the reducer has run, so an action rejected by
	earlier middleware never reaches a client, and the state the server sends
	is the state the server actually has.
]]
function Replication.middleware(send: (action: any, player: Player) -> ())
	return function(nextDispatch, _store)
		return function(action)
			local result = nextDispatch(action)

			-- `local` on purpose: replication is a server duty, and a client
			-- store running this would be sending actions to itself.
			for _, player in Players:GetPlayers() do
				if Replication.mayReceive(action, player) then
					sent += 1
					task.spawn(send, action, player)
				else
					withheld += 1
				end
			end

			return result
		end
	end
end

-- ================================= snapshot =================================
--[[
	What a joining player is allowed to know right now.

	A client that only ever receives actions has missed everything that
	happened before it joined. It needs one state dump, filtered the same way
	the actions are — which is the part that is easy to get wrong, because the
	snapshot is a different code path and a filter applied to one and not the
	other is a leak that only appears on join.

	`sliceFilters` answers per slice what `rules` answers per action, and both
	default closed.
]]
local sliceFilters: { [string]: (state: any, player: Player) -> any } = {}

--[[
	How one slice is trimmed for one player.

	The filter returns what that player may see — usually the whole slice, or
	just their own entry. Returning nil withholds the slice entirely.
]]
function Replication.slice(name: string, filter: (state: any, player: Player) -> any)
	sliceFilters[name] = filter
end

function Replication.snapshot(state: { [string]: any }, player: Player): { [string]: any }
	local out: { [string]: any } = {}
	for name, value in state do
		local filter = sliceFilters[name]
		if filter then
			local ok, allowed = pcall(filter, value, player)
			if ok and allowed ~= nil then
				out[name] = allowed
			end
		elseif Replication.openByDefault then
			out[name] = value
		end
	end
	return out
end

function Replication.describe(): { [string]: any }
	local ruled = {}
	for actionType in rules do
		table.insert(ruled, actionType)
	end
	for actionType in publicTypes do
		table.insert(ruled, actionType .. " (public)")
	end
	table.sort(ruled)

	local slices = {}
	for name in sliceFilters do
		table.insert(slices, name)
	end
	table.sort(slices)

	return {
		openByDefault = Replication.openByDefault,
		actionRules = ruled,
		sliceFilters = slices,
		sent = sent,
		--[[
			The number worth watching.

			A withheld count of zero on a game with private state means every
			action is public, which is either correct or a leak — and it is
			worth having to decide which.
		]]
		withheld = withheld,
	}
end

function Replication.reset()
	table.clear(rules)
	table.clear(publicTypes)
	table.clear(sliceFilters)
	sent = 0
	withheld = 0
end

return Replication
