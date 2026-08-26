local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.Negativity

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #2"

ButtonInfo.Effect = {
	Generation = {
		Mul = function(amount: number)
			return Balance.new():set("Bocchi", AlyaNum.new(1.15):pow(amount))
		end
	}
}

ButtonInfo.Descriptions = {
	Default = `you NEED to get 10K BOCCHI to REACH MY LEVEL! then you will TRULY be the BEST BOCCHI MAKER, BOOSTING X{ButtonInfo.Effect.Generation.Mul(1):toString()}. oh btw u can buy this infinitely`
}

local s = AlyaNum.new(2500)
local t = AlyaNum.new(10000)
local o = AlyaNum.new(1.25)
ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", t:mul(o:pow(nextAmount)):sub(s))
end

return ButtonInfo
