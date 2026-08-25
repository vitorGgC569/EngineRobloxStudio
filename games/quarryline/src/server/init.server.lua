--!strict
--[[
	quarryline — a quarry tycoon, built to exercise the library.

	Why this game exists
	--------------------

	Two hundred and fourteen modules were mined out of the licensed projects
	and fifty of them had ever been used by a real game. By this project's own
	rule — code nobody exercises is not engine, it is inventory with an engine
	address — most of that library was unproven, which is exactly where the
	weapon system, the netcode and the IK all were on the day each of them
	broke the first time somebody ran it.

	So this is the third game, and its job is to *use things*. A tycoon was
	chosen because it consumes the widest set: plots, grids, permissions, an
	economy with big numbers and curves, an upgrade graph, offline earnings,
	rebirth, dailies, quests, achievements, crates, live events, and a save
	profile that has to survive all of it.

	The bootstrap is the point
	--------------------------

	This file is the first thing in the repository written against `Core.Boot`.
	Every system declares what it produces and what it needs; the graph is
	validated before anything runs, so a missing producer is a startup error
	rather than a race that appears on somebody else's machine.

	That matters here more than most places, because this session watched a
	server die exactly that way: a subscription called inline during bootstrap
	never returned, the world was built, and `CharacterAutoLoads` was never
	re-enabled. No error, no player, no clue.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
Forge.require("0.2.0")

local Net = Forge.Net
local Save = Forge.Save
local Debug = Forge.Debug
local Rng = Forge.Core.Rng
local Boot = Forge.Core.Boot
local Clock = Forge.Core.Clock
local Telemetry = Forge.Telemetry
local GlobalEffects = Forge.LiveOps.GlobalEffects
local Capability = Forge.Capability
local Reference = Forge.Reference
local Testing = Forge.Testing

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local startedAt = os.clock()
Rng.seed(Config.seed)

-- =============================== the boot graph =============================
--[[
	What depends on what, declared before anything starts.

	Read as a sentence: the plots have to exist before a line can run on one,
	and both have to exist before a player can be let in. `validate` refuses a
	cycle and names any milestone nothing produces.
]]
Boot.declareMany({
	ground_ready = { producedBy = "Ground", requires = {} },
	plots_ready = { producedBy = "Plots", requires = { "ground_ready" } },
	line_ready = { producedBy = "Line", requires = { "plots_ready" } },
	progress_ready = { producedBy = "Progress", requires = {} },
	economy_open = { producedBy = "bootstrap", requires = { "line_ready", "progress_ready" } },
})

local problems = Boot.validate()
if #problems > 0 then
	-- Loud and early. A graph with a hole is a game with a race in it, and the
	-- race will not be here when it fires.
	Debug.warn(string.format("boot graph has %d problem(s)", #problems))
end

-- ================================== channels ================================
Net.define({
	--: The client asks; the server decides. Every one of these is re-checked
	--: server-side, because a rate limit is not a permission.
	ClaimPlot = { dir = "c2s", rate = 2 },
	Build = { dir = "c2s", rate = 8 },
	BuyUpgrade = { dir = "c2s", rate = 6 },
	Rebirth = { dir = "c2s", rate = 1 },
	ClaimDaily = { dir = "c2s", rate = 2 },

	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	LineSync = { dir = "s2c" },
})

Content.load()

--[[
	The balance, held against the engine's two manuals.

	`Reference` for rates, `Economy.Audit` for the curve. Both warn and neither
	blocks: a table that disagrees with the manual is sometimes the design and
	sometimes a typo, and only a person can tell those apart.
]]
do
	local notes = Content.review()
	for _, note in notes do
		Debug.warn(string.format("balance: %s %s — %s", note.kind, note.id, note.note))
	end
	Debug.probe("balance", function()
		return { notes = notes, frame = Reference.frame }
	end)
end

Save.configure({
	store = Config.saveStore,
	version = 2,
	template = require(script.systems.Progress).template(),
})
Save.start()

-- ================================== systems =================================
local Systems = script:WaitForChild("systems")
local Ground = require(Systems.Ground)
local Plots = require(Systems.Plots)
local Line = require(Systems.Line)
local Progress = require(Systems.Progress)
local Meta = require(Systems.Meta)

-- Ground first: the plots sit on it, and `World.surface` has nothing to
-- measure against until the terrain is written.
Ground.start()
Plots.start()
Line.start()
Progress.start()
Meta.start()

--[[
	Everything the economy needs is up.

	Signalled here rather than by any one system, because it is the *join* of
	them and no single system owns a join.
]]
Boot.signal("economy_open")

-- ================================ the tick ==================================
--[[
	One loop for the whole server, not one per plot.

	Six plots on six coroutines is six schedulers doing the same arithmetic at
	slightly different moments, and the drift shows up as plots that pay at
	visibly different times. One loop, every plot, same instant.
]]
task.spawn(function()
	Boot.await("economy_open", 60)
	while true do
		task.wait(Config.tickSeconds)
		for _, player in Players:GetPlayers() do
			local profile = Save.get(player)
			local plotId = Plots.plotOf(player)
			if not profile or not plotId then
				continue
			end

			local coins = Line.tick(plotId, profile)
			if coins > 0 then
				-- Multiplied by their lives here rather than inside the
				-- pipeline, because rebirth is a property of the player and
				-- the pipeline is a property of the plot.
				coins = math.floor(coins * Progress.rebirthBonus(profile))
				Progress.credit(player, profile, coins, "line")
				profile.incomePerSecond = coins / Config.tickSeconds
				Net.fire(player, "LineSync", {
					coins = profile.coins,
					perTick = coins,
					explain = Line.explain(plotId),
				})
			end
		end
	end
end)

-- ================================== players =================================
--[[
	Everything that needs a loaded profile.

	Driven by `Save.observe`, not by `PlayerAdded`. The two are not the same
	moment: in Studio the local player joins at server start, so their profile
	may already have loaded before this line runs, and a plain `Connect` would
	miss it and leave them with no plot for ever. `observe` fires for anybody
	already loaded and then keeps listening.

	`Save.load` does not exist, which the compiler was happy about and reading
	the module was not — the profile arrives, it is never fetched.
]]
local function attach(player: Player, profile: any)
	Progress.payOffline(player, profile)

	local plotId, refusal = Plots.claim(player)
	if not plotId then
		Net.fire(player, "Notify", { text = refusal or "no plot available" })
	else
		Line.attach(plotId)
		Progress.tutorial:begin(tostring(player.UserId), profile.tutorialDone == true)
	end

	Net.fire(player, "StateSync", profile)
end

Save.observe(attach)

Players.PlayerRemoving:Connect(function(player)
	local profile = Save.get(player)
	if profile then
		profile.lastSeen = Clock.now()
	end
	local plotId = Plots.plotOf(player)
	if plotId then
		Line.detach(plotId)
	end
	Plots.release(player)
end)

-- ================================= requests =================================
Net.on("ClaimPlot", function(player)
	local plotId, refusal = Plots.claim(player)
	Net.fire(player, "Notify", {
		text = plotId and string.format("You have %s", plotId) or (refusal or "no"),
	})
end)

Net.on("Build", function(player, payload)
	if typeof(payload) ~= "table" then
		return
	end
	local profile = Save.get(player)
	local plotId = Plots.plotOf(player)
	if not profile or not plotId then
		return
	end

	local machineId = tostring(payload.machine)
	local machine = Content.machines[machineId]
	if not machine then
		return
	end

	-- Capacity before money: a player told "you cannot afford that" who then
	-- earns it and is told "the plot is full" has been lied to twice.
	local room, why = Line.mayBuild(plotId, profile.life or 0, profile.premium)
	if not room then
		Net.fire(player, "Notify", { text = why })
		return
	end
	if profile.coins < machine.price then
		Net.fire(player, "Notify", {
			text = string.format("%s costs %d", machine.label, machine.price),
		})
		return
	end

	local placed, refusal = Plots.place(player, machineId,
		tonumber(payload.x) or 0, tonumber(payload.z) or 0, tonumber(payload.rotation))
	if not placed then
		Net.fire(player, "Notify", { text = refusal })
		return
	end

	profile.coins -= machine.price
	profile.machinesBuilt = (profile.machinesBuilt or 0) + 1
	Line.record(plotId, machineId)
	Progress.tutorial:completeStep(tostring(player.UserId))
	Telemetry.event("build", { machine = machineId })
	Net.fire(player, "StateSync", profile)
end)

Net.on("BuyUpgrade", function(player, payload)
	local profile = Save.get(player)
	if not profile or typeof(payload) ~= "table" then
		return
	end
	local ok, refusal = Progress.buyUpgrade(player, profile, tostring(payload.id))
	Net.fire(player, "Notify", { text = ok and "Upgraded" or refusal })
	Net.fire(player, "StateSync", profile)
end)

Net.on("Rebirth", function(player)
	local profile = Save.get(player)
	if not profile then
		return
	end
	local ok, refusal = Progress.doRebirth(player, profile)
	if ok then
		local plotId = Plots.plotOf(player)
		if plotId then
			Plots.clear(plotId)
		end
	end
	Net.fire(player, "Notify", { text = ok and "Reborn" or refusal })
	Net.fire(player, "StateSync", profile)
end)

Net.on("ClaimDaily", function(player)
	local profile = Save.get(player)
	if not profile then
		return
	end
	local result, refusal = Progress.claimDaily(player, profile)
	Net.fire(player, "Notify", {
		text = result and "Daily claimed" or refusal,
	})
	Net.fire(player, "StateSync", profile)
end)

-- ================================== the seam ================================
Debug.expose()

Debug.probe("session", function()
	return {
		uptime = math.floor(os.clock() - startedAt),
		players = #Players:GetPlayers(),
		ground = Ground.describe(),
		plots = Plots.describe(),
		line = Line.describe(),
		progress = Progress.describe(),
		boot = Boot.describe(),
		clock = Clock.describe(),
		effects = GlobalEffects.describe(),
		--: What this Roblox build refused. Turns "the material never appeared"
		--: from a mystery into a line in the snapshot.
		unavailable = Capability.missing(),
	}
end)

--[[
	The live suite, last.

	These scenarios assert against systems that must already be running, and a
	suite that starts before the game does tests a game that does not exist.
]]
if Config.selfTest then
	task.defer(function()
		Boot.await("economy_open", 90)
		-- The folder, not a name: `runAndPublish` requires each child and
		-- calls it with the Testing surface, so it wants the container.
		Testing.runAndPublish(script:FindFirstChild("tests"))
	end)
end

Debug.info(string.format("%s up in %.2fs", Config.name, os.clock() - startedAt))
print(string.format("[%s] server ready in %.2fs (seed %d)",
	Config.name, os.clock() - startedAt, Config.seed))
