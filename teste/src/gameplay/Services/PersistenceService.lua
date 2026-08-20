--!strict
local DataStoreService
pcall(function()
	DataStoreService = game:GetService("DataStoreService")
end)

local PersistenceService = {}
PersistenceService.__index = PersistenceService

export type PlayerSaveData = {
	scraps: number,
	level: number,
	xp: number,
	equippedWeapon: string,
	equippedSkin: string,
	unlockedWeapons: { string },
	unlockedSkins: { string },
	ammo: { [string]: number },
	upgrades: { [string]: number },
	highestWave: number,
	totalKills: number,
	armor: number,
}

function PersistenceService.new(storeName: string)
	local self = setmetatable({}, PersistenceService)
	self._storeName = storeName
	self._store = nil
	self._memoryCache = {} :: { [any]: PlayerSaveData }
	self._memoryStore = {} :: { [string]: PlayerSaveData }

	if DataStoreService then
		pcall(function()
			self._store = DataStoreService:GetDataStore(storeName)
		end)
	end
	return self
end

function PersistenceService:defaultData(): PlayerSaveData
	return {
		scraps = 150, -- Starting funds for pistol ammo or knife upgrade
		level = 1,
		xp = 0,
		equippedWeapon = "service_pistol",
		equippedSkin = "default_factory",
		unlockedWeapons = { "combat_knife", "service_pistol" },
		unlockedSkins = { "default_factory" },
		ammo = {
			Pistol = 48,
			Shotgun = 16,
			Rifle = 90,
			Sniper = 10,
			Heavy = 0,
		},
		upgrades = {},
		highestWave = 1,
		totalKills = 0,
		armor = 25,
	}
end

function PersistenceService:load(player: any): PlayerSaveData
	local key = "Player_" .. tostring(player.UserId)
	local defaults = self:defaultData()

	if self._store == nil then
		local cached = self._memoryStore[key]
		if type(cached) == "table" then
			self._memoryCache[player] = table.clone(cached)
		else
			self._memoryCache[player] = table.clone(defaults)
		end
		return self._memoryCache[player]
	end

	local success, result = pcall(function()
		return self._store:GetAsync(key)
	end)

	local data: PlayerSaveData = defaults
	if success and type(result) == "table" then
		for k, v in pairs(result) do
			(data :: any)[k] = v
		end
	end

	self._memoryCache[player] = data
	return data
end

function PersistenceService:get(player: any): PlayerSaveData?
	return self._memoryCache[player]
end

function PersistenceService:save(player: any, data: PlayerSaveData): boolean
	self._memoryCache[player] = data
	local key = "Player_" .. tostring(player.UserId)

	if self._store == nil then
		self._memoryStore[key] = table.clone(data)
		return true
	end

	local success, _ = pcall(function()
		self._store:SetAsync(key, data)
	end)

	return success
end

function PersistenceService:clear(player: any)
	self._memoryCache[player] = nil
end

return PersistenceService
