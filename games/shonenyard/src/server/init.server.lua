--!strict
--[[
	shonenyard — server bootstrap.

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
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Rng = Forge.Core.Rng
local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug

local startedAt = os.clock()

-- 1. Determinism where it belongs: one seed, named streams downstream.
Rng.seed(Config.seed)

-- 2. Runtime containers. Anything the game creates lives in one of these, so a
--    validator can count them and a cleanup can find them.
for _, name in Config.containers do
	if not Workspace:FindFirstChild(name) then
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = Workspace
	end
end

-- 3. The network contract. Nothing crosses the wire that is not declared here.
--[[
	The contract comes from `Shared.Wire`, which the client requires too.

	It used to be defined here and only here. `Net.define` is per-VM, so the
	client had no channels at all: `Net.send("Summon")` went nowhere and the
	reveal handler bound to nothing. The button that is the entire game did
	nothing for anybody, past a clean compile, a clean doctor and eleven
	passing scenarios.
]]
require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Wire"))

Net.on("Ping", function(player)
	Net.fire(player, "Notify", { text = "pong" })
end)

--[[
	5b. The yard.

	Every handler below is the same three lines: find the player's state, ask
	`Dojo` what the action means, tell the player what happened. Nothing here
	does arithmetic -- that is the system's, and duplicating it in a handler is
	how the screen and the ledger come to disagree.
]]
local Dojo = require(script.systems.Dojo)
local Yard = require(script.systems.Yard)
local Telemetry = Forge.Telemetry

--[[
	The world, before anything that stands in it.

	Built first because a player who lands before the floor exists falls, and a
	falling player reads every other problem in the game as this one. The first
	build of this game had no world at all: every scenario passed and the
	screenshot was empty sky.
]]
local yard = Yard.build()

--[[
	How much of the yard actually arrived.

	`InsertService:LoadAsset` is a network call, and "no errors" is not the same
	as "the models are here" -- a grey game with a clean log is the exact shape
	of failure this repository keeps recording. Published so `forge inspect` and
	`Debug.snapshot` can both read it without anybody guessing from a
	screenshot.
]]
do
	local Dress = require(script.systems.Dress)
	local report = Dress.report()
	Debug.info(string.format("dressing: %d of %d models landed (%.0f%%)",
		report.landed, report.asked, report.rate * 100))
	local marker = Instance.new("StringValue")
	marker.Name = "ShonenDressing"
	marker.Value = string.format("%d/%d", report.landed, report.asked)
	marker.Parent = ReplicatedStorage
end

--[[
	Drain the buffer, or the funnel is a number nobody can read.

	`forge doctor` caught this the first time this file was checked: every
	`Telemetry.funnel` call was counting into a buffer that nothing emptied, so
	the drop-off report this whole design is oriented around would have been
	empty on a published server -- and empty reads exactly like "nobody
	played", which is the answer the two experiences already in the air gave
	when they were finally read.

	The DataStore sink is the one `forge analytics` reads back. It is refused
	in Studio, which is correct: a play session is not a cohort.
]]
Telemetry.start()
if not game:GetService("RunService"):IsStudio() then
	Telemetry.dataStoreSink()
end

local yards: { [Player]: any } = {}

local function push(player: Player)
	local state = yards[player]
	if state == nil then
		return
	end
	local snapshot = Dojo.snapshot(state)

	--[[
		The world redraws with the state, not on a timer.

		A yard whose pads still show last minute's trainees is a yard that
		disagrees with its own HUD, and a player believes the one they are
		standing in. Every path that changes a placement calls `push`, so there
		is one place this can be forgotten rather than eight.
	]]
	for stationId, placement in state.stations do
		Yard.showFighters(yard, stationId, placement.fighters)
	end
	Net.fire(player, "StateSync", snapshot)
	--: Published as attributes as well, so the HUD reads them without a
	--: remote and a validator can read them without the HUD.
	player:SetAttribute("ki", snapshot.ki)
	player:SetAttribute("shards", snapshot.shards)
	player:SetAttribute("perSecond", snapshot.perSecond)
	player:SetAttribute("rank", snapshot.rank)
	player:SetAttribute("collected", snapshot.collected)
	player:SetAttribute("life", snapshot.life)
end

--[[
	Connect *and* replay, because `PlayerAdded` misses the player already here.

	In Studio the local player joins before a server script finishes running,
	so a bare `PlayerAdded:Connect` never fires for them: they stand in the
	yard with no state, every remote does nothing, and the HUD reads dashes
	forever. The scaffold's own comment says this about `Save.observe` and this
	handler made the same mistake three lines away from it.

	It is not only a Studio problem. On a live server a player who joins in the
	same frame the script loads gets the same nothing, and it is unreproducible
	by hand -- which is the worst kind of bug to ship.
]]
local function welcome(player: Player)
	if yards[player] ~= nil then
		return
	end
	yards[player] = Dojo.new("player:" .. player.UserId)
	for stationId in yards[player].stations do
		Yard.markBuilt(yard, stationId)
	end
	Yard.updateRank(yard, yards[player].rank)
	push(player)
	Net.fire(player, "Notify", {
		text = "Your first scroll is free. Unseal it.",
	})
end

Players.PlayerAdded:Connect(welcome)
for _, player in Players:GetPlayers() do
	welcome(player)
end

Players.PlayerRemoving:Connect(function(player)
	yards[player] = nil
end)

Net.on("Summon", function(player, payload)
	local state = yards[player]
	if state == nil then
		return
	end
	local fighter, isNew, step, err = Dojo.summon(state, tostring(payload.scroll))
	if fighter == nil then
		Net.fire(player, "Notify", { text = err or "that scroll did nothing" })
		return
	end
	Net.fire(player, "Summoned", {
		id = fighter.id, name = fighter.name, rarity = fighter.rarity,
		blurb = fighter.blurb, isNew = isNew, step = step,
	})
	push(player)
end)

Net.on("BuyStation", function(player, payload)
	local state = yards[player]
	if state == nil then
		return
	end
	local ok, err = Dojo.buyStation(state, tostring(payload.station))
	Net.fire(player, "Notify", { text = if ok then "Built." else (err or "no") })
	push(player)
end)

Net.on("Assign", function(player, payload)
	local state = yards[player]
	if state == nil then
		return
	end
	local ok, err = Dojo.assign(state, tostring(payload.station),
		tostring(payload.fighter))
	if ok then
		--: The funnel step that says they did something with what they got.
		Dojo.kept(state)
	end
	Net.fire(player, "Notify", { text = if ok then "Training." else (err or "no") })
	push(player)
end)

Net.on("Promote", function(player)
	local state = yards[player]
	if state == nil then
		return
	end
	local ok, err = Dojo.promote(state)
	Net.fire(player, "Notify", {
		text = if ok then ("Rank up: " .. Dojo.snapshot(state).rankName)
			else (err or "no"),
	})
	push(player)
end)

Net.on("Ascend", function(player)
	local state = yards[player]
	if state == nil then
		return
	end
	local ok, err = Dojo.ascend(state)
	Net.fire(player, "Notify", {
		text = if ok then "Ascended. The yard is empty and you are not."
			else (err or "no"),
	})
	push(player)
end)

Net.on("SawCollection", function(player)
	local state = yards[player]
	if state ~= nil then
		Dojo.sawCollection(state)
	end
end)

--[[
	The world's own controls.

	Every prompt calls the same `Dojo` the remotes do. A prompt that took a
	shortcut past the system would be a second implementation of the rules, and
	the two would disagree the first time either changed.

	Reachable from the world rather than only from a menu, because
	`Loop.Hatch`'s dead-time rule is about a player with nothing to press --
	and a player standing in a courtyard is looking at the courtyard.
]]
local function nearestPlayer(part: BasePart): Player?
	for player, _ in yards do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (root :: BasePart).Position then
			return player
		end
	end
	return nil
end

local summonPrompt = yard.altar:FindFirstChild("Summon")
if summonPrompt and summonPrompt:IsA("ProximityPrompt") then
	summonPrompt.Triggered:Connect(function(player)
		local state = yards[player]
		if state == nil then
			return
		end
		local fighter, isNew, step, err = Dojo.summon(state, "novice")
		if fighter == nil then
			Net.fire(player, "Notify", { text = err or "nothing happened" })
			return
		end
		Net.fire(player, "Summoned", {
			id = fighter.id, name = fighter.name, rarity = fighter.rarity,
			blurb = fighter.blurb, isNew = isNew, step = step,
		})
		push(player)
	end)
end

local promotePrompt = yard.rankStone:FindFirstChild("Promote")
if promotePrompt and promotePrompt:IsA("ProximityPrompt") then
	promotePrompt.Triggered:Connect(function(player)
		local state = yards[player]
		if state == nil then
			return
		end
		local ok, err = Dojo.promote(state)
		if ok then
			Yard.updateRank(yard, state.rank)
		end
		Net.fire(player, "Notify", {
			text = if ok then ("Rank up: " .. Dojo.snapshot(state).rankName)
				else (err or "not yet"),
		})
		push(player)
	end)
end

for stationId, pad in yard.pads do
	local prompt = pad:FindFirstChild("Buy")
	if prompt == nil or not prompt:IsA("ProximityPrompt") then
		continue
	end
	prompt.Triggered:Connect(function(player)
		local state = yards[player]
		if state == nil then
			return
		end
		--: One prompt, two meanings, decided by what the player already has.
		--: A separate "assign" prompt would be a second thing to find, and the
		--: player is standing on the pad either way.
		if state.stations[stationId] == nil then
			local ok, err = Dojo.buyStation(state, stationId)
			if ok then
				Yard.markBuilt(yard, stationId)
			end
			Net.fire(player, "Notify", {
				text = if ok then "Built." else (err or "not yet"),
			})
		else
			--: The idlest fighter the player owns that is not already training.
			local placed: { [string]: number } = {}
			for _, other in state.stations do
				for _, id in other.fighters do
					placed[id] = (placed[id] or 0) + 1
				end
			end
			local pick: string? = nil
			local best = -1
			for id, count in state.roster do
				local fighter = require(ReplicatedStorage.Shared.Content).fighter(id)
				if fighter and count > (placed[id] or 0) and fighter.power > best then
					pick, best = id, fighter.power
				end
			end
			if pick == nil then
				Net.fire(player, "Notify", {
					text = "Nobody spare. Unseal a scroll.",
				})
			else
				local ok, err = Dojo.assign(state, stationId, pick)
				if ok then
					Dojo.kept(state)
				end
				Net.fire(player, "Notify", {
					text = if ok then "Training." else (err or "full"),
				})
			end
		end
		push(player)
	end)
end

--[[
	The clock. Everything above declares what exists; this is what makes it
	happen without the player asking.

	One second, not one frame. Production is a per-second quantity and ticking
	it at frame rate makes the number depend on the machine.
]]
task.spawn(function()
	while true do
		task.wait(1)
		for player, state in yards do
			Dojo.tick(state, 1)
			push(player)
			--: What the loop says is going wrong for this player, now. An
			--: idle prompt beats a report next month.
			local findings = Dojo.findings(state)
			if #findings > 0 then
				Net.fire(player, "Findings", { findings = findings })
			end
		end
	end
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
Save.observe(function(player, profile)
	Debug.count("profiles.loaded")
	Net.fire(player, "StateSync", profile)
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
		local report = Forge.Testing.runAndPublish(script:FindFirstChild("tests"), nil, Config.name)
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

Debug.info(string.format("%s up in %.2fs", Config.name, os.clock() - startedAt))
print(string.format("[%s] server ready in %.2fs (seed %d)", Config.name, os.clock() - startedAt, Config.seed))

--[[
	8. The last line, and it must stay last.

	Everything that photographs, measures or tests this game has to know when
	it is up, and without this line each of them guesses. The guesses are all
	versions of watching the screen stop changing, and they are all wrong in
	the same way: a HUD builds its labels in the first frame and fills them as
	answers arrive, so a watcher settles while the game is still starting.

	`CLAUDE.md` has asked for this line since it was written, and it was in two
	of thirty-nine games -- because it was a rule in a document rather than a
	line in this file. A convention the scaffold does not produce is a
	convention that does not exist.

	Anything you add below this line runs after the game has announced itself
	as ready, which is exactly the thing this prevents.
]]
Debug.ready(Config.name)
