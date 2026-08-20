--!strict
-- Config — every tunable number for lanternreach in one place.

return {
	name = "lanternreach",
	seed = 771103,
	saveStore = "lanternreach_Profiles_v1",
	containers = { "Salvage", "Props", "Npcs", "Effects" },
	satchelSlots = 18,

	-- Run the live suite during bootstrap and publish the report. On in
	-- Studio, off in a published place: the scenarios build and destroy real
	-- instances, which does not belong in a session somebody is playing.
	selfTest = game:GetService("RunService"):IsStudio(),
}
