--!strict
-- Global all-time leaderboards (wins + conversions) on OrderedDataStores. Every DataStore
-- call is pcall-guarded, so if Studio API access is disabled or a request fails the game is
-- entirely unaffected — the boards just stay empty. Entries update at round end (low write
-- frequency) and the top lists refresh on a timer + broadcast to clients.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local LeaderboardService = {}
LeaderboardService.__index = LeaderboardService

export type Deps = {
	remotes: any,
	dataService: any,
}

local METRICS = {
	{ key = "wins", store = "lb_wins_v1", title = "WINS" },
	{ key = "conversions", store = "lb_conversions_v1", title = "CONVERSIONS" },
}

local TOP_N = 10
local REFRESH_SECONDS = 90

function LeaderboardService.new(deps: Deps)
	local self = setmetatable({}, LeaderboardService)
	self._deps = deps
	self._stores = {} :: { [string]: OrderedDataStore }
	self._nameCache = {} :: { [number]: string }
	self._latest = {} :: { [string]: { any } }
	for _, metric in METRICS do
		local ok, store = pcall(function()
			return DataStoreService:GetOrderedDataStore(metric.store)
		end)
		if ok then
			self._stores[metric.key] = store
		end
	end
	return self
end

function LeaderboardService:_nameFor(userId: number): string
	local cached = self._nameCache[userId]
	if cached then
		return cached
	end
	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	local resolved = (ok and name) or ("Player " .. userId)
	self._nameCache[userId] = resolved
	return resolved
end

-- Push a player's current totals into the ordered stores (round-end frequency).
function LeaderboardService:recordFor(player: Player)
	local data = self._deps.dataService:get(player)
	if data == nil then
		return
	end
	for _, metric in METRICS do
		local store = self._stores[metric.key]
		local value = data.stats[metric.key]
		if store and type(value) == "number" then
			pcall(function()
				store:SetAsync(tostring(player.UserId), value)
			end)
		end
	end
end

function LeaderboardService:onRoundEnd(players: { Player })
	for _, player in players do
		self:recordFor(player)
	end
end

function LeaderboardService:refresh()
	local payload = {}
	for _, metric in METRICS do
		local store = self._stores[metric.key]
		local list = {}
		if store then
			local ok, pages = pcall(function()
				return store:GetSortedAsync(false, TOP_N)
			end)
			if ok and pages then
				local okPage, top = pcall(function()
					return pages:GetCurrentPage()
				end)
				if okPage and top then
					for _, entry in top do
						local userId = tonumber(entry.key)
						if userId then
							table.insert(list, { name = self:_nameFor(userId), value = entry.value })
						end
					end
				end
			end
		end
		payload[metric.key] = list
	end
	self._latest = payload
	self._deps.remotes.fireAllClients("Leaderboard", payload)
end

function LeaderboardService:pushTo(player: Player)
	if next(self._latest) ~= nil then
		self._deps.remotes.fireClient("Leaderboard", player, self._latest)
	end
end

function LeaderboardService:start()
	task.spawn(function()
		while true do
			self:refresh()
			task.wait(REFRESH_SECONDS)
		end
	end)
	Players.PlayerAdded:Connect(function(player)
		task.delay(2, function()
			self:pushTo(player)
		end)
	end)
end

return LeaderboardService
