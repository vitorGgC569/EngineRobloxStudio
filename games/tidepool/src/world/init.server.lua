--!strict
-- World: the validated blockout, built.
--
-- The spec was expanded by the world grammar and passed the planner, including
-- its reachability walk, before this file existed. Building it here is the
-- first moment any of it becomes geometry.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldKit = require(ReplicatedStorage.WorldKit)
local WorldSpec = require(ReplicatedStorage.Shared.WorldSpec)
local TokenData = require(ReplicatedStorage.Shared.TokenData)

local tokens = WorldKit.Tokens.define(TokenData)

-- The spec arrives as plain data; Vector types are reconstructed here rather
-- than emitted, because a serialised Vector3 is a table that looks like one.
local spec = {
	id = WorldSpec.id,
	regions = {},
	circulation = WorldSpec.circulation,
	landmarks = {},
	sightlines = WorldSpec.sightlines,
}
for _, region in ipairs(WorldSpec.regions) do
	table.insert(spec.regions, {
		id = region.id,
		kind = region.kind,
		centre = Vector3.new(region.centre[1], region.centre[2], region.centre[3]),
		size = Vector2.new(region.size[1], region.size[2]),
		spawn = region.spawn,
		elevation = region.elevation,
	})
end
for _, landmark in ipairs(WorldSpec.landmarks) do
	table.insert(spec.landmarks, {
		id = landmark.id,
		at = Vector3.new(landmark.at[1], landmark.at[2], landmark.at[3]),
		height = landmark.height,
		visibleFrom = landmark.visibleFrom,
	})
end

local problems = WorldKit.Blockout.validate(spec, tokens)
if #problems > 0 then
	-- Validated again at runtime. The planner checked this spec, but the spec
	-- that reaches the place is the one that matters, and a mismatch means the
	-- emitter and the planner disagree.
	error("[World] the built spec does not validate: " .. table.concat(problems, "; "), 0)
end

local built = WorldKit.Blockout.build(spec, tokens, workspace)
print(string.format("[tidepool] world: %d regions, %.0f covered",
	#spec.regions, built.coveredArea))

return built
