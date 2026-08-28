--!strict
--[[
	Channels — the one declaration of the wire, required by both VMs.

	`Net.define` is per-VM: a channel the server declares does not exist on the
	client until the client declares it too. Two hand-written copies is the bug
	where a control works in Studio's server view and does nothing in a real
	session, so there is exactly one list and both sides require it.

	The client sends two things and neither carries a value the server trusts:
	`Pull` names a chute and nothing else — not what is in it, not what it is
	worth — and `Buy` names an upgrade and no price.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net

local Channels = {}

function Channels.define()
	Net.define({
		--: server -> client
		--: The shift: score, strikes, speed, multiplier, phase, and the queue
		--: the player is allowed to see. Pushed on change and on a slow timer.
		Shift = { dir = "s2c" },
		--: Per-player: coins and upgrade levels.
		You = { dir = "s2c" },
		--: A gate moved. Sent to everyone so a second operator can see it.
		Gate = { dir = "s2c" },
		--: One crate resolved: sorted, contaminated or overflowed.
		Sorted = { dir = "s2c" },
		Notify = { dir = "s2c" },

		--: client -> server
		--: "Pull the lever at this chute." The server checks the player is
		--: actually standing there; an id from the client is an id the client
		--: can change, and the exploit is otherwise sorting from the spawn.
		Pull = { dir = "c2s", rate = 8, shape = { chute = "string" } },
		Buy = { dir = "c2s", rate = 3, shape = { id = "string" } },
	})
end

return Channels
