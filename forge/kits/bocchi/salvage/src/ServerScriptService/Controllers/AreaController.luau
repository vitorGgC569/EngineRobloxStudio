--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Lumin = require(ReplicatedStorage.Packages.framework)

local AreaController = {}

function AreaController:Init()
	for i, area in pairs(workspace:GetChildren()) do
		if (not area:IsA("Folder")) then
			continue
		end
		local mapFolder = area:FindFirstChild("Map")
		if (mapFolder == nil) then
			continue
		end
		local temp = Instance.new("Model")
		mapFolder.Parent = temp
		temp.Parent = area
		local boundingBox = Instance.new("Part")
		local cframe, size = temp:GetBoundingBox()
		boundingBox.CFrame = cframe
		boundingBox.Size = size
		boundingBox.Transparency = 1
		boundingBox.CanCollide = false
		boundingBox.Anchored = true
		mapFolder.Parent = area
		boundingBox.Parent = area
		temp:Destroy()
	end
end

function AreaController:OnPlayerAdded(player: Player)
	local leaderstats = player:WaitForChild("leaderstats")
	local areaValue = Instance.new("StringValue")
	areaValue.Name = "Area"
	areaValue.Value = "Bocchiria"
	areaValue.Parent = leaderstats
end


return AreaController