--!strict
--[[
	BestiaryService — the collection, and why it pays.

	Recording a species is DataService's job. What lives here is the reward
	curve on top of it: every tenth new species pays a purse, and closing the
	catalogue pays a big one.

	The milestone is derived from the species count rather than stored as a
	"claimed" flag. `isNew` is true exactly once per species, the count only
	rises, and a multiple of ten is crossed exactly once -- so there is no
	state to keep consistent and no way to claim twice.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local FishCatalog = require(Shared.FishCatalog)

local DataService = require(script.Parent.DataService)

local BestiaryService = {}

--: Milestone purses scale with how deep into the book you are.
function BestiaryService.milestoneCoins(known: number): number
	return 100 * math.floor(known / 10) * 10
end

function BestiaryService.afterCatch(player: Player, isNew: boolean)
	local profile = DataService.profile(player)
	if not profile or not isNew then
		return
	end
	local known = profile.stats.species or 0
	local total = FishCatalog.total()

	if known % 10 == 0 and known > 0 then
		local reward = BestiaryService.milestoneCoins(known)
		DataService.addCoins(player, reward)
		Net.fire(player, "Notify", {
			text = string.format("Bestiary: %d/%d species -- +$%d", known, total, reward),
			tone = "good",
		})
		Debug.count("bestiary.milestones")
	end

	if known >= total then
		DataService.addCoins(player, 25000)
		Net.fire(player, "Notify", {
			text = "The catalogue is complete. The trench has nothing left to hide. +$25,000",
			tone = "good",
		})
		Debug.count("bestiary.complete")
	end
end

return BestiaryService
