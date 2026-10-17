--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Wire = {}

Wire.definitions = {
	-- s2c
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	Hit = { dir = "s2c" },
	XpGain = { dir = "s2c" },
	LevelUp = { dir = "s2c" },
	-- c2s
	Attack = { dir = "c2s", rate = 6, shape = { kind = "string" } },
	Fireball = { dir = "c2s", rate = 3, shape = { x = "number", y = "number", z = "number" } },
	Dash = { dir = "c2s", rate = 2, shape = { x = "number", z = "number" } },
}

function Wire.install()
	Forge.Net.define(Wire.definitions)
end

return Wire