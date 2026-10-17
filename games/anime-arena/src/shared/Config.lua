--!strict
-- Config — every tunable number for anime-arena in one place.

return {
	selfTest = game:GetService("RunService"):IsStudio(),

	name = "anime-arena",
	seed = 20260819,
	saveStore = "anime_arena_Profiles_v1",
	containers = { "Actors", "Props", "Effects", "Loot" },

	arenaRadius = 120,
	arenaHeight = 4,
	walkSpeed = 16,
	sprintSpeed = 24,
	dashCooldown = 2.5,
	fireballCooldown = 1.2,
	comboWindow = 1.0,
	maxEnemies = 8,
	xpPerKill = 25,
}