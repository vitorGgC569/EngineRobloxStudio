--!strict
--[[
	Meta — the parts of a live game that are not the game.

	Config that can be changed while people are playing, an experiment, a
	product that can be bought, and an ability with a cost. Four engine modules
	that had never been executed by anything now have exactly one caller each,
	which is the difference between an engine and a folder of plausible code.

	Every number below is a decision about Proving Ground and belongs here
	rather than in the engine. What `LiveOps` supplies is the ability to change
	them without a release; what this file supplies is which ones are worth
	changing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local LiveOps = Forge.LiveOps
local Monetization = Forge.Monetization
local Ability = Forge.Ability
local Combat = Forge.Combat
local Feel = Forge.Feel
local Net = Forge.Net
local Save = Forge.Save
local Telemetry = Forge.Telemetry
local Debug = Forge.Debug

local Meta = {}

-- ================================= config ===================================
--[[
	The knobs worth turning without a release.

	Chosen by asking "if this were wrong at 2am, would I want to wait for a
	build?" Enemy pressure and score rates qualify. Nothing structural does:
	a config key that changes the shape of the game is a release pretending to
	be a setting.
]]
local function defineConfig()
	LiveOps.defineMany({
		["fight.maxEnemies"] = 14,
		["fight.spawnInterval"] = 2,
		["range.targetScore"] = 15,
		["range.bullseyeBonus"] = 2.0,
		["move.sprintDrain"] = 18,
		["flag.rangedWeapons"] = true,
		["flag.targetsRespawn"] = true,
	})

	--[[
		One experiment, and a real one.

		A first session that opens with four enemies instead of eight is a
		genuine question about whether Proving Ground is too hostile to
		newcomers, and the answer changes what the game should ship as. Arms are
		assigned by a hash of the user id, so a player sees the same opening
		every time they return.
	]]
	LiveOps.experiment("openingPressure", { "control", "gentle" }, {
		weights = { 1, 1 },
	})

	LiveOps.strings("en-us", {
		["hud.outOfBreath"] = "out of breath",
		["hud.targetDown"] = "target",
		["notify.welcome"] = "Proving Ground. LMB strikes, Q dodges, RMB blocks, F shoots.",
		["notify.death"] = "You fell. Score reset.",
	})
	LiveOps.strings("pt-br", {
		["hud.outOfBreath"] = "sem folego",
		["hud.targetDown"] = "alvo",
		["notify.welcome"] = "Proving Ground. LMB golpeia, Q esquiva, RMB bloqueia, F atira.",
		["notify.death"] = "Voce caiu. Pontuacao zerada.",
	})
end

-- =============================== monetisation ===============================
--[[
	One product and one pass, both cosmetic-adjacent on purpose.

	A second wind refills health once; it does not make the player stronger,
	so buying it cannot make the arena easier to beat than earning it. The pass
	doubles score, which is a leaderboard decision rather than a combat one.

	The grant functions are the whole risk surface of this file. They run inside
	`Monetization`'s idempotent transaction, so a Roblox retry cannot pay twice
	— and there is now a live scenario asserting exactly that.
]]
local function defineProducts()
	Monetization.defineProduct("SecondWind", {
		productId = 0, -- set to a real product id before publishing
		grant = function(player: Player)
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = humanoid.MaxHealth
			end
			Telemetry.event("product.granted", { product = "SecondWind" })
		end,
	})

	Monetization.definePass("DoubleScore", {
		passId = 0, -- set to a real pass id before publishing
	})
end

function Meta.scoreMultiplier(player: Player): number
	return Monetization.owns(player, "DoubleScore") and 2 or 1
end

-- ================================ abilities =================================
--[[
	Second wind, as an ability rather than a purchase.

	The same effect, earned: a long cooldown and a stamina cost. Having both
	paths is deliberate — it is the honest version of selling a consumable, and
	it means the product cannot be the only way to get the effect.
]]
local function defineAbilities()
	Ability.define("secondWind", {
		name = "Second Wind",
		cooldown = 90,
		cost = { stamina = 40 },
		cast = 0.6,
		use = function(ctx)
			local player = ctx.subject
			if typeof(player) ~= "Instance" or not player:IsA("Player") then
				return false
			end
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not humanoid then
				return false
			end
			local healed = Combat.heal(character, humanoid.MaxHealth * 0.5, player)
			Net.fireNear(character:GetPivot().Position, 90, "Notify", {
				text = string.format("second wind  (+%d)", math.floor(healed)),
			})
			Telemetry.event("ability.used", { ability = "secondWind" })
			return true
		end,
	})
end

-- ================================== start ===================================
function Meta.start()
	defineConfig()
	defineProducts()
	defineAbilities()
	--[[
		Where events go, and what makes them go there.

		Two calls, and the difference between them cost this game every event
		it ever raised. `dataStoreSink` chooses the destination; `start` is
		what drains the buffer into it — without it there is no periodic
		flush, no session events, no error capture and no shutdown flush, and
		the buffer only empties once it reaches a hundred entries, which a
		short session never does.

		Found by `forge analytics`, on its first run, by asking Roblox which
		datastores this universe has and being told `ForgeAnalytics` is not one
		of them. The writing side was correct, tested and green, and had
		delivered nothing. That is the whole argument for a read path.
	]]
	Telemetry.dataStoreSink()
	Telemetry.start()

	--[[
		Start the pump, not just the destination.

		This line was missing, and the failure was invisible from inside the
		game: the sink was registered, every `Telemetry.event` was counted, and
		`Telemetry.describe()` reported a healthy sink with a full buffer. What
		it did not report was that nothing drains the buffer until either it
		reaches a hundred entries or `Telemetry.start` installs the periodic
		flush — and nobody had called it.

		Found by `forge analytics`, on its first run, by asking Roblox which
		datastores this universe has and being told `ForgeAnalytics` is not one
		of them. That is the entire argument for reading telemetry back: the
		writing side was correct, tested and green, and produced nothing.
	]]
	Telemetry.start()

	LiveOps.start()
	Monetization.start()

	--[[
		Send a player the text in their own language.

		`LocaleId` is per player, so the same server hands two people different
		strings for the same event. Doing this at the point of sending, rather
		than by shipping a translated client, means a wrong string is fixed in
		config rather than in a release.
	]]
	Players.PlayerAdded:Connect(function(player)
		local arm = LiveOps.bucket(player, "openingPressure")
		if arm then
			player:SetAttribute("Experiment_openingPressure", arm)
			Telemetry.event("experiment.assigned", {
				experiment = "openingPressure",
				arm = arm,
			})
		end
	end)

	Debug.probe("meta", function()
		local arms: { [string]: number } = {}
		for _, player in Players:GetPlayers() do
			local arm = player:GetAttribute("Experiment_openingPressure")
			if typeof(arm) == "string" then
				arms[arm] = (arms[arm] or 0) + 1
			end
		end
		return {
			config = LiveOps.describe(),
			monetization = Monetization.describe(),
			abilities = Ability.ids(),
			arms = arms,
		}
	end)

	Debug.info("meta ready (config, products, abilities)")
end

return Meta
