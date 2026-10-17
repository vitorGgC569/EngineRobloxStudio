--[[
	WorldSpec — where everything stands.

	The world builder (server), the station prompts and any future guidance
	marker all read these numbers. A coordinate typed twice is a station a
	player can walk to but cannot use.
]]

local WorldSpec = {}

WorldSpec.plazaSize = Vector3.new(248, 2, 248)

--: The player lands south of the altar, facing it, with the gate behind.
WorldSpec.spawn = Vector3.new(0, 2, -88)
WorldSpec.spawnLookAt = Vector3.new(0, 4, 0)

WorldSpec.altar = Vector3.new(0, 0, 0)
WorldSpec.gate = Vector3.new(0, 0, -102)
WorldSpec.tower = Vector3.new(74, 0, -30)
WorldSpec.dojo = Vector3.new(-74, 0, -30)
WorldSpec.ascend = Vector3.new(0, 0, 68)
WorldSpec.ranks = Vector3.new(46, 0, -66)

WorldSpec.wallHeight = 16

--: Names the world builder gives the stations' ProximityPrompts. The client
--: maps each name to the interface action it opens; these strings are the
--: contract between Structures/Shrine.lua and the client bootstrap.
WorldSpec.prompts = {
	altar = "RollAtAltar",
	tower = "OpenTower",
	dojo = "OpenDojo",
	ascend = "OpenAscend",
	ranks = "OpenRanks",
}

return WorldSpec
