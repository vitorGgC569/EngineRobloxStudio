--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local UI = Forge.UI
local Net = Forge.Net

local Hud = {}
local player = Players.LocalPlayer

function Hud.init()
	local screen = UI.mount("Hud")

	local vitals = UI.panel(screen, {
		size = UDim2.fromOffset(260, 80),
		pos = UDim2.new(0, 18, 1, -98),
		transparency = 0.2,
	})

	local hpBar = UI.bar(vitals, {
		color = Color3.fromRGB(220, 60, 80),
		size = UDim2.fromOffset(228, 18),
		pos = UDim2.fromOffset(16, 14),
	})
	local hpText = UI.label(hpBar.holder, "HP 100/100", {
		size = 12,
		align = Enum.TextXAlignment.Center,
	})

	local xpBar = UI.bar(vitals, {
		color = Color3.fromRGB(120, 80, 200),
		size = UDim2.fromOffset(228, 10),
		pos = UDim2.fromOffset(16, 42),
	})

	UI.label(screen, "Q: Slash  E: Fireball  Shift: Dash", {
		size = 14,
		pos = UDim2.new(0.5, -140, 1, -28),
	})
end

return Hud