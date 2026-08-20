--!strict
-- L7: tycoon genre template.
--
-- A template is the composition layer. It takes a compact game definition -- how
-- many plots, which currencies, which tier costs -- and produces every artefact
-- the lower layers need: a blockout spec, a progression ladder, an economy, and
-- the mood and camera the genre expects.
--
-- It contains no geometry and no colours. Those come from the token set and the
-- kit, which is what allows two tycoons with entirely different art to share
-- this file, and what stops "tycoon" from meaning "the first game we shipped".
--
-- The structural signature of the genre, and the thing that distinguishes it
-- from the other templates: **a grid of private plots around a shared hub, and a
-- linear ladder the player climbs with money they generate themselves.**

local Blockout = require(script.Parent.Parent.WorldKit.Blockout)
local Grid = require(script.Parent.Parent.WorldKit.Grid)
local Progression = require(script.Parent.Parent.GameKit.Progression)

local Tycoon = {}

export type Definition = {
	id: string,
	--- One plot per concurrent player. This is the number that decides whether a
	--- server holds four players or eight, so it is declared, never inferred.
	plots: number,
	plotSize: number?,
	currency: string,
	--- Cumulative cost of each tier, in order.
	tierCosts: { number },
	tierMultiplier: number?,
	baseIncomePerSecond: number,
	hubSize: number?,
	moodId: string?,
	cameraId: string?,
}

export type Compiled = {
	genre: string,
	id: string,
	blockout: Blockout.Spec,
	ladder: Progression.Ladder,
	currencies: { { [string]: any } },
	moodId: string,
	cameraId: string,
	--- Structural fingerprint, used to prove two games are actually different
	--- rather than the same world with different colours.
	signature: { [string]: any },
}

local function fail(message: string): never
	error("[Templates.Tycoon] " .. message, 3)
end

--- Everything wrong with a definition, before it compiles anything.
function Tycoon.validate(definition: Definition, tokens: any): { string }
	local problems: { string } = {}

	if type(definition.id) ~= "string" or definition.id == "" then
		table.insert(problems, "definition needs an id")
	end
	if type(definition.plots) ~= "number" or definition.plots < 1 or definition.plots % 1 ~= 0 then
		table.insert(problems, "plots must be a positive integer")
	end
	if type(definition.currency) ~= "string" or definition.currency == "" then
		table.insert(problems, "definition needs a currency")
	end
	if type(definition.tierCosts) ~= "table" or #definition.tierCosts == 0 then
		table.insert(problems, "a tycoon needs at least one tier to climb")
	end
	if type(definition.baseIncomePerSecond) ~= "number" or definition.baseIncomePerSecond <= 0 then
		table.insert(problems, "baseIncomePerSecond must be positive")
	end

	local plotSize = definition.plotSize or tokens:grammar("plotMinDimension")
	local minimum = tokens:grammar("plotMinDimension")
	if plotSize < minimum then
		table.insert(problems, string.format(
			"plotSize %.0f is below the token grammar plotMinDimension %.0f; the plot cannot hold a buildable floor",
			plotSize, minimum
		))
	end

	return problems
end

--- Turn a definition into every artefact the lower layers consume.
function Tycoon.compile(definition: Definition, tokens: any): Compiled
	local problems = Tycoon.validate(definition, tokens)
	if #problems > 0 then
		fail("definition is invalid:\n- " .. table.concat(problems, "\n- "))
	end

	local plotSize = definition.plotSize or tokens:grammar("plotMinDimension")
	local avenue = tokens:grammar("avenueWidth")
	local hubSize = definition.hubSize or math.max(plotSize * 0.8, tokens:grammar("roomMinDimension") * 4)

	-- Two columns flanking a central avenue, which is the layout that keeps
	-- every plot one turn off the main street. `Grid` owns the arithmetic so the
	-- template never places anything by literal coordinate.
	local columns = if definition.plots >= 4 then 2 else 1
	local layout = Grid.layout(definition.plots, plotSize, plotSize * 0.12, Vector3.new(0, 0, plotSize), avenue, columns)
	local slots = Grid.slots(layout, definition.plots)

	local regions: { Blockout.Region } = {
		{
			id = "hub",
			kind = "hub",
			centre = Vector3.new(0, 0, -hubSize * 0.9),
			size = Vector2.new(hubSize, hubSize),
			spawn = true,
		},
	}
	local circulation: { Blockout.Route } = {}

	for _, slot in ipairs(slots) do
		table.insert(regions, {
			id = "plot-" .. tostring(slot.index),
			kind = "plot",
			centre = slot.centre,
			size = Vector2.new(plotSize, plotSize),
		})
		table.insert(circulation, { from = "hub", to = "plot-" .. tostring(slot.index), width = avenue })
	end

	-- One landmark over the hub, tall enough to orient a player from any plot.
	-- The height is derived from the map's own extent rather than chosen: a
	-- landmark that does not clear the buildings around it is not a landmark.
	local _, extent = Grid.extent(layout, definition.plots)
	local reach = math.max(extent.X, extent.Z) / 2 + hubSize
	local landmarkHeight = math.max(tokens:grammar("landmarkMinHeight"), reach * 0.28)

	local landmarks: { Blockout.Landmark } = {
		{
			id = "hub-tower",
			at = Vector3.new(0, 0, -hubSize * 0.9),
			height = landmarkHeight,
			visibleFrom = { "hub" },
		},
	}

	local tiers: { Progression.Tier } = {}
	for index, cost in ipairs(definition.tierCosts) do
		table.insert(tiers, {
			id = string.format("floor%d", index),
			index = index,
			displayName = string.format("Floor %d", index),
			cost = cost,
			currency = definition.currency,
			incomeMultiplier = definition.tierMultiplier or 1.6,
		})
	end

	return {
		genre = "tycoon",
		id = definition.id,
		blockout = {
			id = definition.id,
			regions = regions,
			circulation = circulation,
			landmarks = landmarks,
			sightlines = { { from = "hub", to = "hub-tower" } },
		},
		ladder = Progression.define(tiers),
		currencies = {
			{ id = definition.currency, displayName = definition.currency, startingBalance = 0 },
		},
		moodId = definition.moodId or "farm-noon",
		cameraId = definition.cameraId or "tycoon-shoulder",
		signature = {
			topology = "grid-plots-around-hub",
			progression = "linear-tier-ladder",
			privateSpace = true,
			regionCount = #regions,
			routeCount = #circulation,
			tierCount = #tiers,
			concurrentPlayers = definition.plots,
		},
	}
end

--- Pacing verdict for a compiled tycoon, with no game running.
function Tycoon.pacing(compiled: Compiled, definition: Definition, policy: { [string]: any }?): (any, { string })
	local report = Progression.pacing(compiled.ladder, definition.baseIncomePerSecond)
	return report, Progression.pacingProblems(report, policy)
end

return Tycoon
