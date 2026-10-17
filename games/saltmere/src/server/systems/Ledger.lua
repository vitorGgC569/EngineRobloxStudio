--!strict
--[[
	Ledger — the live save table and the only writer of StateSync.

	Sim returns a new table on success. This module copies that table back
	onto the one Save is holding, so a later write cannot lose the tide.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug

local Sim = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sim"))
local Marsh = require(script.Parent:WaitForChild("Marsh"))

local Ledger = {}

local profiles: { [Player]: any } = {}

local function coins(player: Player, cash: number)
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
	end
	local coin = folder:FindFirstChild("Coin")
	if not coin then
		coin = Instance.new("IntValue")
		coin.Name = "Coin"
		coin.Parent = folder
	end
	if coin:IsA("IntValue") then
		coin.Value = math.floor(cash)
	end
end

function Ledger.get(player: Player): any?
	return profiles[player]
end

function Ledger.each(): any
	return pairs(profiles)
end

function Ledger.sync(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	coins(player, profile.cash)
	Net.fire(player, "StateSync", {
		cash = profile.cash,
		salt = Sim.clone(profile.salt),
		pans = Sim.clone(profile.pans),
		upgrades = Sim.clone(profile.upgrades),
		crew = Sim.clone(profile.crew),
		prestige = profile.prestige,
		lifetime = profile.lifetime,
		quests = Sim.clone(profile.quests),
		cosmetic = profile.cosmetic,
		prices = {
			coarse = Sim.price(profile, "coarse"),
			fine = Sim.price(profile, "fine"),
			flake = Sim.price(profile, "flake"),
			smoked = Sim.price(profile, "smoked"),
		},
		prestigeNeed = Sim.prestigeNeed(profile),
	})
end

function Ledger.mutate(player: Player, reducer: (any) -> (any, any)): (boolean, any)
	local profile = profiles[player]
	if not profile then
		return false, { ok = false, reason = "bad_id" }
	end
	local newProfile, result = reducer(Sim.clone(profile))
	if type(result) ~= "table" or result.ok ~= true or type(newProfile) ~= "table" then
		return false, result
	end
	Sim.copyInto(profile, newProfile)
	Ledger.sync(player)
	if type(result.toast) == "string" and result.toast ~= "" then
		Net.fire(player, "Notify", { text = result.toast })
	end
	return true, result
end

function Ledger.start()
	Save.observe(function(player: Player, profile: any)
		if type(profile) ~= "table" then
			return
		end
		Sim.reconcile(profile)
		profile.slot = Marsh.assignSlot(player, profile.slot)
		profiles[player] = profile
		Ledger.sync(player)
		if type(profile.slot) == "number" and profile.slot > 0 then
			Marsh.adopt(player, profile.slot)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		profiles[player] = nil
		Marsh.release(player)
	end)

	Debug.probe("ledger", function()
		local count = 0
		local sample = 0
		for _, profile in profiles do
			count += 1
			sample = profile.cash
		end
		return { players = count, cash = sample }
	end)
end

return Ledger
