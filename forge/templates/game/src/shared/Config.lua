--!strict
-- Config — every tunable number for {{NAME}} in one place.
-- If a system contains a magic number, it belongs here instead.

return {
	-- Run the live suite during bootstrap and publish its report. On in
	-- Studio, off in a published place.
	selfTest = game:GetService("RunService"):IsStudio(),

	name = "{{NAME}}",
	seed = 20260819,
	saveStore = "{{NAME}}_Profiles_v1",
	containers = { "Actors", "Props", "Effects", "Loot" },
}
