local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Friendliness

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #3"
ButtonInfo.MaxAmount = 7

local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			local boost = math.pow(1.65, amount)
			headingLabel.Text = `currently {math.floor(boost * 100) / 100}x`
			return Balance.new():set("Nijika", boost)
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `I HATE YOU. x1.65 nijika compounding.`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Nijika", 80 * math.pow(3, nextAmount))
end

return ButtonInfo
