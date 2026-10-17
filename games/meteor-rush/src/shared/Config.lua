--!strict
return {
	selfTest = game:GetService("RunService"):IsStudio(),
	name = "Meteor Rush",
	id = "meteor-rush",
	seed = 20260929,
	saveStore = "MeteorRush_Profiles_v1",
	maxPlayers = 6,

	meteorSpawnEvery = 6.0,
	maxLiveMeteors = 12,
	meteorLifetime = 58,
	showerEvery = 105,
	showerCount = 12,

	offlineCapSeconds = 8 * 60 * 60,
	offlineEfficiency = 0.35,
	baseWalkSpeed = 18,
	speedPerLevel = 2.25,

	-- The first playable prototype used a 122-stud base ring and read like a
	-- tabletop diorama. These dimensions keep the 6-player social loop while
	-- giving the field, yards and landmarks their own visual space.
	worldSize = 520,
	baseRadius = 218,
	arenaRadius = 132,
	craterRadius = 118,
	captureRadius = 14,
	decoderRadius = 14,

	monetization = {
		doubleStardustPassId = 0,
		extraVaultPassId = 0,
		stardustPackProductId = 0,
	},
}
