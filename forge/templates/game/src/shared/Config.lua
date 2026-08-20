--!strict
-- Config — every tunable number for {{NAME}} in one place.
-- If a system contains a magic number, it belongs here instead.

return {
	name = "{{NAME}}",
	seed = 20260819,
	saveStore = "{{NAME}}_Profiles_v1",
	containers = { "Actors", "Props", "Effects", "Loot" },
}
