local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Formula = require(ReplicatedStorage.Formula)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.FelixTheA

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #2"
ButtonInfo.MaxAmount = 1

script.Parent.Boosts.Position -= Vector3.new(0, 200, 0)
ButtonInfo.Effect = {
	Shrine = {
		IsVariable = true
	},
	Cube = {
		Add = function()
			return Balance.new():set("Drums", 1)
		end
	},
	OnPurchase = function()
		local guitarFormula = Formula.new():log(6):pow(2):div(12):add(1) :: Formula.Formula
		local kitaFormula = Formula.new():div(1e9):log(8):pow(2):div(12):add(1) :: Formula.Formula
		local starryFormula = Formula.new():div(1e15):log(10):pow(2):div(12):add(1) :: Formula.Formula

		local boosts = script.Parent.Boosts.SurfaceGui
		local t = 2
		RunService.Heartbeat:Connect(function(dt)
			t += dt
			if (t < 1) then
				return
			end
			t = 0
			local drums = Utils.Currencies:get("Drums")
			local guitarBoost = guitarFormula:apply(drums)
			local kitaBoost: AlyaNum.AlyaNum
			local starryBoost: AlyaNum.AlyaNum
			boosts.GuitarLabel.Text = `x{guitarBoost} GUITARS`
			if (drums:lessThan(1e9)) then
				boosts.KitaLabel.Text = "YOU NEED 1B DRUMS TO UNLOCK THIS BOOST!!!"
			else
				kitaBoost = kitaFormula:apply(drums)
				boosts.KitaLabel.Text = `x{kitaBoost} KITAS`
			end
			if (drums:lessThan(1e15)) then
				boosts.StarryLabel.Text = "YOU NEED 1QD DRUMS TO UNLOCK THIS BOOST!!!"
			else
				starryBoost = starryFormula:apply(drums)
				boosts.StarryLabel.Text = `x{starryBoost} STARRYS`
			end

			ButtonInfo.Effect.Shrine.Mul = function()
				return Balance.new():set("Guitars", guitarBoost)
			end
		end)
		script.Parent.Boosts.Position += Vector3.new(0, 200, 0)
	end,
}

ButtonInfo.Descriptions = {
	Default = `UNLOCK THE NIJIKA CUBE WHERE YOU CLICK NIJIKA FOR DRUMS!!!!!`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 1e9):set("Nijika", 10000)
end

return ButtonInfo
