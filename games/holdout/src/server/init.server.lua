--!strict
--[[
	holdout — server bootstrap.

	This file wires the engine and nothing else. Every line below is
	infrastructure; none of it decides what your game is.

	Add gameplay in `src/server/systems/`. The rule that keeps this project
	from turning into the thing Forge exists to replace: no system in here may
	be a template of a genre. Write the game you mean.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

-- The engine contract this project was scaffolded against. Keep it: an engine
-- that moves under a game fails far from the line that caused it.
Forge.require("0.2.0")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Map = require(Shared:WaitForChild("Map"))
local Posture = require(Shared:WaitForChild("Posture"))
local Wire = require(Shared:WaitForChild("Wire"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug

local startedAt = os.clock()

-- 1. Determinism where it belongs: one seed, named streams downstream.
Rng.seed(Config.seed)

--: Remotes before any handler. A handler registered first attaches to nothing
--: and the client's call hangs until it times out, which looks exactly like a
--: broken button.
Wire.install()

--[[
	Named places, with geography.

	`World.Areas` gained `center`/`radius` for this: a location readout and a
	minimap both need to answer "which area is this point in", and before that
	the module could only answer "may this player enter". The bounds live in
	`Map` so the client draws the same circles the server tests against.
]]
--: The layout comes from `World`, is adopted by `Map`, and only then becomes
--: areas. One source, three readers, and no way for them to drift.
do
	local Layout = require(script.systems.World)
	Map.adopt(Layout.DISTRICTS, Layout.LANDMARKS)
	for _, area in Map.areas do
		Forge.World.Areas.define(area.id, {
			label = area.label, center = area.center, radius = area.radius,
			priority = area.priority, safe = true,
		})
	end
end

-- 2. Runtime containers. Anything the game creates lives in one of these, so a
--    validator can count them and a cleanup can find them.
for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

-- 3. The world, before anybody can stand in it.
--
--    Built here rather than lazily on join, because a player arrives faster
--    than a world builds and the failure mode is a character in freefall
--    against an empty sky. That has happened twice in this repository already.
--[[
	Nobody stands in a world that is still being built.

	Moving the spawn pad to the front of `World.build` gave a player somewhere
	to stand from the first frame, and introduced a worse problem: terrain is
	carved *underneath* a character who is already standing there, and Roblox
	ejects anything a new voxel intersects. The player was launched over the
	valley.

	Holding character loading until the world exists is the fix with no other
	side. It costs the eleven seconds the terrain was always going to take, and
	during them a player waits instead of being thrown.
]]
Players.CharacterAutoLoads = false

local World = require(script.systems.World)
local built = World.build()

Players.CharacterAutoLoads = true
for _, player in Players:GetPlayers() do
	if not player.Character then
		player:LoadCharacter()
	end
end
local Caches = require(script.systems.Caches)
local Fight = require(script.systems.Fight)
Fight.start()
local stocked = Caches.build(Workspace:WaitForChild("World"))
Debug.info(string.format("world: %d trees, %d rocks, %d ruins, %d caches",
	built.trees or 0, built.rocks or 0, built.ruins or 0, stocked))

-- =============================== the player =================================
--[[
	Posture, owned by the server.

	It looks like overkill for a crouch key right up until you remember that
	posture changes a hitbox height and an accuracy multiplier: a client that
	could declare itself prone would be shrinking its own target for free, and
	skipping the second and a half it costs to get up.
]]
local posture: { [Player]: string } = {}
local changing: { [Player]: number } = {}
local sprinting: { [Player]: boolean } = {}
local aiming: { [Player]: boolean } = {}

local function applyPosture(player: Player, id: string)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local state = Posture.get(id)
	humanoid.WalkSpeed = Posture.speed(id, sprinting[player])
	--[[
		The camera drops. The character does not.

		`HipHeight` is how far the root floats above the feet, so lowering it
		pulls the torso down while the legs stay the length they were -- the
		character sinks into the ground up to the waist, which is exactly what
		the first build did.

		Crouching *visually* needs an animation that bends the knees, and this
		project has no crouch clip. So the posture is real in every way that
		decides a fight -- view height, speed, spread, and the hit profile the
		server tests against -- and not yet real in the way it looks to
		somebody else. Saying that plainly beats shipping a player buried in a
		field.
	]]
	--[[
		And the character is left alone entirely.

		This wrote `HipHeight = 2` to undo an earlier version that lowered it.
		Writing it at all is the mistake: this avatar's rig is built from
		`AnimationConstraint` and `BallSocketConstraint`, not `Motor6D`, so the
		root height is one term in a physics solve rather than a number that
		describes the character. Forcing a value the solver did not arrive at
		makes it correct the difference, and pressing crouch launched the player
		over the valley.

		Posture stays real in every way that decides a fight -- view height,
		speed, spread, hit profile. What it still does not do is *look* like
		crouching, and on this rig that needs the joints driven directly or an
		animation to drive them. Neither exists here yet, and pretending
		otherwise by shoving the root around is what caused the flight.
	]]
	player:SetAttribute("posture", id)
	player:SetAttribute("profile", state.profile)
	Net.fire(player, "postured", { posture = id, speed = humanoid.WalkSpeed,
		drop = state.drop, profile = state.profile })
end

Net.on("posture", function(player: Player, payload: any)
	local from = posture[player] or "stand"
	local to = tostring((payload or {}).to)
	local ok, why = Posture.mayChange(from, to)
	if not ok then
		return { ok = false, reason = why }
	end
	local now = os.clock()
	if now < (changing[player] or 0) then
		return { ok = false, reason = "still moving" }
	end
	local seconds = Posture.duration(from, to)
	changing[player] = now + seconds
	posture[player] = to
	--: Speed drops immediately and the rest lands when the change finishes, so
	--: standing up is slow in the way a player can feel rather than in a
	--: number they never see.
	applyPosture(player, to)
	return { ok = true, detail = { posture = to, seconds = seconds } }
end)

Net.on("sprint", function(player: Player, payload: any)
	sprinting[player] = (payload or {}).on == true
	applyPosture(player, posture[player] or "stand")
	return { ok = true }
end)

Net.on("aim", function(player: Player, payload: any)
	aiming[player] = (payload or {}).on == true
	player:SetAttribute("aiming", aiming[player])
	return { ok = true }
end)

Net.on("loot", function(player: Player, payload: any)
	local name = tostring((payload or {}).container)
	local world = Workspace:FindFirstChild("World")
	local box = world and world:FindFirstChild(name, true)
	if not (box and box:IsA("BasePart") and box.Name == "Cache") then
		return { ok = false, reason = "no such container" }
	end
	local ok, detail = Caches.open(player.Character, box)
	if not ok then
		Net.fire(player, "notice", { kind = "refused", text = tostring(detail) })
		return { ok = false, reason = tostring(detail) }
	end
	Net.fire(player, "looted", detail)
	return { ok = true, detail = detail }
end)

--[[
	Picking a gun up arms you with it.

	The first build spilled a rifle on the floor, let a player take it, and did
	nothing -- the drop vanished and the player was still empty-handed. A
	pickup that does not change what you are holding is a pickup that did not
	happen.
]]
Net.on("pickup", function(player: Player, payload: any)
	local ok, detail = Caches.take(player.Character, tostring((payload or {}).drop))
	if not ok then
		return { ok = false, reason = tostring(detail) }
	end
	if detail.kind == "gun" then
		local armed, info = Fight.give(player, detail.id)
		if armed then
			Net.fire(player, "armed", info)
			Net.fire(player, "notice", { kind = "good", text = info.name })
			return { ok = true, detail = info }
		end
	end
	Net.fire(player, "notice",
		{ kind = "good", text = "Picked up " .. tostring(detail.id) })
	return { ok = true, detail = detail }
end)

Net.on("fire", function(player: Player, payload: any)
	local p = payload or {}
	local direction = Vector3.new(tonumber(p.x) or 0, tonumber(p.y) or 0,
		tonumber(p.z) or 0)
	local ok, detail = Fight.shoot(player, direction, aiming[player],
		posture[player] or "stand")
	if not ok then
		--: Silent. A shooter that toasts "too fast" on every held trigger is a
		--: shooter nobody can read the screen of.
		return { ok = false, reason = tostring(detail) }
	end
	Net.fire(player, "shot", detail)
	return { ok = true, detail = detail }
end)

Net.on("reload", function(player: Player)
	local ok, detail = Fight.reload(player)
	return { ok = ok, detail = detail }
end)

Net.on("atlas", function()
	--: The map does not move, so this is asked once and never polled.
	return { areas = Map.layout(), extent = Map.EXTENT, cell = Map.CELL,
		columns = Map.COLUMNS }
end)

--: The caches are server-owned prompts, so no client claim is involved in
--: opening one at all.
game:GetService("ProximityPromptService").PromptTriggered:Connect(
	function(prompt, player)
		local part = prompt.Parent
		if not (part and part:IsA("BasePart")) then
			return
		end
		if prompt.Name == "Open" and part:GetAttribute("cache") then
			local ok, detail = Caches.open(player.Character, part)
			if ok then
				Net.fire(player, "looted", detail)
			else
				Net.fire(player, "notice",
					{ kind = "refused", text = tostring(detail) })
			end
		elseif prompt.Name == "Take" and part:GetAttribute("drop") then
			local ok, detail = Caches.take(player.Character,
				tostring(part:GetAttribute("drop")))
			if ok then
				Net.fire(player, "notice",
					{ kind = "good", text = "Picked up " .. tostring(detail.id) })
			end
		end
	end)

--[[
	Where everybody is, four times a second.

	Not per frame: a grid reference that updates sixty times a second is one
	nobody can read, and the minimap interpolates its own dot from the
	character it can already see. This is for the words.
]]
task.spawn(function()
	while true do
		task.wait(0.25)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local areaId = Forge.World.Areas.at(root.Position)
				Net.fire(player, "located", Map.locate(root.Position, areaId))
			end
		end
	end
end)

--[[
	Set up everybody, including the ones already here.

	The world takes eleven seconds to carve and a player joins in two, so by
	the time this line runs the local player in Studio has already arrived and
	`PlayerAdded` will never fire for them. Connecting and *also* replaying is
	the only shape that works, and the failure without it is total and silent:
	no gun, no posture, no location, no error.
]]
local function setUp(player: Player)
	local function onCharacter()
		posture[player] = "stand"
		sprinting[player], aiming[player] = false, false
		applyPosture(player, "stand")
		--: Everybody starts with a sidearm. The loop is finding something
		--: better; starting empty is a five-minute walk before the game begins.
		local ok, info = Fight.give(player, "m9")
		if ok then
			Net.fire(player, "armed", info)
		end
	end
	player.CharacterAdded:Connect(function()
		task.defer(onCharacter)
	end)
	if player.Character then
		task.defer(onCharacter)
	end
end

for _, player in Players:GetPlayers() do
	setUp(player)
end
Players.PlayerAdded:Connect(setUp)

Players.PlayerRemoving:Connect(function(player)
	Fight.drop(player)
	posture[player], changing[player] = nil, nil
	sprinting[player], aiming[player] = nil, nil
end)

-- 4. Persistence. The template is the shape of a new player's save.
Save.configure({
	store = Config.saveStore,
	version = 1,
	template = {
		-- add your fields here; anything you add later is backfilled
		-- automatically for existing players
	},
})
Save.start()

-- `observe` connects AND replays for players whose profile already loaded.
-- A plain `onLoaded:Connect` here silently misses the Studio local player,
-- because they join before the bootstrap finishes.
--: The scaffold fired a `StateSync` remote here that this game's own network
--: contract does not declare, so the first profile load threw. Left alone
--: until there is a save shape worth sending; a remote defined for the sake
--: of the line that uses it is how a contract stops meaning anything.
Save.observe(function(player, profile)
	Debug.count("profiles.loaded")
end)

-- 5. Your systems. Each one is a module with a `start()`.
local systems = script:FindFirstChild("systems")
if systems then
	for _, module in systems:GetChildren() do
		if module:IsA("ModuleScript") then
			local ok, system = pcall(require, module)
			if not ok then
				Debug.error(string.format("system '%s' failed to load: %s", module.Name, tostring(system)))
				continue
			end
			if type(system) == "table" and type(system.start) == "function" then
				local started, err = pcall(system.start)
				if not started then
					Debug.error(string.format("system '%s' failed to start: %s", module.Name, tostring(err)))
				end
			end
		end
	end
end

--[[
	6. The live suite.

	Runs after every system is up, because a suite that starts first tests a
	game that does not exist yet. Studio only: the scenarios build and destroy
	real instances, which does not belong in a session somebody is playing.

	`forge gametest` reads the report this publishes. That command is the only
	thing in this project that can answer "does the game still work" without a
	person watching a screen, and it needs this line to have anything to read.
]]
if Config.selfTest then
	task.defer(function()
		local report = Forge.Testing.runAndPublish(script:FindFirstChild("tests"), nil, "holdout")
		Debug.info(string.format(
			"self test: %d passed, %d failed, %d hung",
			report.passed or 0, report.failed or 0, report.timedOut or 0))
	end)
end

-- 7. The seam. This is what lets the Quality Engine measure meaning and not
--    just geometry. Removing it does not break the game; it blinds the
--    validator, which is worse.
Debug.expose()

Debug.probe("session", function()
	return {
		uptime = os.clock() - startedAt,
		players = #Players:GetPlayers(),
		seed = Rng.masterSeed(),
	}
end)

--: The last line of the bootstrap, and the only honest answer to "is it up".
--: Everything that photographs or measures this game waits for it.
Debug.ready(Config.name)

Debug.info(string.format("%s up in %.2fs", Config.name, os.clock() - startedAt))
print(string.format("[%s] server ready in %.2fs (seed %d)", Config.name, os.clock() - startedAt, Config.seed))
