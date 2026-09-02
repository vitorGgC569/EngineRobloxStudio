--!strict
--[[
	Lanternreach — server bootstrap.

	Second game on Forge. It shares the engine with Proving Ground and nothing
	else: no combat, no enemies, no arena, no shared file. Different genre,
	different loop, same twenty modules.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

-- The engine contract this game was written against. Before 1.0 the minor
-- number carries breaking changes, so a mismatch here is a real one.
Forge.require("0.2.0")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Rig = Forge.Rig
local Inventory = Forge.Inventory
local Progression = Forge.Progression
local Quest = Forge.Quest
local Debug = Forge.Debug
local Telemetry = Forge.Telemetry
local Events = Forge.Events

local startedAt = os.clock()

Rng.seed(Config.seed)
Players.CharacterAutoLoads = false

for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

Net.define({
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	Opened = { dir = "s2c" },
	Dialogue = { dir = "s2c" },
	Quests = { dir = "s2c" },

	DialogueChoice = { dir = "c2s", rate = 6, shape = { index = "number" } },
	AcceptQuest = { dir = "c2s", rate = 4, shape = { quest = "string" } },
})

Content.load()

-- Telemetry before anything can fail, so a failure during startup is itself
-- recorded. The sink is the game's choice; `printSink` is development only.
Telemetry.printSink()
--[[
	A destination, then the pump.

	This game called `start` and never registered a sink, so every event it
	raised was buffered and thrown away — invisible from inside, because a
	telemetry system with no sink reports itself as perfectly healthy.
]]
Telemetry.dataStoreSink()
Telemetry.start()

-- The onboarding funnel. Four steps, and the drop between any two is the
-- question a designer actually asks.
Events.on("salvage.opened", function(payload)
	Telemetry.funnel("onboarding", 2, payload.subject)
	Telemetry.event("salvage.opened", { kind = payload.kind, subject = payload.subject })
	Telemetry.mark(payload.subject, "first_salvage")
end)
Events.on("keeper.sold", function(payload)
	Telemetry.funnel("onboarding", 3, payload.subject)
	Telemetry.event("economy.sold", { amount = payload.amount, subject = payload.subject })
end)
Events.on("quest.completed", function(payload)
	Telemetry.funnel("onboarding", 4, payload.subject)
	Telemetry.event("quest.completed", { quest = payload.quest, subject = payload.subject })
end)


Save.configure({
	store = Config.saveStore,
	version = 1,
	template = {
		satchel = nil,
		progression = nil,
		quests = nil,
		nightsWorked = 0,
	},
})
Save.start()

local Weather = Forge.Weather
local LiveOps = Forge.LiveOps
local Destruction = Forge.Destruction

local Systems = script:WaitForChild("systems")
local Shore = require(Systems.Shore)
local Salvage = require(Systems.Salvage)
local Keeper = require(Systems.Keeper)

--[[
	Weather, config and destruction, from the engine.

	Not decoration on this list: until now every module built for Proving
	Ground had exactly one consumer, which makes it indistinguishable from that
	game's own code living in the engine folder. A second game using the same
	surface is what proves an API is an API.

	Each one earns its place here on its own terms. A night shore is the most
	natural home weather will ever have; salvage rates are exactly the kind of
	number worth changing without a release; and a cache that bursts open is a
	better answer than one that vanishes.
]]
Weather.installDefaults()
LiveOps.defineMany({
	["salvage.maxCaches"] = 12,
	["salvage.respawnSeconds"] = 25,
	["flag.nightFog"] = true,
})
LiveOps.start()

Destruction.define("cache", {
	shards = 10,
	spread = 14,
	upward = 10,
	life = 6,
	scale = 1.2,
})

Shore.start()
Salvage.start()
Keeper.start()

--[[
	Fog and rain over the shelf.

	Server-side here rather than client-side, unlike Proving Ground: this game
	has no pinned hour to protect, and the tide's mood is part of what it is.
	The condition is set once and cycled slowly; clients render whatever is in
	force.
]]
if LiveOps.enabled("nightFog") then
	Weather.set("overcast", { immediate = true })
	Weather.cycle({ "overcast", "rain", "overcast", "clear" }, 240)
end

-- The editor edits the same scene the streamer is serving, so a piece moved in
-- the overlay lands in the chunk it now belongs to instead of the one it used
-- to. Authorisation defaults to Studio-only; a live game names its people.
local Editor = Forge.Editor
Editor.attachStreamer(Shore.streamer)
Editor.open(Shore.scene)
Editor.serve()

Debug.probe("streaming", function()
        return Forge.Streaming.describe()
end)

Debug.probe("editor", Editor.describe)
Debug.probe("onboarding", function()
        return Telemetry.funnelReport("onboarding")
end)

-- ============================== the player ==================================
local function subjectOf(player: Player): string
	return "player:" .. player.UserId
end

local function onCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.WalkSpeed = 15
	Rig.stripDefaultAnimate(character)
	character:PivotTo(CFrame.new(Shore.dock + Vector3.new(math.random(-5, 5), 0, math.random(-5, 5))))

	-- A lantern, because the whole map is dark and this is the only way to see
	-- your own feet between lighthouse sweeps.
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local lantern = Instance.new("PointLight")
	lantern.Name = "Lantern"
	lantern.Color = Color3.fromRGB(255, 214, 150)
	lantern.Range = 34
	lantern.Brightness = 1.8
	lantern.Parent = root
end

local function attachPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		onCharacter(player, player.Character)
	end
end

Players.PlayerAdded:Connect(attachPlayer)
for _, player in Players:GetPlayers() do
	attachPlayer(player)
end

-- `observe` and not `onLoaded:Connect`: the world takes seconds to write and
-- the Studio player is already here by then.
Save.observe(function(player, profile)
	local subject = subjectOf(player)

	if profile.satchel then
		Inventory.deserialize(subject, profile.satchel, { slots = Config.satchelSlots })
	else
		Inventory.create(subject, { slots = Config.satchelSlots, currencies = { coin = 0 } })
	end
	if profile.progression then
		Progression.deserialize(profile.progression)
	end
	Quest.deserialize(subject, profile.quests)

	-- Satchel capacity is what a level actually buys here.
	local track = Progression.track("reach", subject)
	local bag = Inventory.get(subject)
	bag.slots = Config.satchelSlots + (Progression.totals(track).satchel or 0)

	if not player.Character then
		player:LoadCharacter()
	end

	-- Step one is simply arriving with a body. A funnel that starts at the
	-- first *action* cannot see the players who never got one.
	Telemetry.funnel("onboarding", 1, subject)

	Keeper.sync(player)
	Net.fire(player, "Notify", {
		text = "Low tide. Search the shelf, bring it to the light. [F] to speak.",
		color = Color3.fromRGB(238, 202, 128),
	})
end)

Save.onSaving:Connect(function(player, profile)
	local subject = subjectOf(player)
	local bag = Inventory.get(subject)
	if bag then
		profile.satchel = Inventory.serialize(bag)
	end
	profile.progression = Progression.serialize(Progression.track("reach", subject))
	profile.quests = Quest.serialize(subject)
end)

Players.CharacterAutoLoads = true

task.defer(function()
	for _, player in Players:GetPlayers() do
		if not player.Character then
			player:LoadCharacter()
		end
	end
end)

-- ================================ the seam ==================================
--[[
	The live suite, if this is Studio.

	Last, after every system is up: a suite that starts before the game does
	tests a game that does not exist yet. Deferred so bootstrap returns first.

	The point of running it *here* is not this game's coverage. It is that
	`Testing` was built inside Proving Ground and had only ever run there,
	which made it a Proving Ground helper with an engine address. A second game
	running the same harness against inventories, entities and dialogue instead
	of combat is what makes it engine surface.
]]
if Config.selfTest then
	task.defer(function()
		local Testing = Forge.Testing
		local suite = script:FindFirstChild("tests")
		local report = Testing.runAndPublish(suite, nil, "lanternreach")
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
