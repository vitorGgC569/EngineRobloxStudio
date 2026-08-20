--!strict
--[[
	Lanternreach — content.

	Everything this game *is* lives in this file: what can be found, what it is
	worth, what the Keeper asks for, and what she says. The systems below only
	move it around.

	Note what is absent. There is no combat, no enemy, no damage. The engine
	does not require any, which is the point of the exercise: Proving Ground and
	Lanternreach share every line of Forge and not one line of each other.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Assets = Forge.Assets
local Inventory = Forge.Inventory
local Quest = Forge.Quest
local Dialogue = Forge.Dialogue
local Progression = Forge.Progression
local Rig = Forge.Rig

local Content = {}

-- ================================== items ===================================
local ITEMS = {
	kelp_glass = { stack = 20, value = 6, label = "Kelp Glass", tint = Color3.fromRGB(120, 200, 170) },
	brass_fitting = { stack = 20, value = 14, label = "Brass Fitting", tint = Color3.fromRGB(214, 168, 88) },
	sealed_tin = { stack = 10, value = 26, label = "Sealed Tin", tint = Color3.fromRGB(178, 186, 196) },
	charts = { stack = 5, value = 48, label = "Water-Stained Charts", tint = Color3.fromRGB(226, 210, 170) },
	lamp_oil = { stack = 10, value = 18, label = "Lamp Oil", tint = Color3.fromRGB(255, 190, 110) },
	drowned_bell = { stack = 1, value = 180, label = "Drowned Bell", tint = Color3.fromRGB(198, 214, 220) },
}

-- ============================== cache tables ================================
-- What each kind of wreck can hold. Weighted, so a hull yields differently
-- from a crate without either being special-cased anywhere in code.
Content.caches = {
	crate = {
		label = "Waterlogged Crate",
		rolls = { 1, 2 },
		table_ = {
			{ item = "kelp_glass", weight = 40, count = { 1, 3 } },
			{ item = "brass_fitting", weight = 26, count = { 1, 2 } },
			{ item = "lamp_oil", weight = 20, count = { 1, 1 } },
			{ item = "sealed_tin", weight = 14, count = { 1, 1 } },
		},
	},
	hull = {
		label = "Broken Hull",
		rolls = { 2, 3 },
		table_ = {
			{ item = "brass_fitting", weight = 34, count = { 1, 3 } },
			{ item = "sealed_tin", weight = 28, count = { 1, 2 } },
			{ item = "charts", weight = 22, count = { 1, 1 } },
			{ item = "kelp_glass", weight = 16, count = { 2, 4 } },
		},
	},
	deep = {
		label = "Something Under the Silt",
		rolls = { 1, 2 },
		table_ = {
			{ item = "charts", weight = 40, count = { 1, 2 } },
			{ item = "sealed_tin", weight = 30, count = { 2, 3 } },
			{ item = "drowned_bell", weight = 8, count = { 1, 1 } },
			{ item = "lamp_oil", weight = 22, count = { 2, 3 } },
		},
	},
}

function Content.load()
	-- items ------------------------------------------------------------------
	local defs = {}
	for id, item in ITEMS do
		defs[id] = { stack = item.stack, value = item.value, label = item.label, tint = item.tint }
	end
	Inventory.defineItems(defs)

	-- assets -----------------------------------------------------------------
	-- One producer teaches Forge how to build every salvage cache. Adding a
	-- fourth kind is a table entry, not code.
	Assets.producer("Salvage", function(_id, definition)
		local model = Instance.new("Model")
		model.Name = definition.label

		local base = Instance.new("Part")
		base.Size = definition.size
		base.Color = definition.color
		base.Material = definition.material
		base.Anchored = true
		base.TopSurface = Enum.SurfaceType.Smooth
		base.BottomSurface = Enum.SurfaceType.Smooth
		base.Parent = model
		model.PrimaryPart = base

		-- A faint glow is the whole discoverability design: at night the player
		-- navigates by these and nothing else.
		local glow = Instance.new("PointLight")
		glow.Color = definition.glow
		glow.Range = 26
		glow.Brightness = 1.1
		glow.Parent = base

		for i = 1, (definition.debris or 0) do
			local shard = Instance.new("Part")
			shard.Size = Vector3.new(0.6, 0.4, 1.8) * (0.7 + i * 0.15)
			shard.Color = definition.color:Lerp(Color3.new(0, 0, 0), 0.25)
			shard.Material = definition.material
			shard.Anchored = true
			shard.CFrame = base.CFrame
				* CFrame.new(math.cos(i * 2.3) * 3, -definition.size.Y / 2 + 0.2, math.sin(i * 2.3) * 3)
				* CFrame.Angles(0, i * 1.1, math.rad(8))
			shard.Parent = model
		end

		model:SetAttribute("ForgeAsset", _id)
		return model
	end)

	Assets.registerMany("Salvage", {
		Crate = {
			label = "Waterlogged Crate", kind = "crate",
			size = Vector3.new(3.4, 2.6, 3.4),
			color = Color3.fromRGB(96, 78, 58), material = Enum.Material.WoodPlanks,
			glow = Color3.fromRGB(150, 220, 190), debris = 2,
		},
		Hull = {
			label = "Broken Hull", kind = "hull",
			size = Vector3.new(9, 3.4, 4.2),
			color = Color3.fromRGB(78, 68, 60), material = Enum.Material.Wood,
			glow = Color3.fromRGB(200, 170, 110), debris = 4,
		},
		Deep = {
			label = "Something Under the Silt", kind = "deep",
			size = Vector3.new(4.2, 1.6, 4.2),
			color = Color3.fromRGB(58, 66, 70), material = Enum.Material.Slate,
			glow = Color3.fromRGB(140, 200, 255), debris = 3,
		},
	})

	Assets.producer("Npc", function(_id, definition)
		local model = Rig.build({
			name = definition.name,
			scale = definition.scale or 1,
			shape = "biped",
			body = definition.body,
			accent = definition.accent,
			glow = definition.glow,
		})
		model:SetAttribute("ForgeAsset", _id)
		return model
	end)

	Assets.register("Npc.Keeper", {
		name = "The Keeper",
		body = Color3.fromRGB(64, 72, 92),
		accent = Color3.fromRGB(238, 202, 128),
		glow = true,
	})

	-- progression ------------------------------------------------------------
	Progression.define("reach", {
		maxLevel = 12,
		curve = function(level)
			return math.floor(120 * level ^ 1.4 + 60 * level)
		end,
		perLevel = { satchel = 4 },
		unlocks = {
			[2] = { "cache.hull" },
			[5] = { "cache.deep" },
			[8] = { "light.far" },
		},
	})

	-- quests -----------------------------------------------------------------
	-- Objectives are event filters. "Bring me glass" and "open six crates" are
	-- the same mechanism with different data.
	Quest.defineMany({
		q_first_light = {
			name = "First Light",
			summary = "The Keeper wants to know the shelf still gives.",
			giver = "keeper",
			objectives = {
				{ id = "open", label = "Open salvage caches", count = 3, event = "salvage.opened" },
			},
			rewards = { xp = 140, currency = { coin = 40 } },
		},
		q_glasswork = {
			name = "Glasswork",
			summary = "Kelp glass, enough to reline a lamp.",
			giver = "keeper",
			requires = { "q_first_light" },
			objectives = {
				{
					id = "glass", label = "Gather kelp glass", count = 10,
					event = "inventory.added", match = { item = "kelp_glass" }, useAmount = true,
				},
			},
			rewards = { xp = 300, currency = { coin = 120 } },
		},
		q_the_bell = {
			name = "The Drowned Bell",
			summary = "She will not say why she wants it.",
			giver = "keeper",
			requires = { "q_glasswork" },
			objectives = {
				{
					id = "bell", label = "Recover the drowned bell", count = 1,
					event = "inventory.added", match = { item = "drowned_bell" }, useAmount = true,
				},
			},
			rewards = { xp = 900, currency = { coin = 500 } },
		},
		q_standing_order = {
			name = "Standing Order",
			summary = "She always needs tins. Always.",
			giver = "keeper",
			repeatable = true,
			requires = { "q_first_light" },
			objectives = {
				{
					id = "tins", label = "Deliver sealed tins", count = 5,
					event = "inventory.added", match = { item = "sealed_tin" }, useAmount = true,
				},
			},
			rewards = { xp = 180, currency = { coin = 90 } },
		},
	})

	-- dialogue ---------------------------------------------------------------
	Dialogue.define("keeper", {
		start = "greet",
		nodes = {
			greet = {
				text = "The tide went out early tonight. That means the shelf is open, and it means it wants something back.",
				choices = {
					{ text = "What needs doing?", action = "quests" },
					{ text = "I have salvage to sell.", action = "sell" },
					{ text = "Why does the light stay on?", goto = "light" },
					{ text = "Nothing tonight.", action = "close" },
				},
			},
			light = {
				text = "Because someone is still out there. Has been for eleven years. I keep it lit and I do not explain it twice.",
				choices = {
					{ text = "Understood.", goto = "greet" },
					{ text = "Is that who the bell is for?", goto = "bell", condition = function(ctx)
						return ctx.level ~= nil and ctx.level >= 3
					end },
				},
			},
			bell = {
				text = "Bring it up and we will find out together. Do not ring it on the water.",
				choices = { { text = "I will remember that.", goto = "greet" } },
			},
		},
	})
end

Content.items = ITEMS

return Content
