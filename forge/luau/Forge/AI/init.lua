--!strict
--[[
	AI — crowd and companion intelligence for Forge games.

	Pure decision layers over injected world probes: personality brains
	(TraitBrain), cheap kinematic locomotion (GroundLocomotion), bubble
	separation (CrowdSeparation), client pose blending (SnapshotInterp),
	sight/hearing memory (Perception) and weighted spawn specs (MobCatalog).

	The engine answers "what is true"; these modules decide what to do.
]]

--[[
	Siblings, and the reference that was wrong.

	These were written `require(script.Parent.X)`. Inside a family's own
	`init.lua`, `script` *is* the family — so `script.Parent` is `Forge`, and
	every one of these was looking for a module one level too high. Requiring
	this family at all would have thrown; nothing did, because every caller so
	far reached past it to the child directly.

	Corrected to `script.X`, and given the same lazy resolver as the rest so a
	module added tomorrow is reachable without editing this list.
]]

local _AI = {
	TraitBrain = require(script.TraitBrain),
	GroundLocomotion = require(script.GroundLocomotion),
	CrowdSeparation = require(script.CrowdSeparation),
	SnapshotInterp = require(script.SnapshotInterp),
	Perception = require(script.Perception),
	MobCatalog = require(script.MobCatalog),
}

return setmetatable(_AI, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
