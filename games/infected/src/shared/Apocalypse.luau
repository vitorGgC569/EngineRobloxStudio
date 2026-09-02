--!strict
--[[
	Apocalypse — what this game is now, and the levers that make it that.

	This started as a round-based social deduction game: thirty players, one
	secretly Patient Zero, a timer, a winner. Everything else it has -- three
	hand-built maps, ballistics, bot AI, an economy, quests, seasons, ranks,
	persistence -- is worth keeping and has nothing to do with that premise.

	So the premise is what changed, and this file is where the change is
	stated rather than scattered through nine services.

	The three rules
	---------------

	**The world never ends.** No intermission, no round, no winner. A player
	joins, spawns, and plays until they leave. The round machine still runs
	underneath because sixty other things read its state -- the HUD timer, the
	economy's payout hooks, the analytics -- but it is held permanently open
	instead of being torn out. A state machine with one state is cheaper to
	maintain than the absence of one.

	**Everyone is a survivor.** There is no Patient Zero and no conversion.
	Being infected was the twist of the old game and it is the one part that
	cannot survive: a hidden traitor needs a round to be hidden *for*.

	**Survivors shoot survivors.** This is the whole point of the change. The
	old game refused survivor-on-survivor damage on purpose -- it would have
	let you find the Patient Zero by shooting everybody -- and with no Patient
	Zero to protect, that refusal is just a shooter where you cannot shoot.

	What the dead are for
	---------------------

	Zombies stop being players and become the world's pressure: always there,
	scaling with headcount, never the thing you are competing with. The
	competition is the other survivors, and the horde is what makes fighting
	them expensive. Shooting a rival in the open is loud, and loud is a
	decision rather than a free action.
]]

local Apocalypse = {}

--: Named so a grep for "why is the round never ending" lands here.
Apocalypse.PERSISTENT_WORLD = true

--[[
	The world is always live.

	Every service that used to ask "is a round running" is asking "may I act",
	and in a persistent world the answer is always yes. Passed as the
	`isRoundActive` dependency so the services keep their existing shape.
]]
function Apocalypse.worldIsLive(): boolean
	return true
end

Apocalypse.Rules = {
	--: Survivors damage each other. The one line that turns a game about
	--: hiding into a game about shooting.
	FriendlyFire = true,

	--[[
		Damage between players, as a multiplier on the weapon's own figure.

		Slightly under one, because these weapons were tuned against zombies
		that take several hits and die, and a player who dies in three tenths
		of a second to something they never saw stops playing. Lengthening the
		exchange is what gives a fight a middle -- time to break contact, take
		cover, or decide it was a bad idea.
	]]
	PlayerDamageScale = 0.85,

	--: Seconds of immunity after spawning. Long enough to get off the pad,
	--: short enough not to be a weapon.
	SpawnProtectionSeconds = 5,

	--: How long a body waits before the player is back in the world.
	RespawnSeconds = 6,

	--: No Patient Zero, ever.
	PatientZero = false,
}

--[[
	How heavy the horde is.

	Per player rather than flat: a flat count makes a solo server crowded and a
	full one empty, and the horde's job is to be constant pressure whatever the
	headcount is.
]]
Apocalypse.Horde = {
	PerPlayer = 5,
	Floor = 8,
	--: Where a crowd of pathfinding rigs starts costing more frame time than
	--: the pressure is worth. Measured, not chosen.
	Ceiling = 18,

	--[[
		Rival scavengers, and there have to be enough of them.

		One was the first guess and it was wrong for an obvious reason: this is
		a game about shooting other survivors, and a server with a single rival
		is a server where the fight you came for happens once every few minutes
		if you can find them. Three per player is enough that the map has
		gunfire in it that is not yours.

		They were already in this game shooting zombies. With friendly fire on
		they became opponents without a line of new AI being written.
	]]
	RivalsPerPlayer = 3,
	RivalsCeiling = 8,
}

function Apocalypse.hordeSize(humanCount: number): number
	local wanted = Apocalypse.Horde.Floor
		+ math.max(0, humanCount) * Apocalypse.Horde.PerPlayer
	return math.clamp(wanted, Apocalypse.Horde.Floor, Apocalypse.Horde.Ceiling)
end

function Apocalypse.rivalSize(humanCount: number): number
	return math.clamp(math.max(0, humanCount) * Apocalypse.Horde.RivalsPerPlayer,
		0, Apocalypse.Horde.RivalsCeiling)
end

function Apocalypse.describe(): { [string]: any }
	return {
		persistent = Apocalypse.PERSISTENT_WORLD,
		friendlyFire = Apocalypse.Rules.FriendlyFire,
		patientZero = Apocalypse.Rules.PatientZero,
		hordeAt4 = Apocalypse.hordeSize(4),
		rivalsAt4 = Apocalypse.rivalSize(4),
	}
end

return Apocalypse
