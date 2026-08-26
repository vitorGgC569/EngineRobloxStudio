local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local constants = require(ReplicatedStorage.constants)
local Lumin = require(ReplicatedStorage.Packages.framework)
local Packets = require(ReplicatedStorage.Packets)
local CubeController = {}

CubeController.Cube = workspace:WaitForChild("Buttons"):WaitForChild("B32"):WaitForChild("Cube")
CubeController.Sound = CubeController.Cube:WaitForChild("ClickPart"):WaitForChild("Sound")

CubeController.Cube.Highlight.Enabled = false

local t = 0

function CubeController:OnCubeClicked()
	local highlight = CubeController.Cube.Highlight
	highlight.Enabled = true
	highlight.FillTransparency = 0.5
	highlight.OutlineTransparency = 0
	TweenService:Create(highlight, TweenInfo.new(0.5), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
	t = tick() + 0.17
	CubeController.Sound:Resume()
end


function CubeController:Init()

	RunService.Heartbeat:Connect(function()
		if tick() > t and CubeController.Sound.IsPlaying then
			CubeController.Sound:Pause()
		end
	end)
	
	Packets.cubeClicked.listen(function()
		CubeController:OnCubeClicked()
	end)
	
end


return CubeController