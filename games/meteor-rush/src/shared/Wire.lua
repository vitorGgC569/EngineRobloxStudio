--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Wire = {}

Wire.definitions = {
	state = { dir = "c2s", kind = "function", rate = 8 },
	buyUpgrade = { dir = "c2s", kind = "function", rate = 5, shape = { id = "string" } },
	collectionSeen = { dir = "c2s", kind = "function", rate = 3 },
	promptPurchase = { dir = "c2s", kind = "function", rate = 2, shape = { id = "string" } },

	State = { dir = "s2c", kind = "event" },
	Notify = { dir = "s2c", kind = "event" },
	Decoded = { dir = "s2c", kind = "event" },
	MeteorClaimed = { dir = "s2c", kind = "event" },
	MeteorSpawned = { dir = "s2c", kind = "event" },
	Shower = { dir = "s2c", kind = "event" },
	Announce = { dir = "s2c", kind = "event" },
}

function Wire.install()
	Forge.Net.define(Wire.definitions)
end

return Wire
