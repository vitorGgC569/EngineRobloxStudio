--!optimize 2

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local Currency = require(ReplicatedStorage.Currency)
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Lumin = require(ReplicatedStorage.Packages.framework)
local ProfileService = require(ServerStorage.ServerPackages.profileservice)

local DataController = {}

DataController.ServerProfileTemplate = {
	Name = "no name",
	Owner = 0,
	Created = 0,
	Playtime = 0,
	LongestSession = 0,
	AccessCode = "",

	Managers = {1021594469},
	Trusted = {1021594469},
	Banned = {0},
	Logs = {},
	PermLevels = {
		Purchase = 0,
		Reset = 0
	},
	GlobalChat = true,

	Buttons = {} :: {[string]: number},
	Upgrades = {} :: {[number]: number},
	Currencies = {
		Bocchi = AlyaNum.new(0)
	} :: {[Currency.Currency]: AlyaNum.BaseAlyaNum},
	MostCurrencies = {}
}
if (RunService:IsStudio() and ServerScriptService.Debug.ServerId:GetAttribute("Active") == true) then
	local id = ServerScriptService.Debug.ServerId:GetAttribute("Resets") == true and game:GetService("HttpService"):GenerateGUID() or ServerScriptService.Debug.ServerId.Value
	local userId = 0
	if (ServerScriptService.Debug.Individual.Value == true) then
		userId = game:GetService("Players").PlayerAdded:Wait().UserId
		id ..= userId
	end
	DataController.ServerId = id
	DataController.ServerOwner = userId
else
	DataController.ServerId = game.PrivateServerId == "" and game.JobId or game.PrivateServerId
	DataController.ServerOwner = game.PrivateServerOwnerId
end

DataController.ServerProfileStore = ProfileService.GetProfileStore("ServerData", DataController.ServerProfileTemplate)
DataController.ServerProfile = DataController.ServerProfileStore:LoadProfileAsync(DataController.ServerId)

function DataController:CheckPermLevel(player: Player, action: string)
	local minimumPerm = DataController.ServerProfile.Data.PermLevels[action]
	local permLevel = player:GetAttribute("PermissionLevel") :: number
	return minimumPerm ~= nil and permLevel ~= nil and permLevel >= minimumPerm
end


function DataController:Init()
	workspace:SetAttribute("ServerId", DataController.ServerId)
	DataController.ServerProfile:Reconcile()
	for id, amount in pairs(DataController.ServerProfile.Data.Buttons) do
		if (type(id) == "number") then
			DataController.ServerProfile.Data.Buttons["B" .. id] = amount
			DataController.ServerProfile.Data.Buttons[id] = nil
		end
	end
	DataController.ServerProfile.Data.Owner = DataController.ServerOwner
	task.spawn(function()
		DataController.ServerProfile.Data.Name = `{Players:GetNameFromUserIdAsync(DataController.ServerOwner)}'s Server`
	end)
end

function DataController:RefreshPermLevel(player: Player)
	local data = DataController.ServerProfile.Data
	if (data.Owner == player.UserId) then
		player:SetAttribute("PermissionLevel", 3)
		
	elseif (table.find(data.Banned, player.UserId)) then
		player:SetAttribute("PermissionLevel", -1)
		
	elseif (table.find(data.Managers, player.UserId)) then
		player:SetAttribute("PermissionLevel", 2)
		
	elseif (table.find(data.Trusted, player.UserId)) then
		player:SetAttribute("PermissionLevel", 1)
		
	else
		player:SetAttribute("PermissionLevel", 0)
	end
end

function DataController:OnPlayerAdded(player: Player)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player
	
	DataController:RefreshPermLevel(player)
end


return DataController