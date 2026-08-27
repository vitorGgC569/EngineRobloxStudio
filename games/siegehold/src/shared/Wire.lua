--!strict
--[[
	Wire — the messages the client and the server agree on.

	One file, required by both, so the names and shapes cannot drift. A remote
	defined twice with two spellings is the classic way a UI button stops
	working with no error anywhere: the client fires into a remote nobody
	listens on, and firing into nothing is silent.

	Every `c2s` entry is a *request*, never an instruction. `dailyClaim` does
	not mean "give me the reward" -- it means "I pressed the button". Whether a
	reward is owed is the server's to decide, and it decides from its own
	state, not from anything in the payload. That is why these payloads are
	nearly empty: a payload the server trusts is an exploit waiting for
	somebody to open the developer console.

	The rate limits are per-player and deliberately tight. A claim button
	pressed eight times a second is not a player.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Wire = {}

Wire.definitions = {
	--: "I pressed claim." The server decides whether anything is owed.
	dailyClaim = { dir = "c2s", kind = "function", rate = 2 },
	--: What the calendar looks like right now, for drawing it.
	dailyState = { dir = "c2s", kind = "function", rate = 4 },

	--[[
		There were three more here -- `shopBuy`, `shopStock`, `tierUpgrade` --
		written for panels that turned out to read rather than act: towers are
		raised in the world and tiers are bought by the server the moment the
		balance covers them.

		Removed rather than left in place. A remote with no handler accepts the
		call and hangs until it times out, which is the worst failure mode
		available: the button appears to work and then does nothing, with no
		error on either side. `systems.save` sat declared and dead in this game
		for exactly as long as nobody asked it for anything.
	]]

	--: Server-driven feedback the HUD reacts to. Attributes carry the numbers;
	--: this carries the *event*, because "cash changed" and "you were paid for
	--: a seven-day streak" want different presentation and an attribute
	--: change cannot tell them apart.
	notice = { dir = "s2c", kind = "event" },
}

function Wire.install()
	Forge.Net.define(Wire.definitions)
end

return Wire
