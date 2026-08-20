--!strict
-- The authored kit, by name.
--
-- Generated from the Blender kit. Callers ask for a name and get mesh
-- data or nil, so a world that wants a tree gets an authored one where
-- the kit has it and falls back to the Part version where it does not.
-- Nothing here is specific to one game: the names are the world
-- grammar's own prop vocabulary.

local MeshKit = {
	cave_landmark = require(script.cave_landmark),
	hub_landmark = require(script.hub_landmark),
	kit_plot = require(script.kit_plot),
	reef_landmark = require(script.reef_landmark),
}

--- Mesh data for a named kit entry, or nil when it has none.
function MeshKit.get(name: string)
	return (MeshKit :: any)[name]
end

return MeshKit
