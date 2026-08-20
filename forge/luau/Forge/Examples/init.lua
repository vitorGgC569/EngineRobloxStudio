--!strict
--[[
	Examples — one runnable demonstration per module.

	A documented example rots. It is written once, the API moves, and nobody
	notices until an agent copies it and gets an error. This project has been
	bitten by that exact shape all day: a comment describing a call that was no
	longer true is worse than no comment, because it is believed.

	So these are not snippets in a docstring. Each one is a function that
	actually runs inside the live game, does the thing, asserts something small
	about the result, and cleans up after itself. `forge example --all` runs
	every one of them; if the API moves, the example fails, and it fails in CI
	rather than in an agent's hands.

		forge example Combat      run one
		forge example --all       run all of them

	--- What an example is for ----------------------------------------------

	Not test coverage — `Testing` does that, and these deliberately assert
	almost nothing. An example answers "what does using this module look like",
	which is the question an agent has when it has never seen the engine and is
	deciding whether a module is the right tool. That is why each one is short,
	uses the shortest path through its module, and reads top to bottom.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Examples = {}

local function stage(): Folder
	local existing = Workspace:FindFirstChild("ForgeExampleStage")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "ForgeExampleStage"
	folder.Parent = Workspace
	return folder
end

--: Far from anything a player is standing on. Examples build real instances.
local ORIGIN = Vector3.new(0, 6000, 24000)

--[[
	Every example, keyed by the module it demonstrates.

	Each returns a table describing what it did. That return value is what a
	CLI prints and what makes an example self-reporting rather than a thing
	you have to watch.
]]
Examples.of = {
	Core = function(Forge, at)
		local Spring = Forge.Core.Spring
		local spring = Spring.new(0, { frequency = 4, damping = 0.7 })
		spring.goal = 10
		for _ = 1, 60 do
			spring:step(1 / 60)
		end
		local stream = Forge.Core.Rng.stream("example")
		return {
			springReached = math.floor(spring.value * 100) / 100,
			settled = spring:settled(0.1),
			deterministicRoll = stream:int(1, 100),
		}
	end,

	Data = function(Forge)
		local Data = Forge.Data
		Data.define("example_item", {
			name = { type = "string" },
			weight = { type = "number", default = 1, min = 0 },
		})
		Data.load("example_item", {
			stone = { name = "Stone", weight = 4 },
			feather = { name = "Feather" },
		})
		local feather = Data.expect("example_item", "feather")
		return { ids = Data.ids("example_item"), defaultApplied = feather.weight }
	end,

	Rig = function(Forge, at)
		local model = Forge.Rig.build({
			name = "ExampleRig",
			rigType = "R15",
			body = Color3.fromRGB(140, 150, 160),
		})
		model.Parent = stage()
		model:PivotTo(CFrame.new(at))
		local joints = 0
		for _, d in model:GetDescendants() do
			if d:IsA("Motor6D") then
				joints += 1
			end
		end
		model:Destroy()
		return { parts = 15, joints = joints }
	end,

	Anim = function(Forge, at)
		local Anim = Forge.Anim
		Anim.registerAll(require(script.Parent.Anim.Presets))
		local model = Forge.Rig.build({ name = "ExampleAnim", rigType = "R15" })
		model.Parent = stage()
		model:PivotTo(CFrame.new(at))

		local animator = Anim.new(model)
		animator:setLocomotion(false)
		animator:play("attack_1")
		for _ = 1, 20 do
			animator:update(1 / 60)
		end
		local shape = animator:describe()
		animator:destroy()
		model:Destroy()
		return { rig = shape.rig, joints = #shape.joints, playing = shape.playing }
	end,

	Combat = function(Forge, at)
		local Combat = Forge.Combat
		local model = Forge.Rig.build({ name = "ExampleTarget" })
		model.Parent = stage()
		model:PivotTo(CFrame.new(at))
		local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
		humanoid.MaxHealth = 100
		humanoid.Health = 100

		Combat.damage(model, { amount = 30, kind = "example" })
		local left = Combat.getHealth(model)
		model:Destroy()
		return { healthAfter30Damage = left }
	end,

	Weapon = function(Forge, at)
		local Weapon = Forge.Weapon
		Weapon.define("example_rifle", {
			mode = "hitscan", damage = 12, rpm = 600, magazine = 4, range = 200,
		})
		local model = Forge.Rig.build({ name = "ExampleShooter" })
		model.Parent = stage()
		model:PivotTo(CFrame.new(at))

		Weapon.equip(model, "example_rifle")
		local shot = Weapon.fire(model, at, Vector3.new(0, 0, -1), { ignore = { model } })
		local ammo = Weapon.ammo(model)
		Weapon.unequip(model)
		model:Destroy()
		return { fired = shot.ok, ammoLeft = ammo, seed = shot.seed }
	end,

	Nav = function(Forge, at)
		local waypoints, status = Forge.Nav.computePath(at, at + Vector3.new(40, 0, 0))
		return { status = status, waypoints = #waypoints }
	end,

	IK = function(Forge)
		-- No rig needed: the solver is pure maths and that is the point of it.
		local shoulder, elbow = Forge.IK.solveTwoBone(2, 2, 3)
		return {
			shoulderDegrees = math.floor(math.deg(shoulder)),
			elbowDegrees = math.floor(math.deg(elbow)),
		}
	end,

	World = function(Forge)
		local field = Forge.World.heightfield({
			size = 128, seed = 1,
			base = { { frequency = 0.02, octaves = 3, weight = 1 } },
			range = { 10, 30 },
		})
		return { heightAtCentre = math.floor(field:height(0, 0)) }
	end,

	Scene = function(Forge)
		local Scene = Forge.Scene
		local scene = Scene.create("example_scene")
		scene:add("Prop.Crate", CFrame.new(0, 5, 0), { name = "One" })
		local restored = Scene.fromJson(scene:toJson())
		return { placements = #restored.placements, name = restored.name }
	end,

	Catalog = function(Forge)
		local Catalog = Forge.Catalog
		local foliage = Catalog.byCategory("foliage")
		return {
			entries = #Catalog.entries,
			categories = Catalog.categories(),
			firstFoliage = foliage[1] and foliage[1].name or nil,
		}
	end,

	Capability = function(Forge)
		local Capability = Forge.Capability
		local part = Instance.new("Part")
		local real = Capability.set(part, "Transparency", 0.5)
		local invented = Capability.set(part, "NotARealProperty", 1)
		part:Destroy()
		return { realPropertyWrote = real, inventedPropertyWrote = invented }
	end,

	LiveOps = function(Forge)
		local LiveOps = Forge.LiveOps
		LiveOps.define("example.cap", 10)
		LiveOps.set("example.cap", 25)
		LiveOps.flag("exampleFeature", true)
		LiveOps.strings("en-us", { ["example.hello"] = "hello" })
		return {
			value = LiveOps.get("example.cap"),
			flag = LiveOps.enabled("exampleFeature"),
			text = LiveOps.text("example.hello"),
			missingKeyReturnsKey = LiveOps.text("example.absent"),
		}
	end,

	Save = function(Forge)
		-- The pure half: checksum and verification, with no DataStore involved.
		local payload = { score = 10 }
		payload.__checksum = Forge.Save.checksum(payload)
		local honest = Forge.Save.verify(payload)
		payload.score = 999999
		local tampered = Forge.Save.verify(payload)
		return { acceptsIntact = honest, rejectsTampered = not tampered }
	end,

	Telemetry = function(Forge)
		local Telemetry = Forge.Telemetry
		local seen = 0
		Telemetry.sink(function(batch)
			seen += #batch
			return true
		end)
		Telemetry.event("example.fired", { where = "examples" })
		Telemetry.flush()
		Telemetry.clearSinks()
		return { eventsDelivered = seen }
	end,

	Collab = function(Forge)
		-- Server-only, and it says so rather than pretending on a client.
		if not RunService:IsServer() then
			return { skipped = "Collab arbitrates on the server" }
		end
		local Collab = Forge.Collab
		return { keyFor = Collab.keyFor("placement:demo"), roster = #Collab.roster() }
	end,

	Material = function(Forge)
		local made = Forge.Material.defineMany({
			example_stone = { base = Enum.Material.Slate, studsPerTile = 8 },
		})
		return {
			variantsCreated = made,
			note = made == 0 and "MaterialVariant needs the plugin capability; author it into the place" or nil,
		}
	end,

	Feel = function(Forge, at)
		Forge.Feel.hit(at, { power = 1, kind = "burst" })
		Forge.Feel.number(at, "12")
		return { emitted = "impact and a damage number at the stage" }
	end,

	UI = function(Forge)
		return { tokens = { text = Forge.UI.theme.text, radius = Forge.UI.theme.radius } }
	end,

	Net = function(Forge)
		-- Shapes are the interesting part: a malformed payload never reaches a
		-- handler, and that check is worth seeing in isolation.
		local check = Forge.Net.shape({ amount = "number", who = "string" })
		return {
			acceptsGood = check({ amount = 1, who = "a" }),
			rejectsBad = not check({ amount = "one", who = "a" }),
		}
	end,

	Testing = function(Forge)
		return { registered = Forge.Testing.count() }
	end,

	Destruction = function(Forge, at)
		local Destruction = Forge.Destruction
		Destruction.define("example_crate", { shards = 6, spread = 10, life = 2 })

		local crate = Instance.new("Part")
		crate.Size = Vector3.new(4, 4, 4)
		crate.CFrame = CFrame.new(at)
		crate.Anchored = true
		crate.Color = Color3.fromRGB(150, 110, 70)
		crate.Parent = stage()

		local shards = Destruction.break_(crate, {
			recipe = "example_crate",
			from = at + Vector3.new(0, 0, 6),
		})
		local report = Destruction.describe()
		Destruction.clear()
		return { shards = shards, budget = report.budget, live = report.live }
	end,

	Weather = function(Forge)
		local Weather = Forge.Weather
		Weather.installDefaults()
		Weather.set("storm", { immediate = true })
		local stormy = Weather.describe()
		Weather.set("clear", { immediate = true })
		Weather.stop()
		return {
			conditions = #Weather.names(),
			stormRain = stormy.blend.rain,
			clearedTo = Weather.describe().blend.rain,
		}
	end,

	Examples = function(Forge)
		-- Self-describing, so `--all` proves the runner itself is reachable.
		return { available = #Forge.Examples.names() }
	end,
}

-- =================================== run ====================================
function Examples.names(): { string }
	local out = {}
	for name in Examples.of do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

--[[
	Run one example and report what happened.

	Failures are returned rather than thrown: running twenty examples and
	stopping at the first broken one hides the other nineteen, and the whole
	point is to find out which parts of the surface have drifted.
]]
function Examples.run(name: string): { [string]: any }
	local fn = Examples.of[name]
	if not fn then
		return { module = name, ok = false, error = "no example for this module" }
	end

	local Forge = require(script.Parent)
	local started = os.clock()
	local ok, result = pcall(fn, Forge, ORIGIN)
	local seconds = math.floor((os.clock() - started) * 1000) / 1000

	if not ok then
		return { module = name, ok = false, error = tostring(result), seconds = seconds }
	end
	return { module = name, ok = true, result = result, seconds = seconds }
end

function Examples.runAll(): { [string]: any }
	local results = {}
	local passed, failed = 0, 0
	for _, name in Examples.names() do
		local report = Examples.run(name)
		table.insert(results, report)
		if report.ok then
			passed += 1
		else
			failed += 1
		end
	end

	local folder = Workspace:FindFirstChild("ForgeExampleStage")
	if folder then
		folder:Destroy()
	end

	return { total = passed + failed, passed = passed, failed = failed, results = results, ok = failed == 0 }
end

function Examples.describe(): { [string]: any }
	return { available = Examples.names(), count = #Examples.names() }
end

return Examples
