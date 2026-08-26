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
local Channels = require(Shared:WaitForChild("Channels"))
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
Channels.define(Net)

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

--[[
	Nobody spawns into a world that is still being built.

	Writing the terrain and laying six plots takes a couple of seconds, and
	Roblox does not wait: the character loads on join, falls through a place
	with no floor and no `SpawnLocation` yet, and lands on whatever part
	happens to exist by then. The first screenshot of this game showed exactly
	that -- a player standing on top of a claim marker, several plots away from
	the spawn pad that was created a moment after they landed.

	So the gate goes up before the first system runs and comes down after the
	last one. `pcall` around the build is not defensive dressing: this file's
	own header records a server that died with the gate still up and no player
	ever spawning, which produced no error and no clue. A build that throws must
	still let people in to see the broken world.
]]
Players.CharacterAutoLoads = false

local built, buildError = pcall(function()
	-- Ground first: the plots sit on it, and `World.surface` has nothing to
	-- measure against until the terrain is written.
	Ground.start()
	Plots.start()
	Line.start()
	Progress.start()
	Meta.start()
end)

Players.CharacterAutoLoads = true
for _, player in Players:GetPlayers() do
	if not player.Character then
		player:LoadCharacter()
	end
end

if not built then
	Debug.error(string.format("world build failed: %s", tostring(buildError)))
	error(buildError, 0)
end

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
				if coins > 0 then
					Net.fireAll("Sold", { plot = plotId, amount = coins })
				end
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

		--[[
			A saved factory is rebuilt; a first arrival is given one.

			The order matters and the old version had only the second half. It
			gated the starter line on `machinesBuilt == 0` -- correct on its own
			-- but nothing ever restored a layout, so a returning player whose
			counter was four came back to an empty plot and could never be given
			another line. They kept their coins and lost their factory.
		]]
		local saved = profile.layout
		if typeof(saved) == "table" and #saved > 0 then
			local back, lost = Plots.restore(plotId, saved)
			profile.layout = Plots.snapshot(plotId)
			Net.fire(player, "Notify", {
				text = lost > 0
					and string.format("Restored %d machines (%d no longer fit)", back, lost)
					or string.format("Welcome back -- %d machines running", back),
			})
		--[[
			An empty plot gets a line, whatever the counter says.

			The gate used to be `machinesBuilt == 0`, and that is the wrong
			question twice over. It asks how many machines this player has ever
			built, when what matters is whether they have a factory now -- and
			it strands every profile saved before layouts were persisted, whose
			counter is four and whose plot is bare.

			Asking the plot instead is both the migration and the correct rule.
		]]
		elseif next(Plots.built[plotId] or {}) == nil then
			local given = Plots.grantStarterLine(plotId)
			if given > 0 then
				profile.machinesBuilt = given
				profile.layout = Plots.snapshot(plotId)
				Net.fire(player, "Notify", {
					text = string.format("Your first line is running (%d machines)", given),
				})
			end
		end
	end

	Progress.publishStats(player, profile)
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

--[[
	Every refusal says why, including the ones that used to say nothing.

	This had three silent `return`s at the top -- a malformed payload, a missing
	profile or plot, and an unknown machine -- and Build is the player's main
	action. Pressing it and receiving *nothing* is indistinguishable from a
	broken button, and it hid a real fault for an entire debugging session:
	firing Build from a live client did nothing at all, and no message existed
	anywhere to say which of the three checks had turned it away.

	A refusal a player cannot see is a refusal the developer cannot see either.
]]
Net.on("Build", function(player, payload)
	if typeof(payload) ~= "table" then
		Net.fire(player, "Notify", { text = "that build request was malformed" })
		return
	end
	local profile = Save.get(player)
	local plotId = Plots.plotOf(player)
	if not profile then
		Net.fire(player, "Notify", { text = "your save is still loading" })
		return
	end
	if not plotId then
		Net.fire(player, "Notify", { text = "claim a plot before building" })
		return
	end

	local machineId = tostring(payload.machine)
	local machine = Content.machines[machineId]
	if not machine then
		Net.fire(player, "Notify", {
			text = string.format("there is no machine called '%s'", machineId),
		})
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

	local placed, refusal, model = Plots.place(player, machineId,
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

	--[[
		Broadcast the spot, so everyone nearby sees it land.

		`Plots.place` hands back the model as a third value, so this reports
		where the machine actually went rather than where the client asked for
		-- the two differ whenever the grid snaps to the next free cell, which
		is most of the time.
	]]
	--: The layout is what a profile has to carry: a counter tells you how many
	--: things were ever built, and rebuilds nothing.
	profile.layout = Plots.snapshot(plotId)

	if model then
		Net.fireAll("Built", { at = model:GetPivot().Position })
	end
end)

Net.on("ClientReady", function(player, payload)
	if typeof(payload) ~= "table" then
		return
	end
	local adopted = tonumber(payload.adopted) or -1
	local tagged = tonumber(payload.tagged) or -1
	Debug.info(string.format("[client] %s bound %d of %d tagged machines",
		player.Name, adopted, tagged))

	--[[
		Recorded on the player, not only in the log.

		A log line needs somebody watching the console at the right moment; an
		attribute can be read at any time, by a tool, from outside the game.
		That is the difference between a diagnostic and a hope.
	]]
	player:SetAttribute("boundMachines", adopted)
	player:SetAttribute("taggedMachines", tagged)
end)

Net.on("BuyUpgrade", function(player, payload)
	local profile = Save.get(player)
	if not profile or typeof(payload) ~= "table" then
		--: Silent for the same reason Build was, and wrong for the same reason.
		Net.fire(player, "Notify", { text = "that upgrade request was malformed" })
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
