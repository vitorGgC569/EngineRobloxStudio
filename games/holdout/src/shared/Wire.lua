--!strict
--[[
	Wire — the messages the client and the server agree on.

	One file, required by both, so a name cannot drift between them. Firing
	into an undeclared remote raises nothing anywhere and just hangs the
	client, which is why `Net.handles` exists and why there is a scenario that
	checks every c2s entry has a listener.

	Posture is the interesting one
	------------------------------

	It is a `c2s` request and the server decides. That looks like overkill for
	a crouch key until you remember posture changes a player's hitbox height
	and their accuracy: a client that could declare itself prone would be a
	client that shrinks its own hitbox for free.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Wire = {}

Wire.definitions = {
	--: "I pressed C." The server owns the timing, so a player cannot skip the
	--: second and a half it costs to get off the floor.
	posture = { dir = "c2s", kind = "function", rate = 6,
		shape = { to = "string" } },

	--: "I am sprinting" / "I am aiming". Both change accuracy and speed, both
	--: are held rather than toggled, and both are cheap enough to send on
	--: change rather than per frame.
	sprint = { dir = "c2s", kind = "function", rate = 10,
		shape = { on = "boolean" } },
	aim = { dir = "c2s", kind = "function", rate = 10,
		shape = { on = "boolean" } },

	--: "I opened that container." The server checks it exists, is in reach and
	--: is not on cooldown, then decides what was in it.
	loot = { dir = "c2s", kind = "function", rate = 6,
		shape = { container = "string" } },

	--: "I took the thing on the floor."
	pickup = { dir = "c2s", kind = "function", rate = 8,
		shape = { drop = "string" } },

	--: Everything the map screen needs, once. The map does not move.
	atlas = { dir = "c2s", kind = "function", rate = 2 },

	--[[
		"I pulled the trigger, looking this way."

		The direction is the only thing the client is believed about, and only
		within a cone of where its character is actually facing. What was hit,
		how far away and for how much are all recomputed server-side: a client
		that could name its target is a client that shoots through walls.
	]]
	fire = { dir = "c2s", kind = "function", rate = 22,
		shape = { x = "number", y = "number", z = "number" } },
	reload = { dir = "c2s", kind = "function", rate = 3 },

	-- ---------------------------------------------------- server -> client
	notice = { dir = "s2c", kind = "event" },

	--: Posture actually changed, after the transition. The client predicts the
	--: camera immediately and corrects to this.
	postured = { dir = "s2c", kind = "event" },

	--: A container gave something up.
	looted = { dir = "s2c", kind = "event" },

	--: What a shot did, for the tracer, the impact and the hitmarker. The
	--: client draws all three; it decides none of them.
	shot = { dir = "s2c", kind = "event" },

	--: A gun arrived.
	armed = { dir = "s2c", kind = "event" },

	--: Where the player is, for the compass and the grid readout. Sent on a
	--: slow tick rather than per frame: a grid reference that updates sixty
	--: times a second is a grid reference nobody can read.
	located = { dir = "s2c", kind = "event" },
}

function Wire.install()
	Forge.Net.define(Wire.definitions)
end

return Wire
