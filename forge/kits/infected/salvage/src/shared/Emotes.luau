--!strict
-- Emote catalog.
--
-- STATUS.md listed emotes as permanently blocked on "animation assets uploaded to the
-- Roblox account". That turned out to be wrong: Roblox's own emote animations are public,
-- and every id below was verified to load on the live engine by tests/asset-probe2.lua.
-- Do not add an id here without re-running that probe.
--
-- Emotes matter more here than in most games: a hidden Patient Zero waving at the group is
-- the cheapest possible way to look like a survivor, so this feeds the core mind-game.

local Emotes = {}

export type Emote = {
	id: string,
	label: string,
	animationId: number,
	duration: number, -- seconds before the player can move freely again
}

Emotes.Catalog = {
	{ id = "wave", label = "WAVE", animationId = 507770239, duration = 2.2 },
	{ id = "point", label = "POINT", animationId = 507770453, duration = 2.2 },
	{ id = "cheer", label = "CHEER", animationId = 507770677, duration = 2.6 },
	{ id = "laugh", label = "LAUGH", animationId = 507770818, duration = 2.8 },
	{ id = "dance", label = "DANCE", animationId = 507771019, duration = 4.0 },
	{ id = "dance2", label = "DANCE 2", animationId = 507776043, duration = 4.0 },
	{ id = "dance3", label = "DANCE 3", animationId = 507777268, duration = 4.0 },
} :: { Emote }

function Emotes.byId(id: string): Emote?
	for _, emote in Emotes.Catalog do
		if emote.id == id then
			return emote
		end
	end
	return nil
end

function Emotes.ids(): { string }
	local out = {}
	for _, emote in Emotes.Catalog do
		table.insert(out, emote.id)
	end
	return out
end

-- Who is allowed to emote.
--
-- PATIENT ZERO GUARD: the hidden PZ *must* be able to emote — being able to wave along with
-- everyone else is exactly the bluff the game is built on. Revealed zombies cannot, both
-- because a dancing zombie looks broken and because it would be a channel for a converted
-- player to signal to the living.
function Emotes.canPlay(role: string): boolean
	return role == "SURVIVOR" or role == "PATIENT_ZERO"
end

return Emotes
