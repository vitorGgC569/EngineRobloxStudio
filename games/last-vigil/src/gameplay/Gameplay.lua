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
local FeedbackConfig = require(ReplicatedStorage.Shared.FeedbackConfig)
local Tiers = require(ReplicatedStorage.Shared.Tiers)
local Catalogue = require(ReplicatedStorage.Shared.Catalogue)

local Gameplay = {}
local systems = {}

-- Created by the server. It carries facts from authoritative systems to
-- presentation and has no OnServerEvent handler.
systems.feedback = GameKit.Feedback.server(FeedbackConfig)

systems.onboarding = GameKit.Onboarding.define({
	id = "last-vigil.first-session",
	steps = {
		{ id = "earn", instruction = "Collect your first reward",
			event = "reward_collected", targetId = "reward-source" },
		{ id = "purchase", instruction = "Use it at the highlighted site",
			event = "purchase_committed", targetId = "first-purchase" },
	},
}, GameKit.Onboarding.memoryStore(), function(player: Player, snapshot: { [string]: any })
	-- The snapshot is authoritative. The HUD presents this attribute; it
	-- never advances onboarding or claims that an action succeeded.
	player:SetAttribute("RQEOnboardingInstruction", snapshot.instruction or "")
end)

systems.analytics = GameKit.Analytics

systems.economy = GameKit.Economy.define(Currencies, GameKit.Economy.memoryStore())

systems.save = GameKit.Save.store("last-vigil", {
	balance = 0, tier = 1,
})

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
	if reason ~= "production" then
		systems.feedback:emit(player, "reward", { amount = amount })
		if systems.onboarding ~= nil then
			systems.onboarding.observe(player, "reward_collected",
				reason .. ":" .. tostring(balance), { amount = amount })
		end
	end
	return balance
end

-- Tuning the drivers read. Derived rather than chosen here: the income
-- comes from the ladder the economy designer verified, so a driver cannot
-- run the game at a pace the pacing report never saw.
Gameplay.incomePerSecond = 1.125
Gameplay.waveSeconds = 60.0
Gameplay.roundsToWin = 12
Gameplay.pathLength = 120.0
Gameplay.prepareSeconds = 45.0

function Gameplay.systems(): { [string]: any }
	return systems
end

function Gameplay.loop(): { string }
	return CoreLoop
end

local constructed = 0
for _ in pairs(systems) do constructed += 1 end
print(string.format("[last-vigil] gameplay: %d systems, %d loop steps",
	constructed, #CoreLoop))

return Gameplay
