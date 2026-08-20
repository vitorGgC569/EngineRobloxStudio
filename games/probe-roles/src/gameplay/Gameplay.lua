--!strict
-- Gameplay: the systems this game runs on, constructed and wired.
--
-- Every system here is GameKit's, configured from what the layers decided.
-- Writing another economy would be a second implementation of the one the
-- pacing was verified against.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local GameKit = require(ReplicatedStorage.GameKit)
local Currencies = require(ReplicatedStorage.Shared.Currencies)
local CoreLoop = require(ReplicatedStorage.Shared.CoreLoop)
local Tiers = require(ReplicatedStorage.Shared.Tiers)
local Catalogue = require(ReplicatedStorage.Shared.Catalogue)

local Gameplay = {}
local systems = {}

systems.analytics = GameKit.Analytics

systems.economy = GameKit.Economy.define(Currencies, GameKit.Economy.memoryStore())

systems.progression = GameKit.Progression.define(Tiers)
-- Measured with the same call the economy designer made. A ladder checked
-- only offline is one the shipped game can disagree with.
local pacing = GameKit.Progression.pacing(systems.progression, 1)

-- The generated catalogue, shaped for the systems that consume it. This
-- was the largest single drop: entries emitted and read by nothing.
local items, towers, enemies = {}, {}, {}
for _, entry in ipairs(Catalogue) do
	local stats = entry.stats or {}
	table.insert(items, { id = entry.id, displayName = entry.name, stackSize = 20 })
	if entry.role == "melee" or entry.role == "ranged" then
		table.insert(towers, {
			id = entry.id, displayName = entry.name,
			damage = math.max(stats.attack or 1, 1),
			range = 12 + (stats.speed or 1) * 4,
			cost = math.max(math.floor((entry.power or 10) * 5), 1),
			currency = "cash",
		})
	else
		table.insert(enemies, {
			id = entry.id, displayName = entry.name,
			health = math.max((stats.health or 1) * 20, 20),
			speed = math.max(stats.speed or 1, 1) * 3,
			bounty = math.max(math.floor(entry.power or 1), 1),
			leak = 1,
		})
	end
end

-- Waves built from the enemy tiers the content layer produced.
local waves = {}
for index = 1, math.min(#enemies, 8) do
	table.insert(waves, {
		index = index,
		entries = { { enemyId = enemies[index].id, count = 4 + index * 2, interval = 1 } },
	})
end
if #towers > 0 and #waves > 0 then
	systems.tower = GameKit.Tower.define(towers, enemies, waves, GameKit.Tower.memoryStore(), 100)
end

-- The loop, as behaviour rather than as a comment.
function Gameplay.reward(player: Player, amount: number, reason: string): number
	local balance = systems.economy:grant(player, "cash", amount, reason)
	-- Published as an attribute so the HUD can read it without a remote.
	-- The server owns the number; a client keeping its own disagrees with
	-- the ledger the moment anything is spent, always in its own favour.
	player:SetAttribute("cash", balance)
	if systems.leaderboard ~= nil then
		systems.leaderboard.submit(player, "wealth", math.floor(balance))
	end
	return balance
end

function Gameplay.systems(): { [string]: any }
	return systems
end

function Gameplay.loop(): { string }
	return CoreLoop
end

local constructed = 0
for _ in pairs(systems) do constructed += 1 end
print(string.format("[probe-roles] gameplay: %d systems, %d loop steps",
	constructed, #CoreLoop))

return Gameplay
