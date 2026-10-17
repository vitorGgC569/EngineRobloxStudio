--!strict
--[[
	Server bootstrap. The order here is the dependency graph, written down.

	World first, because docks, spawn and water checks have to exist before a
	boat or a cast can ask about them. Data before anything that reads a
	profile. Wire before any service, because `Net.define` is per-VM and an
	`Net.on` for a channel that was never declared is not a warning -- it is
	a dead handler.

	Nothing here iterates a folder to find services. An explicit list is the
	one place a reader can see what runs and in what order.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

--[[
	No character until the world can hold one.

	Roblox loads the character the moment a player joins, which here is a
	minute before the terrain, the spawn and the docks exist. Measured: with
	auto-load on, the first character was dropped in open water 960 studs
	from the harbor and swam there for the entire session. The world builds
	first; the character is loaded through the same door deaths use.
]]
Players.CharacterAutoLoads = false

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Debug = Forge.Debug
local Rng = Forge.Core.Rng
local Mark = Forge.Mark

--[[
	The netcode remotes must exist before anyone asks for them.

	`Debug.expose` makes every Forge module describe itself, and that loop
	requires *all* of them -- including Netcode, which wires its channels at
	load. On the client the loop runs at boot; on this server it used to run
	only after the world build, so the first client snapshot spent twenty
	seconds in `WaitForChild` and then errored. The engine documents the
	server as owning these remotes from the first line of the bootstrap;
	loading it here, before the world, is exactly that line.
]]
local Netcode = Forge.Netcode
assert(Netcode, "netcode wired at load")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

--: The network contract must exist in this VM before any service subscribes.
local Wire = require(Shared.Wire)
assert(Wire, "wire declared")

Rng.seed(Config.seed)

for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

--: Bobber parts are gameplay, not dressing; the quality engine skips the
--: whole folder so a ripple does not read as an unclassified prop.
local bobbers = Workspace:FindFirstChild("Bobbers")
if bobbers then
	Mark.exclude(bobbers)
end

local DataService = require(script.Services.DataService)
local WorldService = require(script.Services.WorldService)
local WeatherService = require(script.Services.WeatherService)
local QuestService = require(script.Services.QuestService)
local BestiaryService = require(script.Services.BestiaryService)
local LeaderboardService = require(script.Services.LeaderboardService)
local FishingService = require(script.Services.FishingService)
local EconomyService = require(script.Services.EconomyService)
local BoatService = require(script.Services.BoatService)
local NpcService = require(script.Services.NpcService)
local LandmarkService = require(script.Services.LandmarkService)

WorldService.start()
--: The terrain is painted before landmarks stand on it. Guarded: landmarks
--: are the one purely decorative service, and a bad prop must not take the
--: whole boot (saves, quests, boats) down with it -- measured twice today.
local landmarkOk, landmarkError = pcall(function()
	LandmarkService.start({ WorldService = WorldService })
end)
if not landmarkOk then
	Debug.warn("landmarks failed to start: " .. tostring(landmarkError))
end
WeatherService.start()
DataService.start()
QuestService.start()
LeaderboardService.start()
FishingService.start()
EconomyService.start()
BoatService.start()
--: After the world: NPCs stand on the docks WorldService just built.
NpcService.start()

--: The world exists now, so the first character may. Joins that raced ahead
--: of the build wait in `GetPlayers`; later joins come through `PlayerAdded`.
--: Deaths respawn through the same door, a beat later.
local function bindRespawn(player: Player)
	player.CharacterAdded:Connect(function(character)
		--: Characters are players, not scenery.
		Mark.exclude(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid then
			(humanoid :: Humanoid).Died:Connect(function()
				task.wait(4)
				if player.Parent then
					player:LoadCharacter()
				end
			end)
		end
	end)
end

for _, player in Players:GetPlayers() do
	bindRespawn(player)
	player:LoadCharacter()
end

Players.PlayerAdded:Connect(function(player)
	bindRespawn(player)
	player:LoadCharacter()
end)

Debug.expose()

if Config.selfTest and RunService:IsStudio() then
	local Smoke = require(script.Tests.Smoke)
	Smoke.run({
		DataService = DataService,
		WorldService = WorldService,
		WeatherService = WeatherService,
		QuestService = QuestService,
		BestiaryService = BestiaryService,
		LeaderboardService = LeaderboardService,
		FishingService = FishingService,
		EconomyService = EconomyService,
		BoatService = BoatService,
		NpcService = NpcService,
	})
end

Debug.ready("tidebound-server")
Debug.info("Tidebound server booted")
