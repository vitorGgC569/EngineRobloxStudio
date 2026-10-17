--!strict
--[[
	Presentation — afternoon on the marsh.

	Brightness stays low on purpose. A bright fill plus a pale ambient
	washes the salt out, and a field of point lights does the same.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Presentation = {}

local function rgb(name: string): Color3
	local color = Config.colors[name]
	return Color3.fromRGB(color[1], color[2], color[3])
end

function Presentation.start()
	pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	Lighting.ClockTime = 17.45
	Lighting.Brightness = 2
	Lighting.Ambient = Color3.fromRGB(58, 62, 58)
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 112, 92)
	Lighting.ColorShift_Top = Color3.fromRGB(255, 214, 170)
	Lighting.ColorShift_Bottom = Color3.fromRGB(70, 90, 88)
	Lighting.FogColor = rgb("fog")
	Lighting.FogStart = 220
	Lighting.FogEnd = 980
	Lighting.GlobalShadows = true
	pcall(function()
		Lighting.EnvironmentDiffuseScale = 0.35
		Lighting.EnvironmentSpecularScale = 0.25
	end)

	if not Lighting:FindFirstChild("SaltmereGrade") then
		local grade = Instance.new("ColorCorrectionEffect")
		grade.Name = "SaltmereGrade"
		grade.TintColor = Color3.fromRGB(255, 236, 214)
		grade.Saturation = 0.12
		grade.Contrast = 0.06
		grade.Brightness = 0.02
		grade.Parent = Lighting
	end
	if not Lighting:FindFirstChild("SaltmereBloom") then
		local bloom = Instance.new("BloomEffect")
		bloom.Name = "SaltmereBloom"
		bloom.Intensity = 0.28
		bloom.Size = 16
		bloom.Threshold = 0.95
		bloom.Parent = Lighting
	end

	local existing = Lighting:FindFirstChild("SaltmereAtmosphere")
	if not existing then
		pcall(function()
			local atmosphere = Instance.new("Atmosphere")
			atmosphere.Name = "SaltmereAtmosphere"
			atmosphere.Density = 0.28
			atmosphere.Offset = 0.15
			atmosphere.Color = rgb("fog")
			atmosphere.Decay = rgb("brine")
			atmosphere.Glare = 0.1
			atmosphere.Haze = 1.2
			atmosphere.Parent = Lighting
		end)
	end

	Debug.probe("presentation", function()
		return {
			clock = Lighting.ClockTime,
			brightness = Lighting.Brightness,
		}
	end)
end

return Presentation
