--!strict
-- Live (no-republish) config tuning. Loads an override table from a DataStore and applies
-- the whitelisted, validated tunables onto GameConfig in place, then re-polls so changes
-- take effect on the next round without shipping a new place version. Everything is
-- pcall-guarded and skipped in Studio (where the fast-timer test setup owns the config),
-- so it can never break a live server: a missing/failed/bad override just leaves defaults.
--
-- To change a value live: set the DataStore "LiveConfig_v1" key "overrides" to a table like
--   { ["Round.IntermissionSeconds"] = 30, ["Bots.TargetPlayers"] = 10 }
-- (via the Creator Hub DataStore editor or an admin script). See LiveConfig.Whitelist.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local LiveConfig = require(Shared.LiveConfig)

local POLL_SECONDS = 120

local LiveConfigService = {}
LiveConfigService.__index = LiveConfigService

function LiveConfigService.new()
	local self = setmetatable({}, LiveConfigService)
	self._store = nil
	if not RunService:IsStudio() then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore("LiveConfig_v1")
		end)
		if ok then
			self._store = store
		end
	end
	return self
end

function LiveConfigService:_load()
	if self._store == nil then
		return
	end
	local ok, overrides = pcall(function()
		return self._store:GetAsync("overrides")
	end)
	if not ok or type(overrides) ~= "table" then
		return
	end
	local result = LiveConfig.apply(GameConfig, overrides, LiveConfig.Whitelist)
	for key, value in result.applied do
		print(("[LiveConfig] applied %s = %s"):format(key, tostring(value)))
	end
	for key, reason in result.rejected do
		warn(("[LiveConfig] rejected %s (%s)"):format(key, reason))
	end
end

function LiveConfigService:start()
	if self._store == nil then
		return
	end
	task.spawn(function()
		while true do
			self:_load()
			task.wait(POLL_SECONDS)
		end
	end)
end

return LiveConfigService
