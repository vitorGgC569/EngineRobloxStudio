--!strict
-- Config — every tunable number for aurarift in one place.
-- If a system contains a magic number, it belongs here instead.

return {
	-- Run the live suite during bootstrap and publish its report. On in
	-- Studio, off in a published place.
	selfTest = game:GetService("RunService"):IsStudio(),

	name = "aurarift",
	seed = 20260819,
	saveStore = "aurarift_Profiles_v1",
	containers = { "World", "Props", "Effects", "Loot", "Actors" },
}
