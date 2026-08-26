local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local DataController = require(ServerScriptService.Controllers.DataController)
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local constants = require(ReplicatedStorage.constants)

local LeaderboardController = {}
LeaderboardController.bocchiStore = DataStoreService:GetOrderedDataStore("Bocchi")
LeaderboardController.totalTimeStore = DataStoreService:GetOrderedDataStore("TotalTime")
LeaderboardController.banned = { 1900444407 }

type Leaderboard = typeof(workspace.Leaderboards.Bocchi)

function LeaderboardController:getLeaderboardSlot(place: number, name: string, amount: number)
	local lbSlot = constants.ASSETS.LeaderboardSlot:Clone()
	lbSlot.ServerLabel.Text = name
	lbSlot.AmountLabel.Text = tostring(AlyaNum.fromSingle(amount))
	lbSlot.PlaceLabel.Text = tostring(place)
	lbSlot.LayoutOrder = place
	return lbSlot
end
function LeaderboardController:resetLeaderboard(leaderboard: Leaderboard)
	for _, l in leaderboard.GuiPart.SurfaceGui.Display:GetChildren() do
		if l.Name == "LeaderboardSlot" then
			l:Destroy()
		end
	end
end
function LeaderboardController:updateLeaderboardStore(store: OrderedDataStore, name: string, amount: number)
	--if name ~= "no name" and name ~= nil and not RunService:IsStudio() then
	if name ~= "no name" and name ~= nil then
		store:SetAsync(name, amount)
	end
	local data = store:GetSortedAsync(false, 100)
	return data:GetCurrentPage()
end

function LeaderboardController:updateLeaderboard(leaderboard: Leaderboard, lbDatas: {{key: string, value: number}})
	LeaderboardController:resetLeaderboard(leaderboard)
	local i = 1
	for _, data in lbDatas do
		if data == nil then
			continue
		end
		LeaderboardController:getLeaderboardSlot(i, data.key, data.value).Parent = leaderboard.GuiPart.SurfaceGui.Display
		i += 1
	end
end
function LeaderboardController:updateLeaderboards()
	local data = DataController.ServerProfile.Data

	if table.find(LeaderboardController.banned, data.Owner) ~= nil then
		return nil
	end
	
	local name = data.Name
	
	LeaderboardController:updateLeaderboard(workspace.Leaderboards.Playtime, 
		LeaderboardController:updateLeaderboardStore(LeaderboardController.totalTimeStore, name, AlyaNum.new(data.Playtime):toSingle()))
	local value = data.MostCurrencies.Bocchi
	if value ~= nil then
		LeaderboardController:updateLeaderboard(workspace.Leaderboards.Bocchi, 
			LeaderboardController:updateLeaderboardStore(LeaderboardController.bocchiStore, name, AlyaNum.new(value):toSingle()))
	end
end

function LeaderboardController:Init()
	task.spawn(function()
		LeaderboardController:updateLeaderboards()
		while task.wait(30) do
			LeaderboardController:updateLeaderboards()
		end
	end)
end

return LeaderboardController
