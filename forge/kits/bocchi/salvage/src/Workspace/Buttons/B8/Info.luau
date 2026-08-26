local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local AlyaNum = require(ReplicatedStorage.Packages.alyanum)
local Balance = require(ReplicatedStorage.Balance)
local Bocculty = require(ReplicatedStorage.Bocculty)
local Formula = require(ReplicatedStorage.Formula)
local Utils = require(ReplicatedStorage.Utils)

local ButtonInfo = {}

ButtonInfo.Difficulty = Bocculty.TheLowerGap

ButtonInfo.Name = ButtonInfo.Difficulty.name .. " #3"
ButtonInfo.MaxAmount = 1

script.Parent.Boosts.Position -= Vector3.new(0, 200, 0)
local headingLabel = script.Parent.Button.SurfaceGui.Frame.Cost.HeadingLabel
ButtonInfo.Effect = {
	Generation = {
		IsVariable = true
	},
	Shrine = {
		Add = function()
			return Balance.new():set("Guitars", 1)
		end,
	},
	OnPurchase = function()
		local bocchiFormula = Formula.new():log(5):pow(2):div(12):add(1) :: Formula.Formula
		local nijikaFormula = Formula.new():div(10000):log(7):pow(2):div(12):add(1) :: Formula.Formula
		local ryoFormula = Formula.new():div(10000000):log(9):pow(2):div(12):add(1) :: Formula.Formula
		
		local boosts = script.Parent.Boosts.SurfaceGui
		local t = 2
		RunService.Heartbeat:Connect(function(dt)
			t += dt
			if (t < 1) then
				return
			end
			t = 0
			local guitars = Utils.Currencies:get("Guitars")
			local bocchiBoost = bocchiFormula:apply(guitars)
			local nijikaBoost: AlyaNum.AlyaNum
			local ryoBoost: AlyaNum.AlyaNum
			boosts.BocchisLabel.Text = `x{bocchiBoost} BOCCHIS`
			if (guitars:lessThan(10000)) then
				boosts.NijikaLabel.Text = "YOU NEED 10K GUITARS TO UNLOCK THIS BOOST!!!"
			else
				nijikaBoost = nijikaFormula:apply(guitars)
				boosts.NijikaLabel.Text = `x{nijikaBoost} NIJIKAS`
			end
			if (guitars:lessThan(10000000)) then
				boosts.RyoLabel.Text = "YOU NEED 10M GUITARS TO UNLOCK THIS BOOST!!!"
			else
				ryoBoost = ryoFormula:apply(guitars)
				boosts.RyoLabel.Text = `x{ryoBoost} RYOS`
			end
			
			ButtonInfo.Effect.Generation.Mul = function()
				local boost = Balance.new():set("Bocchi", bocchiBoost)
				if (nijikaBoost ~= nil) then
					boost = boost:set("Nijika", nijikaBoost)
					if (ryoBoost ~= nil) then
						boost = boost:set("Ryo", ryoBoost)

					end
				end
				return boost
			end
		end)
		script.Parent.Boosts.Position += Vector3.new(0, 200, 0)
	end,
}

ButtonInfo.Descriptions = {
	Default = `Unlock. THE BOCCHI SHRINE WHERE YOU CAN PRAY TO BOCCHI FOR MORE BOCCHIS`
}

ButtonInfo.Cost = function(nextAmount: number)
	return Balance.new():set("Bocchi", 2000)
end

return ButtonInfo
