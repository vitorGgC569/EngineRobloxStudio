--!strict
--[[
	Beaconmile — client bootstrap.

	The server decides coal, burn and the shift. This script draws StateSync.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net

Net.define({
	StateSync = { dir = "s2c" },
	TakeCoal = { dir = "c2s", rate = 4, shape = { confirm = "boolean" } },
	FeedBeacon = { dir = "c2s", rate = 4, shape = { beaconId = "string" } },
	PlayAgain = { dir = "c2s", rate = 2, shape = { confirm = "boolean" } },
})

local Hud = require(script:WaitForChild("ui"):WaitForChild("Hud"))
Hud.start(Net)
