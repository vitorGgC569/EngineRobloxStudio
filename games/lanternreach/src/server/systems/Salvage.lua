--!strict
--[[
	Salvage — caches you find, open and carry home.

	The whole loop is four Forge calls: Assets makes the thing, Scene places it,
	Interaction lets a player open it, Inventory holds what came out. Quests and
	progression are not mentioned anywhere in this file and advance anyway,
	because opening a cache emits an event and they listen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Assets = Forge.Assets
local Entity = Forge.Entity
local Events = Forge.Events
local Interaction = Forge.Interaction
local Inventory = Forge.Inventory
local Progression = Forge.Progression
local Net = Forge.Net
local Rng = Forge.Core.Rng
local Sched = Forge.Core.Sched
local Debug = Forge.Debug

local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))
local Shore = require(script.Parent.Shore)

local Salvage = {}

local liveCaches = 0
local maxCaches = Debug.tunable("salvage.maxCaches", 22)
local respawnSeconds = Debug.tunable("salvage.respawnSeconds", 26)

Entity.define("Cache", { kind = "crate", opened = false, richness = 1 })

local UNLOCK_FOR = {
	crate = nil,
	hull = "cache.hull",
	deep = "cache.deep",
}

local ASSET_FOR = {
	crate = "Salvage.Crate",
	hull = "Salvage.Hull",
	deep = "Salvage.Deep",
}

local function subjectOf(player: Player): string
	return "player:" .. player.UserId
end

--[[
	Roll the contents. A cache the player cannot yet open is still placed and
	still visible — seeing a wreck you are not ready for is the map telling you
	where to come back to.
]]
local function rollContents(kind: string): { { item: string, count: number } }
	local definition = Content.caches[kind]
	local stream = Rng.stream("salvage.rolls")
	local out = {}
	local rolls = stream:int(definition.rolls[1], definition.rolls[2])

	for _ = 1, rolls do
		local pick = stream:weighted(definition.table_)
		if pick then
			table.insert(out, {
				item = pick.item,
				count = stream:int(pick.count[1], pick.count[2]),
			})
		end
	end
	return out
end

local function spawnCache(kind: string)
	local point = Shore.salvagePoint()
	if not point then
		return nil
	end

	local assetId = ASSET_FOR[kind]
	local model = Assets.spawn(assetId, CFrame.new(point), Workspace:FindFirstChild("Salvage"))
	if not model then
		return nil
	end

	local id = Entity.create({
		name = kind,
		instance = model,
		tags = { "cache" },
		components = { Cache = { kind = kind, opened = false } },
	})
	liveCaches += 1

	local definition = Content.caches[kind]
	Interaction.register(model, {
		id = "salvage",
		label = "Search",
		objectLabel = definition.label,
		holdDuration = 0.9,
		range = 11,
		condition = function(player)
			local unlock = UNLOCK_FOR[kind]
			if not unlock then
				return true
			end
			local track = Progression.track("reach", subjectOf(player))
			if Progression.unlocked(track, unlock) then
				return true
			end
			Net.fire(player, "Notify", { text = "You do not know how to open this yet." })
			return false
		end,
		onTrigger = function(player)
			Salvage.open(player, id)
		end,
	})

	return id
end

function Salvage.open(player: Player, entityId: number)
	local cache = Entity.get(entityId, "Cache")
	if not cache or cache.opened then
		return
	end
	cache.opened = true

	local subject = subjectOf(player)
	local bag = Inventory.get(subject)
	if not bag then
		return
	end

	local contents = rollContents(cache.kind)
	local taken = {}
	for _, entry in contents do
		local accepted = Inventory.add(bag, entry.item, entry.count)
		if accepted > 0 then
			table.insert(taken, { item = entry.item, count = accepted })
		end
	end

	-- One event. Quests, progression and the client all key off it, and none
	-- of them are referenced here.
	Events.emit("salvage.opened", {
		subject = subject,
		player = player.Name,
		kind = cache.kind,
		items = taken,
	})

	local track = Progression.track("reach", subject)
	Progression.award(track, cache.kind == "deep" and 90 or (cache.kind == "hull" and 55 or 30))

	local position = Entity.position(entityId)
	Net.fire(player, "Opened", {
		pos = position,
		label = Content.caches[cache.kind].label,
		items = taken,
	})

	Debug.count("salvage.opened")
	Entity.destroy(entityId)
	liveCaches -= 1
end

function Salvage.start()
	if not Workspace:FindFirstChild("Salvage") then
		local folder = Instance.new("Folder")
		folder.Name = "Salvage"
		folder.Parent = Workspace
	end

	local weights = {
		{ kind = "crate", weight = 58 },
		{ kind = "hull", weight = 30 },
		{ kind = "deep", weight = 12 },
	}

	-- One loop keeps the shelf stocked. Caches are not tied to players, so the
	-- world stays populated in a headless run — which is what makes it
	-- measurable without a person standing in it.
	task.spawn(function()
		while true do
			task.wait(respawnSeconds() / 4)
			local target = maxCaches()
			for _ = 1, 3 do
				if liveCaches >= target then
					break
				end
				local pick = Rng.stream("salvage.mix"):weighted(weights)
				if pick then
					spawnCache(pick.kind)
				end
			end
		end
	end)

	Debug.probe("salvage", function()
		return {
			live = liveCaches,
			max = maxCaches(),
			opened = Debug.counter("salvage.opened"),
		}
	end)

	Debug.info("salvage system ready")
end

return Salvage
