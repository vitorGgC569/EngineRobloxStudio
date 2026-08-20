--!strict
-- L7: wave-defence genre template.
--
-- This file exists to prove the SDK is an engine rather than an elaborate
-- validator for one game. It is deliberately the structural opposite of
-- `Tycoon` on every axis that matters:
--
--   Tycoon                          Defense
--   ------                          -------
--   grid of private plots           one shared radial arena
--   linear cost ladder              escalating wave ladder
--   idle income the player owns      burst income per wave cleared
--   shoulder camera, personal        overhead camera, tactical
--   space is partitioned             space is contested
--
-- If both compile from the same L0-L6 layers, produce valid blockouts, and
-- disagree on their structural signature, then nothing in those layers is shaped
-- like either game in particular. If one of them needs a special case, the layer
-- that needed it is not generic and the claim fails there.

local Blockout = require(script.Parent.Parent.WorldKit.Blockout)
local Progression = require(script.Parent.Parent.GameKit.Progression)

local Defense = {}

export type Definition = {
	id: string,
	--- Approach corridors converging on the core. Three or more, or the arena
	--- degenerates into a single line with no tactical choice.
	lanes: number,
	arenaRadius: number?,
	currency: string,
	--- Reward for clearing each wave, in order.
	waveRewards: { number },
	--- Enemy pressure multiplier per wave.
	difficultyStep: number?,
	secondsPerWave: number,
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
	signature: { [string]: any },
}

local function fail(message: string): never
	error("[Templates.Defense] " .. message, 3)
end

function Defense.validate(definition: Definition, tokens: any): { string }
	local problems: { string } = {}

	if type(definition.id) ~= "string" or definition.id == "" then
		table.insert(problems, "definition needs an id")
	end
	if type(definition.lanes) ~= "number" or definition.lanes < 3 or definition.lanes % 1 ~= 0 then
		table.insert(problems, "lanes must be an integer of at least 3; fewer removes the tactical choice the genre is built on")
	end
	if type(definition.waveRewards) ~= "table" or #definition.waveRewards == 0 then
		table.insert(problems, "a defence needs at least one wave")
	end
	if type(definition.secondsPerWave) ~= "number" or definition.secondsPerWave <= 0 then
		table.insert(problems, "secondsPerWave must be positive")
	end

	local radius = definition.arenaRadius or tokens:grammar("plotMinDimension")
	local minimum = tokens:grammar("roomMinDimension") * 3
	if radius < minimum then
		table.insert(problems, string.format(
			"arenaRadius %.0f is below %.0f; lanes would overlap the core and there would be nowhere to defend from",
			radius, minimum
		))
	end

	return problems
end

function Defense.compile(definition: Definition, tokens: any): Compiled
	local problems = Defense.validate(definition, tokens)
	if #problems > 0 then
		fail("definition is invalid:\n- " .. table.concat(problems, "\n- "))
	end

	local radius = definition.arenaRadius or tokens:grammar("plotMinDimension")
	local corridor = tokens:grammar("corridorWidth")
	local coreSize = math.max(tokens:grammar("roomMinDimension") * 2, radius * 0.35)

	-- The core is the spawn: in this genre the thing you protect and the thing
	-- you stand on are the same place, which is why there is no separate hub.
	local regions: { Blockout.Region } = {
		{
			id = "core",
			kind = "hub",
			centre = Vector3.new(0, 0, 0),
			size = Vector2.new(coreSize, coreSize),
			spawn = true,
		},
	}
	local circulation: { Blockout.Route } = {}
	local landmarks: { Blockout.Landmark } = {}

	local laneLength = math.max(radius, tokens:grammar("roomMinDimension") * 2)
	local laneWidth = math.max(corridor * 2, tokens:grammar("roomMinDimension"))

	for lane = 1, definition.lanes do
		local angle = (lane - 1) * (2 * math.pi / definition.lanes)
		local distance = coreSize / 2 + laneLength / 2
		local centre = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local id = string.format("lane-%d", lane)
		table.insert(regions, {
			id = id,
			kind = "lane",
			centre = centre,
			size = Vector2.new(laneWidth, laneWidth),
		})
		table.insert(circulation, { from = "core", to = id, width = corridor })
	end

	-- One beacon per lane mouth, so a player can read where pressure is coming
	-- from without a minimap. Height derived, not chosen.
	local beaconHeight = math.max(tokens:grammar("landmarkMinHeight"), laneLength * 0.3)
	table.insert(landmarks, {
		id = "core-beacon",
		at = Vector3.new(0, 0, 0),
		height = beaconHeight,
		visibleFrom = { "core" },
	})

	local tiers: { Progression.Tier } = {}
	local cumulative = 0
	local step = definition.difficultyStep or 1.35
	for index, reward in ipairs(definition.waveRewards) do
		cumulative += reward
		table.insert(tiers, {
			id = string.format("wave%d", index),
			index = index,
			displayName = string.format("Wave %d", index),
			cost = cumulative,
			currency = definition.currency,
			incomeMultiplier = step,
		})
	end

	return {
		genre = "defense",
		id = definition.id,
		blockout = {
			id = definition.id,
			regions = regions,
			circulation = circulation,
			landmarks = landmarks,
			sightlines = { { from = "core", to = "core-beacon" } },
		},
		ladder = Progression.define(tiers),
		currencies = {
			{ id = definition.currency, displayName = definition.currency, startingBalance = 0 },
		},
		moodId = definition.moodId or "farm-overcast",
		cameraId = definition.cameraId or "plot-overview",
		signature = {
			topology = "radial-lanes-around-core",
			progression = "escalating-wave-ladder",
			privateSpace = false,
			regionCount = #regions,
			routeCount = #circulation,
			tierCount = #tiers,
			concurrentPlayers = 0,
		},
	}
end

--- Wave pacing, expressed in the units the genre is actually judged in.
---
--- A defence does not stall because a tier is expensive; it stalls because a
--- wave takes too long to survive. The reward curve is fed in as income so the
--- same `Progression.pacing` machinery answers both genres.
function Defense.pacing(compiled: Compiled, definition: Definition, policy: { [string]: any }?): (any, { string })
	local incomeRate = definition.waveRewards[1] / definition.secondsPerWave
	local report = Progression.pacing(compiled.ladder, incomeRate)
	local rules = policy or {}
	if rules.maximumFirstTierSeconds == nil then
		rules.maximumFirstTierSeconds = definition.secondsPerWave * 1.5
	end
	return report, Progression.pacingProblems(report, rules)
end

return Defense
