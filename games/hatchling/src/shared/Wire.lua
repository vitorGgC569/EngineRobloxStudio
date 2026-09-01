--!strict
--[[
	Wire — the messages the client and the server agree on.

	One file, required by both, so a name cannot drift between them. A remote
	spelled two ways is the classic silent failure: the client fires into
	something nobody listens on, and firing into nothing raises no error
	anywhere. `Net.handles` exists so a scenario can catch that.

	Every `c2s` entry is a request. `hatch` means "I pressed the stand for egg
	3", never "give me a Legendary" -- what comes out is rolled on the server
	from a seed the client never sees. That is not a nicety in a game whose
	entire economy is a drop table.

	Crates are the exception worth explaining
	-----------------------------------------

	Breaking a crate is a touch, and touches happen on the client first. The
	client says "I touched crate 14"; the server checks the crate exists, is not
	already broken, and is within reach of that player's character, then decides
	what it was worth. The reach check is the whole security model here and it
	lives in the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Wire = {}

Wire.definitions = {
	--: "I ran into that crate." Rate-limited well above a human's pace, because
	--: the real gate is the per-crate cooldown the server keeps.
	smash = { dir = "c2s", kind = "function", rate = 30,
		shape = { crate = "string" } },

	--: "I pressed the stand for this egg."
	hatch = { dir = "c2s", kind = "function", rate = 8,
		shape = { egg = "number" } },

	--: The bench.
	equip = { dir = "c2s", kind = "function", rate = 12, shape = { uid = "string" } },
	unequip = { dir = "c2s", kind = "function", rate = 12, shape = { uid = "string" } },
	equipBest = { dir = "c2s", kind = "function", rate = 4 },
	release = { dir = "c2s", kind = "function", rate = 12, shape = { uid = "string" } },
	buySlot = { dir = "c2s", kind = "function", rate = 3 },

	--: The climb.
	unlockZone = { dir = "c2s", kind = "function", rate = 3 },
	travel = { dir = "c2s", kind = "function", rate = 6, shape = { zone = "number" } },
	rebirth = { dir = "c2s", kind = "function", rate = 2 },

	--: The whole save, for drawing it. The hot numbers travel as attributes;
	--: this carries the shape, which is too big for one and changes only when
	--: the player acts.
	state = { dir = "c2s", kind = "function", rate = 8 },

	-- ---------------------------------------------------- server -> client
	--: What just happened, as opposed to what the numbers are.
	notice = { dir = "s2c", kind = "event" },

	--: A crate came apart. Carries what it paid so the client can throw the
	--: number without asking.
	smashed = { dir = "s2c", kind = "event" },

	--: An egg opened. The single most important message in the game: the
	--: client owns the shake, the crack and the reveal, and this is what
	--: starts them.
	hatched = { dir = "s2c", kind = "event" },

	--: Somebody on this server pulled something rare enough that everybody
	--: should hear about it.
	announce = { dir = "s2c", kind = "event" },
}

function Wire.install()
	Forge.Net.define(Wire.definitions)
end

return Wire
