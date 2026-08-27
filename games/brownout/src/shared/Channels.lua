--!strict
--[[
	Channels — the one declaration of the wire, required by both VMs.

	`Net.define` is per-VM: the server declaring a channel does not make it
	exist on the client. Two copies of this list is the bug where a button
	works in Studio's server view and does nothing in a real session, so there
	is exactly one list and both sides require it.

	Every c2s entry carries a rate and a shape. The client is not trusted to
	say what a deposit is worth -- it says only "I pressed the thing", and the
	server decides everything that follows.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net

local Channels = {}

function Channels.define()
	Net.define({
		--: server -> client
		--: The whole shift, pushed on change: charge, radius, phase, clock.
		Shift = { dir = "s2c" },
		--: Per-player: watts, upgrades, what they are carrying, exposure.
		You = { dir = "s2c" },
		--: One-shot feedback the client turns into a toast and a sound.
		Notify = { dir = "s2c" },
		--: A cell was deposited: everyone sees the surge at the generator.
		Surge = { dir = "s2c" },

		--: client -> server
		--: "I want the cell nearest me." The server picks it, not the client:
		--: an id from the client is an id the client can lie about.
		Grab = { dir = "c2s", rate = 4, shape = {} },
		Drop = { dir = "c2s", rate = 4, shape = {} },
		Buy = { dir = "c2s", rate = 3, shape = { id = "string" } },
	})
end

return Channels
