--!strict
--[[
	Market — the quay, the upgrades, and the spring tide.

	Sell, BuyUpgrade, UpgradePan and Prestige arrive here and leave through
	Sim. Prices stay in Sim. The copper lantern is the upgrade id "lantern",
	paid in cash. A prestige remote spends nothing unless confirm is true.
	The lighthouse on the plot is that confirm.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Debug = Forge.Debug

local Sim = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"))
local Ledger = require(script.Parent:WaitForChild("Ledger"))
local Marsh = require(script.Parent:WaitForChild("Marsh"))
local Rivals = require(script.Parent:WaitForChild("Rivals"))

local Market = {}

local ACTIONS = {
	"Sell",
	"Refine",
	"BuyUpgrade",
	"UpgradePan",
	"Prestige",
	"quaySell",
	"lighthousePrestige",
}

local function marketFacts(): { [string]: any }
	if type(Ledger.each) ~= "function" then
		return { listening = true, actions = ACTIONS }
	end

	local players = 0
	local lanterns = 0
	local upgradeLevels = 0
	local prestiged = 0
	local seen: { [Player]: boolean } = {}

	local ok = pcall(function()
		for player, profile in Ledger.each() do
			if typeof(player) ~= "Instance" or not player:IsA("Player") or seen[player] then
				error("iterator")
			end
			seen[player] = true
			players += 1
			if players > 32 then
				error("iterator")
			end
			if type(profile) ~= "table" then
				continue
			end
			if profile.cosmetic == "lantern" then
				lanterns += 1
			end
			if type(profile.prestige) == "number" and profile.prestige > 0 then
				prestiged += 1
			end
			local upgrades = profile.upgrades
			if type(upgrades) ~= "table" then
				continue
			end
			for _, level in upgrades do
				if type(level) == "number" and level > 0 then
					upgradeLevels += level
				end
			end
		end
	end)

	if not ok then
		return { listening = true, actions = ACTIONS }
	end
	return {
		listening = true,
		actions = ACTIONS,
		players = players,
		lanterns = lanterns,
		upgradeLevels = upgradeLevels,
		prestiged = prestiged,
	}
end

local function sell(player: Player, grade: string, amount: number)
	local ok, result = Ledger.mutate(player, function(clone)
		return Sim.sell(clone, grade, amount)
	end)
	if ok and type(result) == "table" and type(result.delta) == "table" and type(result.delta.cash) == "number" then
		local passed = Rivals.noteSale(player, result.delta.cash)
		if passed then
			Net.fire(player, "Notify", { text = "You passed " .. passed .. "." })
		end
	end
end

function Market.start()
	Net.on("Sell", function(player: Player, payload: { grade: string, amount: number })
		sell(player, payload.grade, payload.amount)
	end)

	Net.on("Refine", function(player: Player, payload: { kind: string, amount: number })
		Ledger.mutate(player, function(clone)
			return Sim.refine(clone, payload.kind, payload.amount)
		end)
	end)

	Net.on("BuyUpgrade", function(player: Player, payload: { upgradeId: string })
		Ledger.mutate(player, function(clone)
			return Sim.buyUpgrade(clone, payload.upgradeId)
		end)
	end)

	Net.on("UpgradePan", function(player: Player, payload: { panId: string })
		Ledger.mutate(player, function(clone)
			return Sim.upgradePan(clone, payload.panId)
		end)
	end)

	Net.on("Prestige", function(player: Player, payload: { confirm: boolean })
		if payload.confirm ~= true then
			-- The clone comes back as it arrived. Sim.prestige is not called.
			Ledger.mutate(player, function(clone)
				return clone, { ok = false, reason = "unconfirmed" }
			end)
			return
		end
		Ledger.mutate(player, function(clone)
			return Sim.prestige(clone)
		end)
	end)

	Marsh.onSell(function(player: Player)
		local profile = Ledger.get(player)
		if type(profile) ~= "table" or type(profile.salt) ~= "table" then
			return
		end
		local amount = profile.salt.coarse
		if type(amount) ~= "number" or amount < 1 then
			return
		end
		sell(player, "coarse", math.floor(amount))
	end)

	Marsh.onPrestige(function(player: Player)
		Ledger.mutate(player, function(clone)
			return Sim.prestige(clone)
		end)
	end)

	Debug.probe("market", marketFacts)
end

return Market
