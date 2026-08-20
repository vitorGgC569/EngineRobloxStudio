--!strict
--- Across servers, and across what a player is allowed to be shown.
---
--- Three services at zero, and they are here together because each one is the
--- part of a live game that a single-server demo never needs:
---
---   MessagingService   servers talking to each other
---   MemoryStore        state that outlives one server and expires on its own
---   PolicyService      what this particular player may legally be shown
---
--- **PolicyService is the compliance one, and it is the least known.** Roblox
--- decides per player -- by age, by country, by account -- whether they may be
--- shown paid random items, whether external links may be offered, and whether
--- trading is permitted. A game that shows a loot box to a player whose policy
--- forbids it is not making a design mistake; it is breaking a rule that is
--- enforced. The same shape as the chat filter: not taste, policy.
---
--- **The safe answer when the policy cannot be read is no.** A network failure
--- returns the restrictive default here, never the permissive one. Defaulting
--- to "allowed" means an outage silently turns compliance off for everybody,
--- which is the worst possible time for it.
---
--- **MemoryStore is not a DataStore.** It is fast, it expires, and it is shared
--- across the whole universe -- right for a matchmaking queue or a global
--- counter, wrong for a player's inventory. Using it for saves loses them, and
--- the loss is silent because expiry is not an error.

local MessagingService = game:GetService("MessagingService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local PolicyService = game:GetService("PolicyService")
local RunService = game:GetService("RunService")

local Reach = {}

-- -- policy --------------------------------------------------------------------

--- The restrictive answer, used whenever the real one cannot be had.
local DENIED = {
	ArePaidRandomItemsRestricted = true,
	AllowedExternalLinkReferences = {},
	IsPaidItemTradingAllowed = false,
	IsSubjectToChinaPolicies = true,
}

local policyCache: { [number]: { [string]: any } } = {}

--- What this player may be shown. Cached per player for the session.
function Reach.policy(player: Player): { [string]: any }
	local cached = policyCache[player.UserId]
	if cached ~= nil then
		return cached
	end
	local ok, result = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	if not ok or type(result) ~= "table" then
		warn("[Reach] policy unavailable for " .. player.Name
			.. "; assuming the restrictive default")
		-- Not cached: an outage must not pin a player to the restrictive answer
		-- for their whole session once the service comes back.
		return DENIED
	end
	policyCache[player.UserId] = result
	return result
end

--- May this player be shown paid random items -- loot boxes, gacha, crates?
function Reach.mayShowRandomPaidItems(player: Player): boolean
	return Reach.policy(player).ArePaidRandomItemsRestricted ~= true
end

--- May this player be offered a link out of the game?
function Reach.mayLinkTo(player: Player, url: string): boolean
	local allowed = Reach.policy(player).AllowedExternalLinkReferences
	if type(allowed) ~= "table" then
		return false
	end
	for _, reference in ipairs(allowed) do
		if string.find(string.lower(url), string.lower(tostring(reference)), 1, true) then
			return true
		end
	end
	return false
end

function Reach.mayTrade(player: Player): boolean
	return Reach.policy(player).IsPaidItemTradingAllowed == true
end

-- -- cross-server ---------------------------------------------------------------

local topics: { [string]: RBXScriptConnection } = {}

--- Everything wrong with a topic name, before anything is published on it.
function Reach.topicProblems(topic: string): { string }
	local found = {}
	if type(topic) ~= "string" or topic == "" then
		table.insert(found, "a topic needs a name")
		return found
	end
	if #topic > 80 then
		table.insert(found, "topic names are capped at 80 characters")
	end
	return found
end

--- Listen for messages from other servers.
function Reach.listen(topic: string, handle: (any) -> ()): (boolean, string?)
	if not RunService:IsServer() then
		return false, "cross-server messages are received on the server"
	end
	local problems = Reach.topicProblems(topic)
	if #problems > 0 then
		return false, problems[1]
	end

	Reach.deafen(topic)
	local ok, connection = pcall(function()
		return MessagingService:SubscribeAsync(topic, function(message)
			-- The payload arrives wrapped; handlers want the data, and the
			-- wrapper is the single most common source of "my message is nil".
			local ok2, err = pcall(handle, (message :: any).Data)
			if not ok2 then
				warn("[Reach] " .. topic .. ": " .. tostring(err))
			end
		end)
	end)
	if not ok then
		return false, tostring(connection)
	end
	topics[topic] = connection
	return true, nil
end

--- Send to every other server running this experience.
---
--- Rate limited by Roblox and **not delivered to the sender**. A game that
--- updates its own state only in the subscriber never sees its own change,
--- which looks exactly like the message never arriving.
function Reach.publish(topic: string, payload: any): (boolean, string?)
	if not RunService:IsServer() then
		return false, "cross-server messages are published from the server"
	end
	local ok, err = pcall(function()
		MessagingService:PublishAsync(topic, payload)
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

function Reach.deafen(topic: string): boolean
	local connection = topics[topic]
	if connection == nil then
		return false
	end
	connection:Disconnect()
	topics[topic] = nil
	return true
end

-- -- shared, expiring state -----------------------------------------------------

--- A sorted map shared by every server: leaderboards, queues, live counters.
---
--- `expiry` is required rather than defaulted. MemoryStore entries expire, and
--- a caller who does not choose a lifetime has not understood that -- which is
--- how an inventory ends up here and quietly disappears.
function Reach.shared(name: string, key: string, value: any,
	expiry: number): (boolean, string?)

	if type(expiry) ~= "number" or expiry <= 0 then
		return false, "MemoryStore entries expire; choose a lifetime in seconds. "
			.. "If nothing should expire, this is the wrong service -- use a DataStore"
	end
	local ok, err = pcall(function()
		local map = MemoryStoreService:GetSortedMap(name)
		map:SetAsync(key, value, expiry)
	end)
	if not ok then
		return false, tostring(err)
	end
	return true, nil
end

function Reach.readShared(name: string, key: string): (any, string?)
	local ok, value = pcall(function()
		local map = MemoryStoreService:GetSortedMap(name)
		return map:GetAsync(key)
	end)
	if not ok then
		return nil, tostring(value)
	end
	return value, nil
end

function Reach.report(): { [string]: any }
	local listening = {}
	for topic in pairs(topics) do
		table.insert(listening, topic)
	end
	table.sort(listening)

	local cached = 0
	for _ in pairs(policyCache) do
		cached += 1
	end

	return {
		topics = listening,
		policiesCached = cached,
		restrictiveDefault = DENIED.ArePaidRandomItemsRestricted,
		notes = {
			"PublishAsync does not deliver to the sender",
			"MemoryStore expires; it is not a save",
			"an unreadable policy denies rather than allows",
		},
	}
end

return Reach
