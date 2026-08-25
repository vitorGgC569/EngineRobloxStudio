--!strict
--[[
	Content — every number quarryline balances on.

	Schemas first, so a typo is an error at load instead of a nil three systems
	later. No system under `src/server/systems/` holds a balance number; they
	all read from here.

	The two critics
	---------------

	`Content.review` runs the engine's own manuals over these tables at
	startup: `Reference` for anything with hit points or a rate, and
	`Economy.Audit` for the whole faucet-and-sink curve. Both report and
	neither blocks — a table that disagrees with the manual is sometimes the
	design and sometimes a typo, and only a person can tell those apart.

	Having them run at all is the point. A price of 5,000 means nothing until
	something says "that is one hour and forty minutes away", and nobody reads
	that off a table.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Data = Forge.Data
local Reference = Forge.Reference

local Content = {}

--[[
	The machines a plot can hold.

	A tycoon is a chain: something produces, something carries, something
	sells. Each machine here is one link, and the interesting design is that
	they are bought separately — a player with three drills and one belt has a
	bottleneck they can see, which is the whole tutorial nobody has to write.

	`footprint` is in grid cells and drives `Tycoon.GridPlacement`; `draw` is
	what the machine costs to run, so a line can be over-built.
]]
Content.machines = {
	drill = {
		label = "Drill",
		role = "source",
		price = 250,
		footprintX = 2, footprintZ = 2,
		--: Ore per tick at level one. The whole economy scales off this.
		output = 3,
		draw = 1,
		colour = Color3.fromRGB(176, 132, 84),
	},
	belt = {
		label = "Conveyor",
		role = "carry",
		price = 90,
		footprintX = 1, footprintZ = 3,
		--[[
			What one belt can move per tick.

			Deliberately under two drills. A belt that keeps up with everything
			is a belt nobody thinks about, and a tycoon where you never think
			about the layout is a tycoon with one decision in it.
		]]
		output = 5,
		draw = 1,
		colour = Color3.fromRGB(96, 104, 112),
	},
	smelter = {
		label = "Smelter",
		role = "refine",
		price = 900,
		footprintX = 3, footprintZ = 3,
		--: Turns three ore into one ingot, which is worth six.
		output = 2,
		draw = 4,
		colour = Color3.fromRGB(196, 108, 60),
	},
	depot = {
		label = "Depot",
		role = "sell",
		price = 400,
		footprintX = 3, footprintZ = 2,
		output = 12,
		draw = 2,
		colour = Color3.fromRGB(92, 140, 168),
	},
}

--[[
	The upgrade tree.

	A directed graph rather than a list, because the interesting choice in a
	tycoon is *order*: capacity first or speed first. `roots` are the
	prerequisites, and `Progression.UpgradeTree` refuses a cycle at
	construction — which is the one way a tree like this goes wrong silently.
]]
Content.upgrades = {
	bore = {
		--[[
			Cost curve.

			Geometric at 1.55. Under about 1.4 the late game is free; over
			about 1.8 the third purchase is a wall. This one doubles roughly
			every two levels, which is the rate players read as "steady".
		]]
		cost = { base = 400, growth = 1.55 },
		maxLevel = 20,
	},
	belts = {
		cost = { base = 300, growth = 1.5 },
		maxLevel = 20,
	},
	furnace = {
		cost = { base = 1200, growth = 1.6 },
		maxLevel = 15,
		roots = { "bore" },
	},
	haulage = {
		cost = { base = 2000, growth = 1.6 },
		maxLevel = 15,
		roots = { "belts" },
	},
	contracts = {
		--: The sink that keeps existing past the last machine.
		cost = { base = 6000, growth = 1.7 },
		maxLevel = 25,
		roots = { "furnace", "haulage" },
	},
}

--[[
	What each upgrade level actually does.

	Kept beside the tree rather than inside it because `UpgradeTree` owns cost
	and prerequisites and has no opinion about effect — which is right: the
	same tree shape drives a dozen different games.
]]
Content.upgradeEffects = {
	bore = { stat = "oreRate", perLevel = 0.18 },
	belts = { stat = "carryRate", perLevel = 0.16 },
	furnace = { stat = "refineRate", perLevel = 0.22 },
	haulage = { stat = "sellRate", perLevel = 0.2 },
	contracts = { stat = "priceMultiplier", perLevel = 0.12 },
}

--[[
	Rebirth.

	The loop that gives a tycoon a second act. Everything resets except a
	permanent multiplier, so the second run is the same shape at four times the
	speed — which is the only reason anybody plays a tycoon twice.
]]
Content.rebirth = {
	baseCost = 250000,
	costGrowth = 2.2,
	bonusPerLife = 0.35,
}

--: What a full crate is worth, and how often the good one turns up.
Content.crates = {
	scrap = { weight = 60, coins = 400 },
	ore = { weight = 25, coins = 1200 },
	gem = { weight = 12, coins = 4000 },
	relic = { weight = 3, coins = 20000 },
}

function Content.load()
	Data.define("machine", {
		label = { type = "string" },
		role = { type = "string", oneOf = { "source", "carry", "refine", "sell" } },
		price = { type = "number", min = 1 },
		footprintX = { type = "number", min = 1 },
		footprintZ = { type = "number", min = 1 },
		output = { type = "number", min = 1 },
		draw = { type = "number", min = 0 },
		colour = { type = "Color3" },
	})
	Data.load("machine", Content.machines)
end

--: The machines as `GridPlacement` wants them.
function Content.gridItems(): { any }
	local items = {}
	for id, machine in Content.machines do
		table.insert(items, {
			id = id,
			footprintX = machine.footprintX,
			footprintZ = machine.footprintZ,
		})
	end
	return items
end

--: The upgrade tree as `UpgradeTree` wants it.
function Content.upgradeNodes(): { [string]: any }
	local nodes = {}
	for id, upgrade in Content.upgrades do
		nodes[id] = {
			cost = upgrade.cost,
			maxLevel = upgrade.maxLevel,
			roots = upgrade.roots,
		}
	end
	return nodes
end

-- ================================== review ==================================
--[[
	Hold this game's numbers up against the engine's manuals.

	Two of them, and they answer different questions. `Reference` knows what a
	rate and a cadence should look like. `Economy.Audit` knows what a
	progression curve feels like from the inside — which step is a wall and
	whether there is anything to spend on at the end.

	Run at startup and published on the debug seam, because a balance note in a
	file nobody opens is the same as no balance note.
]]
function Content.review(): { any }
	local notes = {}

	--[[
		The economy, walked as faucets and sinks.

		Income is estimated from one depot's throughput at level one, which is
		what a player has in their first minute. Every price is then a number of
		minutes rather than a number of coins.
	]]
	local Audit = Forge.Economy.Audit
	Audit.reset()

	local perTick = Content.machines.depot.output * 4
	Audit.faucet("depot", {
		amount = perTick,
		perMinute = 60 / 2, -- Config.tickSeconds
		note = "one depot selling at level one",
	})

	local tier = 1
	for id, machine in Content.machines do
		Audit.sink(id, { price = machine.price, tier = tier, repeatable = true })
	end
	for id, upgrade in Content.upgrades do
		tier += 1
		Audit.sink(id .. "_1", { price = upgrade.cost.base, tier = tier })
	end
	Audit.sink("rebirth", { price = Content.rebirth.baseCost, tier = 20 })

	for _, note in Audit.report().notes do
		table.insert(notes, { kind = "economy", id = "coin", note = note })
	end

	--[[
		The machines, as weapons.

		A stretch on the face of it, and it holds: `Reference.check("weapon")`
		is about output per unit time against a baseline, which is exactly what
		a production chain is. A machine ten times the throughput of everything
		else is the same defect as a gun nobody can compete with.
	]]
	for id, machine in Content.machines do
		local checked = Reference.check("weapon", {
			damage = machine.output,
			rpm = 60 / 2 * 60, -- one tick every two seconds, expressed per minute
		})
		for _, note in checked do
			table.insert(notes, { kind = "machine", id = id, note = note })
		end
	end

	return notes
end

return Content
