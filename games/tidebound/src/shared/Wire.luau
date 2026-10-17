--!strict
--[[
	Wire — the entire network contract, in one file.

	`Net.define` is per-VM and both halves must declare the same channels, so
	the contract lives in one module that both bootstraps require. Nothing
	crosses this game's wire that is not written here: every client-to-server
	entry carries a rate and a shape, which is what makes "the client said
	something impossible" a refusal instead of a mystery bug.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net

local Wire = {}

Wire.Specs = {
	-- ------------------------ client -> server ------------------------
	--: The rod is thrown. Both points are validated against the character's
	--: real position and the rod's reach before anything exists in the world.
	Cast = { dir = "c2s", rate = 2, shape = { origin = "Vector3", target = "Vector3" } },
	--: The player pulled the line in. The server trusts the *outcome flags*
	--: loosely and re-derives the fish, rewards and records itself.
	ReelResult = { dir = "c2s", rate = 4, shape = { sessionId = "number", won = "boolean", integrity = "number", elapsed = "number" } },
	CancelCast = { dir = "c2s", rate = 2, shape = {} },

	BuyRod = { dir = "c2s", rate = 3, shape = { rod = "string" } },
	BuyBait = { dir = "c2s", rate = 3, shape = { bait = "string", qty = "number" } },
	BuyBoat = { dir = "c2s", rate = 3, shape = { boat = "string" } },
	EquipRod = { dir = "c2s", rate = 3, shape = { rod = "string" } },
	EquipBait = { dir = "c2s", rate = 3, shape = { bait = "string?" } },

	SellCrate = { dir = "c2s", rate = 1, shape = {} },
	UnlockZone = { dir = "c2s", rate = 2, shape = { zone = "string" } },
	TravelTo = { dir = "c2s", rate = 2, shape = { zone = "string" } },

	ClaimQuest = { dir = "c2s", rate = 2, shape = { questId = "string" } },
	ClaimDaily = { dir = "c2s", rate = 2, shape = {} },

	SummonBoat = { dir = "c2s", rate = 2, shape = {} },
	StoreBoat = { dir = "c2s", rate = 2, shape = {} },

	RequestBoard = { dir = "c2s", rate = 1, shape = { board = "string" } },
	SaveSettings = { dir = "c2s", rate = 2, shape = { music = "number", sfx = "number" } },
	TutorialDone = { dir = "c2s", rate = 2, shape = { step = "string" } },

	--: A dialogue choice, by the index the server *offered* -- never a raw
	--: node index, which could reach a branch this player's conditions hid.
	DialogueChoose = { dir = "c2s", rate = 6, shape = { npc = "string", index = "number" } },
	DialogueLeave = { dir = "c2s", rate = 2, shape = { npc = "string" } },

	-- ------------------------ server -> client ------------------------
	--: The whole save, pushed on join and after anything that changes it.
	--: The client reads state from here and never keeps its own.
	ProfileSync = { dir = "s2c" },
	--: A rod is in flight: where the bobber will be and when it lands.
	CastState = { dir = "s2c" },
	--: Something is pulling the line. Carries the minigame parameters.
	Bite = { dir = "s2c" },
	--: The line came out of the water, one way or the other.
	CastEnd = { dir = "s2c" },
	--: The catch, revealed. This is the payoff screen's payload.
	CatchResult = { dir = "s2c" },
	Notify = { dir = "s2c" },
	LevelUp = { dir = "s2c" },
	WeatherSync = { dir = "s2c" },
	BoardSync = { dir = "s2c" },
	QuestSync = { dir = "s2c" },

	--: A conversation opened or moved: one node's words and what may answer
	--: them. The client renders these and sends back an index.
	DialogueOpen = { dir = "s2c" },
	DialogueNode = { dir = "s2c" },
	--: A choice resolved to a door, not a reply. `to` names the panel.
	DialogueAction = { dir = "s2c" },
	DialogueClose = { dir = "s2c" },
}

Net.define(Wire.Specs)

return Wire
