--!strict
-- World: the validated layout, built and then inhabited.
--
-- The blockout was already here and it was all that was here. `Blockout.build`
-- produces the regions and routes the planner validated -- correct, walkable,
-- and visually a set of coloured plates. A capture of it scored 22/100 on
-- environment density, with 90% of the frame one unbroken plane.
--
-- What this adds is the difference between a layout and a place, and it is
-- driven by the region *kind* rather than by the game, so a plaza in a tower
-- defense and a plaza in a simulator are built the same way and neither is
-- special-cased:
--
--   plaza / spawn     terraced ground, banners, lamps -- somewhere to stand
--   shop / interior   buildings with doors facing the circulation
--   landmark          a keep with a beacon, tall enough to read from anywhere
--   field / plot      planting and rock, kept clear of the routes
--   corridor / street lamps along it, buildings lining it
--
-- Two things are deliberately global rather than per region:
--
-- **A perimeter.** The single largest contributor to the flat-plane measurement
-- is the horizon, and no density inside the play space removes it. Walls with
-- towers close the world off and give every outward view something to end on.
--
-- **Relief.** Ground at one elevation reads as a floor plan in perspective
-- regardless of what stands on it.
--
-- Every proportion comes from the token grammar and every colour from a palette
-- role, so a change of kit moves the whole world instead of half of it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WorldKit = require(ReplicatedStorage.WorldKit)
local WorldSpec = require(ReplicatedStorage.Shared.WorldSpec)
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local AssetPlan = require(ReplicatedStorage.Shared.AssetPlan)

local tokens = WorldKit.Tokens.define(TokenData)
local MOOD = "grove-day"
local CAMERA_PROFILE = "mobile-shoulder"
local SEED = 607817

local random = Random.new(SEED)

local STYLE = {
	wall = "stonePrimary",
	trim = "stoneSecondary",
	roof = "structureSecondary",
	accent = "accentGold",
}

-- Light first: three props under default lighting read worse than an empty
-- scene under a considered sky, and it costs one call.
local applied = WorldKit.Mood.apply(tokens, MOOD)

-- The spec arrives as plain data; Vector types are rebuilt here rather than
-- serialised, because a stored Vector3 is a table that merely looks like one.
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

-- Validated again here. The planner checked this spec, but the spec that
-- reaches the place is the one that matters, and a mismatch means the emitter
-- and the planner disagree about what was approved.
local problems = WorldKit.Blockout.validate(spec, tokens)
if #problems > 0 then
	error("[World] the built spec does not validate: " .. table.concat(problems, "; "), 0)
end

local built = WorldKit.Blockout.build(spec, tokens, workspace)
local root = built.root

local dressing = Instance.new("Folder")
dressing.Name = "Dressing"
dressing.Parent = root

-- How far the world reaches, from the regions themselves rather than a guess.
local far = 0
for _, region in ipairs(spec.regions) do
	local reach = math.max(math.abs(region.centre.X), math.abs(region.centre.Z))
		+ math.max(region.size.X, region.size.Y) / 2
	far = math.max(far, reach)
end
local half = far * 1.35
local structures = 0
-- Half the plaza reach: inside this, the ground is paved.
local extentGuard = far * 0.34

local function slab(name: string, size: Vector3, position: Vector3, role: string,
	material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = position
	p.Color = tokens:color(role)
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = dressing
	return p
end

-- Ground beyond the blockout, with relief. Grass rather than a flat colour: at
-- this scale a single tone is most of what makes a plate read as a plate.
slab("Ground", Vector3.new(half * 2.4, 4, half * 2.4), Vector3.new(0, -3, 0),
	"ground", Enum.Material.Grass)
for index = 1, 16 do
	local angle = random:NextNumber(0, math.pi * 2)
	local distance = random:NextNumber(far * 1.05, half * 1.05)
	local size = random:NextNumber(60, 150)
	local mound = slab("Mound",
		Vector3.new(size, random:NextNumber(8, 26), size * random:NextNumber(0.6, 1.4)),
		Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance),
		random:NextNumber() > 0.5 and "ground" or "groundAlt", Enum.Material.Grass)
	mound.Orientation = Vector3.new(0, random:NextNumber(0, 360), 0)
end

