local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Negativity

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #1"
ButtonInfo.MaxAmount = 1

local orb = script["BOCCHIRIUM ORB OF BOCCHER"]
local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
local lastRecharge = tick()
ButtonInfo.Effect = {
	Generation = {
		IsVariable = true,
		Mul = function(amount: number)
			local t = tick()
			if (t - lastRecharge > 60) then
				for i, player in pairs(Players:GetPlayers()) do
					lastRecharge = t
					if (player.Backpack:FindFirstChild(orb.Name) ~= nil) then
						continue
					end
					local clone = orb:Clone()
					for i, v in pairs(clone:GetChildren()) do
						if (v:IsA("BasePart")) then
							v.Anchored = false
						end
					end
					clone.Parent = player.Backpack
				end
			end
			local duration = script.Parent:GetAttribute("Duration")
			headingLabel.Text = `{math.floor(duration)}S LEFT, RECHARGING IN {math.floor(60 - t + lastRecharge)}S`
			if (duration <= 0) then
				return Balance.new()
			end
			
			if (Utils.Buttons["B24"] > 0) then
				return Balance.new():set("Bocchi", 3):set("Nijika", 2)
			end
			
			
			return Balance.new():set("Bocchi", 2)
		end
	},
	OnPurchase = function()
		lastRecharge = 0
		RunService.Heartbeat:Connect(function(dt)
			local n = script.Parent:GetAttribute("Duration") - dt
			script.Parent:SetAttribute("Duration", n < 0 and 0 or n)
		end)
	end,
}

ButtonInfo.Descriptions = {
	Default = `I think it's clear. It's clear that you're a Bocchi master. You are thereby awarded the {orb.Name}, CONSUMING IT WILL BOOST YOUR BOCCHI GAIN BY X2 FOR 30 SECONDS`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 200)
end

ButtonInfo.Roots = {"B7"}

return ButtonInfo
