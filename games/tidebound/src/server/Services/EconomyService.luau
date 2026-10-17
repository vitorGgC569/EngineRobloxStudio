--!strict
--[[
	EconomyService — the stalls.

	Every purchase is "does the wallet cover it, then mutate". Prices live in
	Items; this service owns the *order of checks* and the notifications,
	which is the entire difference between a shop and a source of support
	tickets.

	Selling is the only place coins are born in bulk. The dock bonus exists so
	that the pier is a place people stand rather than a place the game
	mentions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)

local DataService = require(script.Parent.DataService)
local QuestService = require(script.Parent.QuestService)
local LeaderboardService = require(script.Parent.LeaderboardService)
local BoatService = require(script.Parent.BoatService)
local WorldService = require(script.Parent.WorldService)

local EconomyService = {}

local BAIT_CAP = 99

local function notify(player: Player, text: string, tone: string?)
	Net.fire(player, "Notify", { text = text, tone = tone })
end

local function characterAt(player: Player): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

--: Standing near any charted dock. The radius covers the islet and its pier,
--: because "at the dock" to a player fishing off the end of the pier is
--: still the dock.
function EconomyService.atDock(player: Player): boolean
	local position = characterAt(player)
	if not position then
		return false
	end
	for _, dock in WorldService.docks do
		local flat = Vector3.new(position.X, dock.Y, position.Z)
		if (flat - dock).Magnitude < 165 then
			return true
		end
	end
	return false
end

-- ================================= selling ==================================
local function sellCrate(player: Player)
	local profile = DataService.profile(player)
	if not profile then
		return
	end
	local crate = profile.crate
	if #crate == 0 then
		notify(player, "The crate is empty.")
		return
	end
	local total = 0
	for _, entry in crate do
		total += entry.value or 0
	end
	local atDock = EconomyService.atDock(player)
	if atDock then
		total = math.floor(total * Config.dockSellBonus)
	end
	local count = #crate
	profile.crate = {}
	profile.stats.sold += count
	DataService.addCoins(player, total)
	QuestService.record(player, { kind = "sell", coins = total })
	LeaderboardService.publish(player)
	Debug.count("economy.sales")
	Debug.info(string.format("sold %d catches for $%d (dock=%s)", count, total, tostring(atDock)))
	if atDock then
		notify(player, string.format("Sold %d catches at the dock: +$%d", count, total), "good")
	else
		notify(player, string.format("Sold %d catches: +$%d (the dock pays 15%% more)", count, total))
	end
	DataService.push(player, true)
end

-- ================================== buying ==================================
local function buyRod(player: Player, rodId: string)
	local profile = DataService.profile(player)
	local rod = Items.rodById[rodId]
	if not profile or not rod then
		return
	end
	if profile.rods.owned[rodId] then
		profile.rods.equipped = rodId
		notify(player, string.format("%s equipped.", rod.name))
		DataService.push(player, true)
		return
	end
	if not DataService.spend(player, rod.cost) then
		notify(player, string.format("%s costs $%d. You have $%d.", rod.name, rod.cost, profile.coins))
		return
	end
	profile.rods.owned[rodId] = true
	profile.rods.equipped = rodId
	Debug.count("economy.rods")
	notify(player, string.format("Bought and equipped %s.", rod.name), "good")
	DataService.push(player, true)
end

local function buyBait(player: Player, baitId: string, qty: number)
	local profile = DataService.profile(player)
	local bait = Items.baitById[baitId]
	if not profile or not bait then
		return
	end
	qty = math.clamp(math.floor(qty or 1), 1, 99)
	local owned = profile.baits.owned[baitId] or 0
	local room = BAIT_CAP - owned
	if room <= 0 then
		notify(player, "That bait tin is full.")
		return
	end
	qty = math.min(qty, room)
	local cost = bait.cost * qty
	if not DataService.spend(player, cost) then
		qty = math.floor(profile.coins / bait.cost)
		if qty <= 0 then
			notify(player, string.format("You cannot afford %s.", bait.name))
			return
		end
		DataService.spend(player, bait.cost * qty)
	end
	profile.baits.owned[baitId] = owned + qty
	if profile.baits.equipped == nil or (profile.baits.owned[profile.baits.equipped] or 0) <= 0 then
		profile.baits.equipped = baitId
	end
	Debug.count("economy.baits")
	notify(player, string.format("Bought %dx %s.", qty, bait.name), "good")
	DataService.push(player, true)
end

local function buyBoat(player: Player, boatId: string)
	local profile = DataService.profile(player)
	local boat = Items.boatById[boatId]
	if not profile or not boat then
		return
	end
	if profile.boats.owned[boatId] then
		profile.boats.equipped = boatId
		notify(player, string.format("%s equipped.", boat.name))
		DataService.push(player, true)
		return
	end
	if not DataService.spend(player, boat.cost) then
		notify(player, string.format("%s costs $%d. You have $%d.", boat.name, boat.cost, profile.coins))
		return
	end
	profile.boats.owned[boatId] = true
	profile.boats.equipped = boatId
	BoatService.summon(player)
	Debug.count("economy.boats")
	notify(player, string.format("%s bought and in the water.", boat.name), "good")
	DataService.push(player, true)
end

-- ================================ equip =====================================
local function equipRod(player: Player, rodId: string)
	local profile = DataService.profile(player)
	if not profile or not Items.rodById[rodId] or not profile.rods.owned[rodId] then
		return
	end
	profile.rods.equipped = rodId
	DataService.push(player, true)
end

local function equipBait(player: Player, baitId: string)
	local profile = DataService.profile(player)
	if not profile or not Items.baitById[baitId] then
		return
	end
	if (profile.baits.owned[baitId] or 0) <= 0 then
		notify(player, "None left in the tin.")
		return
	end
	profile.baits.equipped = baitId
	DataService.push(player, true)
end

-- ================================ zones =====================================
local function travelTo(player: Player, zoneId: string)
	local profile = DataService.profile(player)
	local zone = Config.zone(zoneId)
	if not profile or not zone then
		return
	end
	if not profile.zones[zoneId] then
		notify(player, "That water is not charted yet.")
		return
	end
	local cost = if zoneId == "shallows" then 0 else Config.travelCost
	if cost > 0 and not DataService.spend(player, cost) then
		notify(player, string.format("The crossing costs $%d.", cost))
		return
	end
	local dock = WorldService.dock(zoneId)
	local character = player.Character
	if character then
		local root = character:FindFirstChild("HumanoidRootPart")
		if root then
			local towardPier = Vector3.new(zone.center.X - dock.X, 0, zone.center.Y - dock.Z)
			if towardPier.Magnitude < 1 then
				towardPier = Vector3.new(0, 0, 1)
			end
			local target = dock + towardPier.Unit * 26 + Vector3.new(0, 4, 0)
			character:PivotTo(CFrame.lookAt(target, Vector3.new(zone.center.X, target.Y, zone.center.Y)))
		end
	end
	BoatService.placeAt(player, zoneId)
	Debug.count("economy.travels")
	notify(player, string.format("Landed at %s.", zone.name), "good")
	DataService.push(player, true)
end

local function unlockZone(player: Player, zoneId: string)
	local profile = DataService.profile(player)
	local zone = Config.zone(zoneId)
	if not profile or not zone then
		return
	end
	if profile.zones[zoneId] then
		travelTo(player, zoneId)
		return
	end
	local level = Config.levelForXp(profile.xp or 0)
	if level < zone.unlockLevel then
		notify(player, string.format("%s needs level %d. You are level %d.", zone.name, zone.unlockLevel, level))
		return
	end
	if not DataService.spend(player, zone.cost) then
		notify(player, string.format("Charting %s costs $%d. You have $%d.", zone.name, zone.cost, profile.coins))
		return
	end
	profile.zones[zoneId] = true
	Debug.count("economy.unlocks")
	notify(player, string.format("%s charted.", zone.name), "good")
	QuestService.sync(player)
	travelTo(player, zoneId)
end

-- ================================== start ===================================
function EconomyService.start()
	Net.on("SellCrate", sellCrate)
	Net.on("BuyRod", function(player: Player, payload: any)
		if type(payload.rod) == "string" then
			buyRod(player, payload.rod)
		end
	end)
	Net.on("BuyBait", function(player: Player, payload: any)
		if type(payload.bait) == "string" then
			buyBait(player, payload.bait, payload.qty or 1)
		end
	end)
	Net.on("BuyBoat", function(player: Player, payload: any)
		if type(payload.boat) == "string" then
			buyBoat(player, payload.boat)
		end
	end)
	Net.on("EquipRod", function(player: Player, payload: any)
		if type(payload.rod) == "string" then
			equipRod(player, payload.rod)
		end
	end)
	Net.on("EquipBait", function(player: Player, payload: any)
		--: nil is legal and means "bare hook": no bait is a choice.
		if payload.bait == nil then
			local profile = DataService.profile(player)
			if profile then
				profile.baits.equipped = nil
				DataService.push(player, true)
			end
		elseif type(payload.bait) == "string" then
			equipBait(player, payload.bait)
		end
	end)
	Net.on("UnlockZone", function(player: Player, payload: any)
		if type(payload.zone) == "string" then
			unlockZone(player, payload.zone)
		end
	end)
	Net.on("TravelTo", function(player: Player, payload: any)
		if type(payload.zone) == "string" then
			travelTo(player, payload.zone)
		end
	end)
	Net.on("SaveSettings", function(player: Player, payload: any)
		local profile = DataService.profile(player)
		if not profile then
			return
		end
		profile.settings.music = math.clamp(tonumber(payload.music) or profile.settings.music, 0, 1)
		profile.settings.sfx = math.clamp(tonumber(payload.sfx) or profile.settings.sfx, 0, 1)
		DataService.push(player)
	end)
	Net.on("TutorialDone", function(player: Player, payload: any)
		local profile = DataService.profile(player)
		if not profile or type(payload.step) ~= "string" then
			return
		end
		profile.tutorial.seen[payload.step] = true
		DataService.push(player)
	end)

	Debug.info("economy armed")
end

return EconomyService