-- Grass in patches, not one colour.
--
-- The last plane standing. Panelling the region floors took the frame from
-- 60% unbroken to 54%, and what was left was the lawn outside them: one
-- slab the size of the world in a single green. Overlapping patches at two
-- tones cost a few dozen parts and give the ground a grain the eye can
-- measure distance against.
for index = 1, 34 do
	local angle = random:NextNumber(0, math.pi * 2)
	local distance = math.sqrt(random:NextNumber(0.02, 1)) * half
	local size = random:NextNumber(38, 96)
	local patch = slab("Patch",
		Vector3.new(size, 1.2, size * random:NextNumber(0.55, 1.5)),
		Vector3.new(math.cos(angle) * distance, -1.6, math.sin(angle) * distance),
		random:NextNumber() > 0.45 and "groundAlt" or "vegetationLeafDark",
		Enum.Material.Grass)
	patch.Orientation = Vector3.new(0, random:NextNumber(0, 360), 0)
end

-- The perimeter. What turns an expanse into a place, and what removes the empty
-- horizon the measurement was actually reading.
local corners = {
	Vector3.new(-half, 0, -half), Vector3.new(half, 0, -half),
	Vector3.new(half, 0, half), Vector3.new(-half, 0, half),
}
for index = 1, #corners do
	WorldKit.Architecture.wall(dressing, tokens, {
		from = corners[index],
		to = corners[(index % #corners) + 1],
		height = tokens:grammar("buildingMinHeight") * 1.5,
		style = STYLE,
		towerSpacing = 150,
	})
end

-- Outlying towers, at varied heights, beyond the wall.
--
-- The skyline was the one axis that would not move: corner towers stand at
-- the same height on the same square, so from any angle they read as one
-- line. What breaks a horizon is silhouettes at different distances and
-- heights, which is why watchtowers sit outside the perimeter.
for index = 1, 7 do
	local angle = (index / 7) * math.pi * 2 + 0.7
	local distance = half * random:NextNumber(1.06, 1.3)
	WorldKit.Architecture.tower(dressing, tokens, {
			position = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance),
		radius = random:NextNumber(7, 13),
		height = tokens:grammar("buildingMinHeight") * random:NextNumber(1.2, 2.6),
		style = STYLE,
		beacon = index % 3 == 0,
	})
	structures += 1
end

-- Landmarks the planner declared, as keeps rather than as boxes.
for _, landmark in ipairs(spec.landmarks) do
	WorldKit.Architecture.tower(dressing, tokens, {
		position = landmark.at,
		radius = 15,
		height = math.max(landmark.height, tokens:grammar("landmarkMinHeight")),
		style = STYLE,
		beacon = true,
	})
end

-- Per region, by kind. Nothing here names a genre: a shop is a shop in every
-- game that declares one.
local PROPS_BY_KIND = {
	field = { "tree", "tree", "rock" },
	plot = { "tree", "rock", "crate" },
	plaza = { "crate", "barrel", "banner" },
	street = { "barrel", "crate" },
	corridor = { "barrel" },
	shop = { "crate", "barrel" },
	decorative = { "tree", "rock" },
}

local props = 0
for _, region in ipairs(spec.regions) do
	local centre = region.centre
	local size = region.size
	local minSide = math.min(size.X, size.Y)
	local minFootprint = tokens:grammar("buildingMinFootprint")

	if region.kind == "plaza" or region.spawn == true then
		WorldKit.Architecture.terrace(dressing, tokens, {
			centre = centre, size = Vector2.new(size.X * 0.7, size.Y * 0.7),
			steps = 3, style = STYLE,
		})
		structures += 1
		for index = 1, 4 do
			local angle = (index / 4) * math.pi * 2
			WorldKit.Props.banner(dressing, tokens, {
				position = centre + Vector3.new(math.cos(angle) * size.X * 0.32, 4,
					math.sin(angle) * size.Y * 0.32),
				seed = SEED + index,
			})
			props += 1
		end
	end

	if (region.kind == "shop" or region.kind == "interior" or region.kind == "landmark")
		and minSide >= tokens:grammar("buildingMinFootprint") * 1.6 then
		local count = region.kind == "landmark" and 1 or 2
		for index = 1, count do
			local angle = random:NextNumber(0, math.pi * 2)
			WorldKit.Architecture.building(dressing, tokens, {
				position = centre + Vector3.new(math.cos(angle) * size.X * 0.22, 0,
					math.sin(angle) * size.Y * 0.22),
				footprint = Vector2.new(
					math.clamp(size.X * 0.4, minFootprint, 52),
					math.clamp(size.Y * 0.4, minFootprint, 44)),
				floors = random:NextInteger(1, 3),
					rotation = random:NextNumber(0, 360),
				style = STYLE,
				seed = SEED + index,
			})
			structures += 1
		end
	end

	if region.kind == "street" or region.kind == "corridor" then
		local along = math.max(math.floor(math.max(size.X, size.Y) / 40), 1)
		for index = -along, along do
			for _, side in ipairs({ -1, 1 }) do
				WorldKit.Props.lamp(dressing, tokens, {
					position = centre + Vector3.new(side * size.X * 0.36, 1, index * 40),
					seed = SEED + index,
				})
				props += 1
			end
		end
	end

	-- Planting, kept off the centre of every region so nothing lands where the
	-- player stands or walks.
	local kinds = PROPS_BY_KIND[region.kind] or { "tree", "rock" }
	local density = math.max(math.floor((size.X * size.Y) / 2600), 3)
	for index = 1, density do
		local angle = random:NextNumber(0, math.pi * 2)
		-- Across the region, not around its rim. Placing at a fixed 0.42-0.5 of
	-- the radius ringed every region and left the middle bare -- and the
	-- middle is the near field, which is where a player-level frame reads
	-- as an empty plane. Square-rooted so the points spread by area rather
	-- than bunching toward the centre.
	local radius = math.sqrt(random:NextNumber(0.04, 0.25))
		WorldKit.Props.build(kinds[random:NextInteger(1, #kinds)], dressing, tokens, {
			position = centre + Vector3.new(
				math.cos(angle) * size.X * radius, 0, math.sin(angle) * size.Y * radius),
			rotation = random:NextNumber(0, 360),
			scale = random:NextNumber(0.8, 1.5),
			seed = SEED + index,
		})
		props += 1
	end
end

-- Ground cover, everywhere. Tufts and pebbles cost nothing at distance and
-- are most of what stops the near field reading as one flat colour.
for index = 1, 260 do
	local angle = random:NextNumber(0, math.pi * 2)
	local distance = math.sqrt(random:NextNumber(0.01, 1)) * half * 0.98
	-- Ground only. Grass sprouting from a paved plaza reads as a placement
	-- bug, and a close capture showed exactly that: green sticks standing
	-- on the stone the player walks over.
	local onPaving = math.abs(math.cos(angle) * distance) < extentGuard
		and math.abs(math.sin(angle) * distance) < extentGuard
	if not onPaving then
		WorldKit.Props.tuft(dressing, tokens, {
		position = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance),
		rotation = random:NextNumber(0, 360),
			scale = random:NextNumber(0.7, 1.6),
			seed = SEED + 900 + index,
		})
		props += 1
	end
end

-- Woodland between the play space and the wall, so the perimeter is arrived at
-- rather than simply met.
for index = 1, 70 do
	local angle = random:NextNumber(0, math.pi * 2)
	local distance = random:NextNumber(far * 1.02, half * 0.94)
	WorldKit.Props.build(random:NextNumber() > 0.28 and "tree" or "rock", dressing, tokens, {
		position = Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance),
		rotation = random:NextNumber(0, 360),
		scale = random:NextNumber(0.9, 1.8),
		seed = SEED + 500 + index,
	})
	props += 1
end

Players.PlayerAdded:Connect(function(player: Player)
	local ok, err = pcall(function()
		WorldKit.Camera.configurePlayer(player, tokens, CAMERA_PROFILE)
	end)
	if not ok then
		warn("[brickfarm2] camera profile " .. CAMERA_PROFILE .. ": " .. tostring(err))
	end
end)

local pending = 0
for _, entry in ipairs(AssetPlan) do
	if entry.strategy == "CREATE" then
		pending += 1
	end
end

print(string.format(
	"[brickfarm2] world: mood %s, %d lights, %d regions, %d structures, %d props, %d/%d assets pending",
	MOOD, applied.created or 0, #spec.regions, structures, props, pending, #AssetPlan))

return built
