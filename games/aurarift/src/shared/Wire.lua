--[[
	Wire — the network contract, defined once and required by both sides.

	`Net.define` builds its channel table per Lua VM. The server calling it
	and the client not calling it produced a game where the summon button did
	nothing for anybody, with no error anywhere (games/shonenyard, four
	seconds for a person to find, invisible to every gate).

	So the definitions live here and both sides require this module. There is
	no arrangement in which one side has them and the other does not.

	Reading the table
	-----------------
	`dir` is from the server's point of view. Every `c2s` entry carries a
	rate and a shape; a payload carrying a price or a payout is a payload
	somebody will edit, so those travel nowhere — the server owns them all.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net

local Wire = {}

Wire.channels = {
	-- ============================ server -> client ==========================
	--: Full refresh of everything the interface shows. Display strings for
	--: big numbers are formatted server-side.
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	--: A reveal is its own message, not a field on StateSync. A draw folded
	--: into a state broadcast reads as a number changing, and a number
	--: changing is not why anybody presses summon again.
	Rolled = { dir = "s2c" },
	--: Divine+ draws are announced to the whole server.
	Announce = { dir = "s2c" },
	--: Tower fight progress, 4 Hz while a fight is live.
	Battle = { dir = "s2c" },
	--: One leaderboard page, answered to BoardRefresh.
	Board = { dir = "s2c" },

	-- ============================ client -> server ==========================
	--: The client says hello when its loop is up; the server answers with
	--: StateSync. Without this a client that loaded after the join-broadcast
	--: would sit on an empty interface.
	Hello = { dir = "c2s", rate = 2, shape = {} },
	--: Which batch to draw; the server decides what it costs.
	Roll = { dir = "c2s", rate = 8, shape = { count = "number?" } },
	GemRoll = { dir = "c2s", rate = 4, shape = { count = "number?" } },
	Equip = { dir = "c2s", rate = 8, shape = { card = "string", slot = "number" } },
	Unequip = { dir = "c2s", rate = 8, shape = { slot = "number" } },
	Upgrade = { dir = "c2s", rate = 6, shape = { id = "string" } },
	Ascend = { dir = "c2s", rate = 1, shape = {} },
	ClaimDaily = { dir = "c2s", rate = 2, shape = {} },
	ClaimOffline = { dir = "c2s", rate = 2, shape = {} },
	SetAuto = { dir = "c2s", rate = 4, shape = { on = "boolean" } },
	BattleStart = { dir = "c2s", rate = 4, shape = { floor = "number?" } },
	BattleStop = { dir = "c2s", rate = 4, shape = {} },
	BoardRefresh = { dir = "c2s", rate = 2, shape = { board = "string" } },
}

--: Idempotent, because a bootstrap and a later require may both call it.
local defined = false

function Wire.install()
	if defined then
		return
	end
	defined = true
	Net.define(Wire.channels)
end

Wire.install()

return Wire
