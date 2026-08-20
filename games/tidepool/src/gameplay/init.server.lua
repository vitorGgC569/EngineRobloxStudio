--!strict
-- Gameplay: the systems this game needs, configured from the plan.
--
-- Every system here is GameKit's. Configuring the shipped module rather than
-- writing another one is what makes the economy the same code the pacing was
-- verified against.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameKit = require(ReplicatedStorage.GameKit)
local Currencies = require(ReplicatedStorage.Shared.Currencies)
local Tiers = require(ReplicatedStorage.Shared.Tiers)
local Catalogue = require(ReplicatedStorage.Shared.Catalogue)

local economy = GameKit.Economy.define(Currencies, GameKit.Economy.memoryStore())

local ladder = GameKit.Progression.define(Tiers)
-- Measured before anyone plays: the same call the economy designer made.
local pacing = GameKit.Progression.pacing(ladder, 1)
print(string.format("[%s] ladder: %d tiers, %.1f minutes",
	script.Name, #Tiers, pacing.totalSeconds / 60))

local items = {}
for _, entry in ipairs(Catalogue) do
	table.insert(items, {
		id = entry.id, displayName = entry.name, stackSize = 20,
	})
end
local inventory = GameKit.Inventory.define(items, GameKit.Inventory.memoryStore(), 12)

local Gameplay = {}

function Gameplay.grant(player: Player, amount: number, reason: string)
	return economy:grant(player, "cash", amount, reason)
end

return Gameplay
