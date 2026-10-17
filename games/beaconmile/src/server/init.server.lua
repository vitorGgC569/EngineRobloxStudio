--!strict
--[[
	Beaconmile — server bootstrap.

	Wiring only. The road, the coal and the clock live in the systems this
	file starts, and the numbers live in Config. Ledger owns the profile.
	Carry and Shift call Ledger; they do not keep a second copy.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

Forge.require("0.2.0")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Sim = require(Shared:WaitForChild("Sim"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug

local startedAt = os.clock()

Rng.seed(Config.seed)

for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

Net.define({
	StateSync = { dir = "s2c" },
	TakeCoal = { dir = "c2s", rate = 4, shape = { confirm = "boolean" } },
	FeedBeacon = { dir = "c2s", rate = 4, shape = { beaconId = "string" } },
	PlayAgain = { dir = "c2s", rate = 2, shape = { confirm = "boolean" } },
})

Save.configure({
	store = Config.saveStore,
	version = 1,
	template = Sim.newProfile(),
})
Save.start()

local Systems = script:WaitForChild("systems")
local ORDER = { "Road", "Ledger", "Carry", "Shift" }
local bootFailed = false

for _, name in ORDER do
	local module = Systems:WaitForChild(name)
	local ok, system = pcall(require, module)
	if not ok then
		bootFailed = true
		Debug.error(string.format("system '%s' failed to load: %s", name, tostring(system)))
	elseif type(system) ~= "table" or type(system.start) ~= "function" then
		bootFailed = true
		Debug.error(string.format("system '%s' has no start()", name))
	else
		local started, err = pcall(system.start)
		if not started then
			bootFailed = true
			Debug.error(string.format("system '%s' failed to start: %s", name, tostring(err)))
		end
	end
end

if Config.selfTest then
	task.defer(function()
		local report = Forge.Testing.runAndPublish(script:FindFirstChild("tests"))
		Debug.info(string.format(
			"self test: %d passed, %d failed, %d hung",
			report.passed or 0, report.failed or 0, report.timedOut or 0))
	end)
end

Debug.expose()

Debug.probe("session", function()
	return {
		uptime = os.clock() - startedAt,
		players = #Players:GetPlayers(),
		seed = Rng.masterSeed(),
	}
end)

Debug.info(string.format("%s up in %.2fs", Config.name, os.clock() - startedAt))
-- A failed system used to still announce ready, so a playtest photographed
-- a shift that had never started.
if not bootFailed then
	Debug.ready(Config.name)
end
