--!strict
-- Nametag titles: pure data. Titles are unlocked by reaching account levels and shown over
-- a player's head. Cosmetic only. IDs are stable keys stored in the profile.

export type Title = { id: string, text: string, rarity: string, unlockLevel: number }

local Titles: { Title } = {
	{ id = "rookie", text = "Rookie", rarity = "Common", unlockLevel = 1 },
	{ id = "survivor", text = "Survivor", rarity = "Common", unlockLevel = 5 },
	{ id = "hunter", text = "Hunter", rarity = "Uncommon", unlockLevel = 10 },
	{ id = "outbreak", text = "Outbreak", rarity = "Rare", unlockLevel = 20 },
	{ id = "carrier", text = "The Carrier", rarity = "Epic", unlockLevel = 35 },
	{ id = "apex", text = "Apex Predator", rarity = "Legendary", unlockLevel = 50 },
	{ id = "undying", text = "Undying", rarity = "Chroma", unlockLevel = 75 },
}

local byId: { [string]: Title } = {}
for _, t in Titles do
	byId[t.id] = t
end

local M = {}
M.All = Titles

function M.get(id: string): Title?
	return byId[id]
end

-- Every title whose unlockLevel <= level (what the player is entitled to own).
function M.unlockedAt(level: number): { Title }
	local out = {}
	for _, t in Titles do
		if level >= t.unlockLevel then
			table.insert(out, t)
		end
	end
	return out
end

return M
