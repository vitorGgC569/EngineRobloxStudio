--!strict
-- Every tunable for Saltmere. Systems read this table. They do not restate it.

local Config = {
	selfTest = game:GetService("RunService"):IsStudio(),

	name = "saltmere",
	seed = 20261013,
	saveStore = "saltmere_Profiles_v1",
	containers = { "Plots", "Quay", "Props", "Effects" },
	maxPlayers = 6,
	startCash = 30,

	tide = {
		flood = 8,
		settle = 2,
		harvest = 18,
		spoil = 4,
	},

	production = {
		capacityBase = 8,
		capacityPerLevel = 4,
		fillPerSecond = 2,
		yieldPerBrine = 1,
		spoilKeep = 0.25,
		watchSpoilKeep = 0.65,
		prestigeYieldBonus = 0.25,
		readyThreshold = 0.85,
	},

	prices = {
		coarse = 6,
		fine = 12,
		flake = 22,
		smoked = 34,
		pressure = 0.04,
	},

	refine = {
		coarsePerFine = 4,
		finePerSmoked = 2,
		flakeChanceAtMaxPan = 0.12,
		flakePanLevel = 5,
	},

	prestige = {
		lifetimeBase = 400,
		lifetimeStep = 1.6,
		cashReset = 30,
	},

	crew = {
		max = 4,
		wage = { raker = 2, grader = 3, watch = 4 },
		hireCost = { raker = 50, grader = 120, watch = 200 },
	},

	pans = {
		{ id = "pan_1", claimCost = 0, row = 0, col = 0 },
		{ id = "pan_2", claimCost = 40, row = 0, col = 1 },
		{ id = "pan_3", claimCost = 140, row = 0, col = 2 },
		{ id = "pan_4", claimCost = 420, row = 1, col = 0 },
		{ id = "pan_5", claimCost = 1100, row = 1, col = 1 },
		{ id = "pan_6", claimCost = 2600, row = 1, col = 2 },
	},

	panUpgrade = {
		maxLevel = 5,
		baseCost = 35,
		costPower = 2.05,
	},

	upgrades = {
		{ id = "cistern", maxLevel = 4, baseCost = 80, costGrowth = 2.4 },
		{ id = "rake", maxLevel = 4, baseCost = 60, costGrowth = 2.2 },
		{ id = "sluice", maxLevel = 3, baseCost = 90, costGrowth = 2.3 },
		{ id = "grader_bench", maxLevel = 1, baseCost = 250, costGrowth = 1 },
		{ id = "smokehouse", maxLevel = 1, baseCost = 700, costGrowth = 1 },
		{ id = "cooperage", maxLevel = 3, baseCost = 180, costGrowth = 2.5 },
		{ id = "lighthouse", maxLevel = 5, baseCost = 500, costGrowth = 2.1 },
		{ id = "lantern", maxLevel = 1, baseCost = 40, costGrowth = 1 },
	},

	effects = {
		cisternCapacity = 3,
		rakeYield = 0.15,
		sluiceFill = 0.2,
		cooperagePrice = 0.12,
		lighthousePrice = 0.08,
	},

	world = {
		plotStride = 70,
		plotOriginX = 0,
		plotZ = 18,
		panSpacing = 18,
		panSize = { x = 14, y = 1.2, z = 14 },
		quay = { x = 0, y = 1, z = -42, length = 160, width = 18 },
		spawnY = 5,
	},

	colors = {
		brine = { 48, 110, 112 },
		salt = { 236, 232, 220 },
		timber = { 92, 64, 46 },
		tar = { 28, 26, 24 },
		copper = { 176, 112, 62 },
		marsh = { 62, 78, 58 },
		foam = { 210, 220, 216 },
		stone = { 128, 132, 128 },
		fog = { 168, 178, 176 },
	},
}

return Config
