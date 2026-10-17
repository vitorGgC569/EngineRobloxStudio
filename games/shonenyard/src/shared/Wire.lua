--!strict
--[[
	Wire — the network contract, defined once and required by both sides.

	The bug this exists to fix
	--------------------------

	`Net.define` builds its channel table **per Lua VM**. The server called it
	and the client did not, so on the client every channel was undefined:
	`Net.send("Summon", ...)` had nothing to send down and
	`Net.on("Summoned", ...)` bound a handler to a channel that did not exist.

	What a player saw: they pressed UNSEAL A SCROLL, the largest thing on the
	screen and the entire game, and nothing happened. No error, no message, no
	reveal card -- ever, for anybody.

	It survived every gate this repository has. It compiles, it type-checks,
	`forge doctor` reports zero errors, eleven live scenarios pass, and the
	screenshots look right, because the failure is in a click handler and no
	automated check in this project has ever clicked the button. A person
	opened the game and found it in four seconds.

	So the definitions live here, in `Shared`, and both sides require this
	module. There is no arrangement in which one has them and the other does
	not.

	Reading the table
	-----------------

	`dir` is from the server's point of view: `s2c` is the server telling the
	client, `c2s` is the client asking the server. Every `c2s` entry carries a
	rate and a shape, which is not a style rule -- it is the difference between
	a game and an exploit surface.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net

local Wire = {}

Wire.channels = {
	-- server -> client
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	--: The reveal is its own channel, not a field on `StateSync`. A draw
	--: folded into a state broadcast arrives with everything else and reads as
	--: a number changing, and a number changing is not why anybody opens the
	--: next one.
	Summoned = { dir = "s2c" },
	Findings = { dir = "s2c" },
	-- client -> server
	Ping = { dir = "c2s", rate = 2, shape = {} },
	--: The client says *which* scroll; the server says what it costs and
	--: whether it is affordable. A payload carrying a price is a payload
	--: somebody will edit.
	Summon = { dir = "c2s", rate = 4, shape = { scroll = "string" } },
	BuyStation = { dir = "c2s", rate = 2, shape = { station = "string" } },
	Assign = { dir = "c2s", rate = 6,
		shape = { station = "string", fighter = "string" } },
	Promote = { dir = "c2s", rate = 2, shape = {} },
	Ascend = { dir = "c2s", rate = 1, shape = {} },
	SawCollection = { dir = "c2s", rate = 2, shape = {} },
}

--[[
	Define the channels in whichever VM is asking.

	Idempotent, because both a bootstrap and a later require may call it and
	`Net.define` on an already-defined channel must not be a second channel.
]]
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
