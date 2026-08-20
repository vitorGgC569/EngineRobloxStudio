--!strict
-- Config — every tunable number for provingground in one place.
-- If a system contains a magic number, it belongs here instead.

return {
	name = "provingground",
	seed = 20260819,
	saveStore = "provingground_Profiles_v1",
	containers = { "Actors", "Props", "Effects", "Loot" },

	-- Run the live gameplay suite during bootstrap and publish the report.
	-- On in Studio, off in a published place: these scenarios spawn rigs and
	-- write to a DataStore, neither of which belongs in a session someone is
	-- actually playing.
	selfTest = game:GetService("RunService"):IsStudio(),
}
