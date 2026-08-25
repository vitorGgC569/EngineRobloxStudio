--!strict
--[[
	AI — crowd and companion intelligence for Forge games.

	Pure decision layers over injected world probes: personality brains
	(TraitBrain), cheap kinematic locomotion (GroundLocomotion), bubble
	separation (CrowdSeparation), client pose blending (SnapshotInterp),
	sight/hearing memory (Perception) and weighted spawn specs (MobCatalog).

	The engine answers "what is true"; these modules decide what to do.
]]

return {
	TraitBrain = require(script.Parent.TraitBrain),
	GroundLocomotion = require(script.Parent.GroundLocomotion),
	CrowdSeparation = require(script.Parent.CrowdSeparation),
	SnapshotInterp = require(script.Parent.SnapshotInterp),
	Perception = require(script.Parent.Perception),
	MobCatalog = require(script.Parent.MobCatalog),
}
