--!strict
--[[
	Saltmere — server bootstrap.

	Wiring only. The tide, the pans and the prices live in the systems this
	file starts, and the numbers live in Config. The order is the dependency
	order: the marsh has to exist before a profile can be given a plot.
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
	Tide = { dir = "s2c" },
	Notify = { dir = "s2c" },

	ClaimPan = { dir = "c2s", rate = 3, shape = { panId = "string" } },
	CollectPan = { dir = "c2s", rate = 4, shape = { panId = "string" } },
	Refine = { dir = "c2s", rate = 3, shape = { kind = "string", amount = "number" } },
	Sell = { dir = "c2s", rate = 4, shape = { grade = "string", amount = "number" } },
	BuyUpgrade = { dir = "c2s", rate = 3, shape = { upgradeId = "string" } },
	UpgradePan = { dir = "c2s", rate = 3, shape = { panId = "string" } },
	Hire = { dir = "c2s", rate = 2, shape = { roleId = "string" } },
	AssignCrew = { dir = "c2s", rate = 3, shape = { crewId = "string", panId = "string" } },
	Prestige = { dir = "c2s", rate = 1, shape = { confirm = "boolean" } },
})

Save.configure({
	store = Config.saveStore,
	version = 1,
	template = Sim.newProfile(),
})
Save.start()

local Systems = script:WaitForChild("systems")
local ORDER = { "Marsh", "Lands", "Ledger", "Works", "Crew", "Rivals", "Market", "Presentation" }

for _, name in ORDER do
	local module = Systems:WaitForChild(name)
	local ok, system = pcall(require, module)
	if not ok then
		Debug.error(string.format("system '%s' failed to load: %s", name, tostring(system)))
	elseif type(system) ~= "table" or type(system.start) ~= "function" then
		Debug.error(string.format("system '%s' has no start()", name))
	else
		local started, err = pcall(system.start)
		if not started then
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
print(string.format("[%s] server ready in %.2fs (seed %d)", Config.name, os.clock() - startedAt, Config.seed))

Debug.ready(Config.name)
