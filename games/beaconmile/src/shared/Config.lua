--!strict
-- Every tunable for Beaconmile. Systems read this table. They do not restate it.

local Config = {
	selfTest = game:GetService("RunService"):IsStudio(),

	name = "beaconmile",
	seed = 20261013,
	saveStore = "beaconmile_Profiles_v1",
	containers = { "Road" },
	maxPlayers = 6,

	shiftSeconds = 90,
	carryMax = 1,

	beacon = {
		burnSeconds = 28,
		feedSeconds = 16,
		burnCap = 40,
	},

	yard = {
		partName = "Yard",
		position = Vector3.new(0, 3, 0),
		size = Vector3.new(14, 1, 14),
	},

	beacons = {
		{ id = "yard", label = "Pátio", position = Vector3.new(0, 5, -28) },
		{ id = "bend", label = "Curva", position = Vector3.new(36, 5, -28) },
		{ id = "ridge", label = "Cume", position = Vector3.new(72, 5, -52) },
	},
}

return Config
