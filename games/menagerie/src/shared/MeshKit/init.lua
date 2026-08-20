--!strict
-- The authored kit, by name.
--
-- Generated from the Blender kit. Callers ask for a name and get mesh
-- data or nil, so a world that wants a tree gets an authored one where
-- the kit has it and falls back to the Part version where it does not.
-- Nothing here is specific to one game: the names are the world
-- grammar's own prop vocabulary.

local MeshKit = {
	barrel = require(script.barrel),
	crate = require(script.crate),
	objective = require(script.objective),
	rock = require(script.rock),
	tree = require(script.tree),
}

--- Mesh data for a named kit entry, or nil when it has none.
function MeshKit.get(name: string)
	return (MeshKit :: any)[name]
end

return MeshKit
