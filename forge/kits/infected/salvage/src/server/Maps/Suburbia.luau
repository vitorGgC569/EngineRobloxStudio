--!strict
-- SUBURBIA — a night-time residential street.
--
-- Rebuilt from six byte-identical flat-roofed boxes into a street with four house layouts,
-- walkable roofs, real windows, and three landmarks that give the map a shape you can call
-- out: the GAS STATION (open canopy, long sightlines), the CHURCH (the map's high ground,
-- up switchback stairs or a faster, more exposed ladder), and the PARK (open ground you
-- cross at your peril).
--
-- The design goal is verticality and named places. Roof-to-roof routes let survivors break
-- line of sight upward, which the original map — a single flat plane — had no answer for.

local Kit = require(script.Parent.Kit)

local C = Kit.Palettes.Suburbia

local ROAD_HALF = 12
local GROUND = 0

-- A house. `variant` selects the layout so the street doesn't read as one asset repeated.
--   1: single storey with a porch and a side door
--   2: two storey with a balcony and interior stairs
--   3: bungalow with a carport
--   4: narrow townhouse
local function house(
	geo: Instance,
	zombieSpawns: Instance,
	patrol: Instance,
	x: number,
	z: number,
	facing: number,
	variant: number
)
	local siding = ({ C.SidingA, C.SidingB, C.SidingC, C.Brick })[((variant - 1) % 4) + 1]
	local roofColor = if variant % 2 == 0 then C.RoofAlt else C.Roof
	local wallProps = { Color = siding, Material = Enum.Material.WoodPlanks }
	local roofProps = { Color = roofColor, Material = Enum.Material.Slate }
	local glassProps = { Color = C.Glass }
	local woodProps = { Color = C.Wood, Material = Enum.Material.WoodPlanks }

	local w = if variant == 4 then 24 else 34
	local d = if variant == 3 then 34 else 28
	local storeys = if variant == 2 then 2 else 1
	local wallH = 10
	local topY = GROUND + wallH * storeys

	for level = 0, storeys - 1 do
		local y = GROUND + level * wallH
		Kit.floor(geo, x, z, w, d, y + (if level == 0 then 0.2 else wallH), woodProps)

		local frontZ = z + facing * (d / 2)
		if level == 0 then
			Kit.wallXDoor(geo, x, frontZ, w, wallH, y, 8, wallProps)
		else
			Kit.wallX(geo, x, frontZ, w, wallH, y, wallProps)
			Kit.window(geo, x - 8, frontZ, 7, 5, y + 3, true, glassProps)
			Kit.window(geo, x + 8, frontZ, 7, 5, y + 3, true, glassProps)
		end
		-- Rear door: no house is a dead end, so a holdout is always breachable.
		Kit.wallXDoor(geo, x, z - facing * (d / 2), w, wallH, y, 7, wallProps)
		Kit.wallZDoor(geo, x - w / 2, z, d, wallH, y, if variant == 1 then 7 else 0, wallProps)
		Kit.wallZ(geo, x + w / 2, z, d, wallH, y, wallProps)
		if level == 0 then
			Kit.window(geo, x - w / 2, z - 8, 8, 5, y + 3, false, glassProps)
			Kit.window(geo, x + w / 2, z + 8, 8, 5, y + 3, false, glassProps)
		end
		-- One interior divider, so there are rooms to be cornered in.
		Kit.wallZDoor(geo, x, z, d * 0.7, wallH, y, 8, wallProps)
	end

	-- Walkable roof deck with a low parapet.
	Kit.floor(geo, x, z, w, d, topY, roofProps)
	Kit.railing(geo, x, z + d / 2, w, topY, true, roofProps)
	Kit.railing(geo, x, z - d / 2, w, topY, true, roofProps)

	-- Ways up. Stairs are the primary route because Humanoids (and therefore bots) walk them
	-- natively; the ladders are a player shortcut on top. An elevated position that only a
	-- ladder reaches would be a camping spot the horde could never answer.
	local stairX = x + w / 2 + 5
	Kit.floor(geo, stairX, z, 10, d * 0.9, GROUND + 0.2, woodProps)
	Kit.stairs(geo, stairX, z - d * 0.3, 9, GROUND, topY, 22, "+Z", woodProps)
	Kit.railing(geo, stairX + 5, z, d * 0.9, topY, false, woodProps)
	if variant == 2 then
		Kit.catwalk(geo, x, z + facing * (d / 2 + 4), w * 0.6, 8, GROUND + wallH, woodProps)
	end
	Kit.ladder(geo, x - w / 2 + 2, z - facing * (d / 2 - 2), GROUND, topY, { Color = C.Metal })

	-- Porch or carport.
	if variant == 3 then
		local px = x + w / 2 + 8
		Kit.floor(geo, px, z, 16, 20, GROUND + 0.2, { Color = C.Concrete, Material = Enum.Material.Concrete })
		Kit.floor(geo, px, z, 16, 20, GROUND + 9, roofProps)
		for _, cx in { px - 7, px + 7 } do
			for _, cz in { z - 9, z + 9 } do
				Kit.part(geo, Vector3.new(1, 9, 1), CFrame.new(cx, GROUND + 4.5, cz), wallProps)
			end
		end
	else
		local pz = z + facing * (d / 2 + 3)
		Kit.floor(geo, x, pz, w * 0.8, 6, GROUND + 0.2, woodProps)
		Kit.floor(geo, x, pz, w * 0.8, 6, GROUND + wallH, roofProps)
		for _, cx in { x - w * 0.35, x + w * 0.35 } do
			Kit.part(geo, Vector3.new(0.8, wallH, 0.8), CFrame.new(cx, GROUND + wallH / 2, pz), wallProps)
		end
	end

	-- Furniture: something to break line of sight indoors.
	Kit.box(geo, x - 6, GROUND, z + 5, 7, 3, 3, { Color = C.Wood, Material = Enum.Material.Wood })
	Kit.box(geo, x + 7, GROUND, z - 6, 4, 5, 4, { Color = C.Wood, Material = Enum.Material.Wood })

	-- Zombie spawn OUTSIDE the front door — never at house center (players/bots used to
	-- materialise inside furniture and sealed rooms with no clear exit).
	Kit.spawnMarker(zombieSpawns, x, GROUND, z + facing * (d / 2 + 10))
	Kit.patrolMarker(patrol, x, GROUND, z + facing * (d / 2 + 6))
	Kit.patrolMarker(patrol, x, topY, z)
end

local function gasStation(geo: Instance, patrol: Instance, x: number, z: number)
	local metal = { Color = C.Metal, Material = Enum.Material.Metal }
	Kit.floor(geo, x, z, 60, 44, GROUND + 0.2, { Color = C.Concrete, Material = Enum.Material.Concrete })

	-- Canopy: an elevated firing position covering the east end of the street.
	Kit.floor(geo, x, z, 52, 30, GROUND + 13, metal)
	Kit.railing(geo, x, z - 15, 52, GROUND + 13, true, metal)
	Kit.railing(geo, x, z + 15, 52, GROUND + 13, true, metal)
	for _, cx in { x - 20, x + 20 } do
		for _, cz in { z - 10, z + 10 } do
			Kit.cylinder(geo, cx, GROUND, cz, 2.4, 13, metal)
		end
	end
	Kit.ladder(geo, x + 24, z + 13, GROUND, GROUND + 13, metal)

	-- Pumps: chest-high hard cover under the canopy.
	for _, px in { x - 12, x, x + 12 } do
		Kit.box(geo, px, GROUND, z, 4, 6, 8, { Color = C.Accent, Material = Enum.Material.Metal })
	end

	-- Shop, enterable.
	local shopProps = { Color = C.SidingA, Material = Enum.Material.Brick }
	Kit.floor(geo, x, z + 30, 34, 20, GROUND + 0.2, { Color = C.Concrete, Material = Enum.Material.Concrete })
	Kit.wallXDoor(geo, x, z + 20, 34, 12, GROUND, 10, shopProps)
	Kit.wallX(geo, x, z + 40, 34, 12, GROUND, shopProps)
	Kit.wallZDoor(geo, x - 17, z + 30, 20, 12, GROUND, 8, shopProps)
	Kit.wallZ(geo, x + 17, z + 30, 20, 12, GROUND, shopProps)
	Kit.floor(geo, x, z + 30, 34, 20, GROUND + 12, { Color = C.Roof, Material = Enum.Material.Slate })
	Kit.window(geo, x - 9, z + 20, 9, 6, GROUND + 4, true, { Color = C.Glass })

	Kit.sign(geo, x, GROUND + 17, z - 16, "FUEL", Enum.NormalId.Front, C.Light, 24)
	Kit.neonStrip(geo, x, GROUND + 12.4, z, 46, 24, C.Light, 3)

	Kit.patrolMarker(patrol, x, GROUND, z)
	Kit.patrolMarker(patrol, x, GROUND + 13, z)
	Kit.patrolMarker(patrol, x, GROUND, z + 30)
end

local function church(geo: Instance, patrol: Instance, x: number, z: number)
	local stone = { Color = C.Concrete, Material = Enum.Material.Slate }
	local wood = { Color = C.Wood, Material = Enum.Material.WoodPlanks }

	Kit.floor(geo, x, z, 44, 64, GROUND + 0.2, wood)
	Kit.wallXDoor(geo, x, z - 32, 44, 22, GROUND, 10, stone)
	Kit.wallX(geo, x, z + 32, 44, 22, GROUND, stone)
	Kit.wallZDoor(geo, x - 22, z, 64, 22, GROUND, 8, stone)
	Kit.wallZDoor(geo, x + 22, z, 64, 22, GROUND, 8, stone)
	for _, wz in { z - 18, z, z + 18 } do
		Kit.window(geo, x - 22, wz, 10, 10, GROUND + 7, false, { Color = C.Glass })
		Kit.window(geo, x + 22, wz, 10, 10, GROUND + 7, false, { Color = C.Glass })
	end
	Kit.floor(geo, x, z, 44, 64, GROUND + 22, stone)
	Kit.pitchedRoof(geo, x, z, 44, 64, GROUND + 22, 10, { Color = C.Roof, Material = Enum.Material.Slate })

	for i = -3, 3 do
		Kit.box(geo, x, GROUND, z + i * 7, 30, 2.5, 2, wood)
	end

	-- Tower: the highest point on the map, and worth contesting.
	local tx, tz = x, z - 40
	Kit.floor(geo, tx, tz, 18, 18, GROUND + 0.2, stone)
	Kit.wallZ(geo, tx - 9, tz, 18, 40, GROUND, stone)
	Kit.wallZ(geo, tx + 9, tz, 18, 40, GROUND, stone)
	Kit.wallX(geo, tx, tz - 9, 18, 40, GROUND, stone)
	Kit.wallXDoor(geo, tx, tz + 9, 18, 40, GROUND, 8, stone)
	-- Switchback stairs up the tower, so the map's high ground is contestable by anything
	-- that walks. The ladder beside them is the fast, exposed way.
	Kit.stairs(geo, tx - 5, tz, 7, GROUND, GROUND + 20, 16, "+Z", stone)
	Kit.floor(geo, tx, tz, 18, 8, GROUND + 20, stone)
	Kit.stairs(geo, tx + 5, tz, 7, GROUND + 20, GROUND + 40, 16, "-Z", stone)
	Kit.ladder(geo, tx + 6, tz - 6, GROUND, GROUND + 40, { Color = C.Metal })
	Kit.floor(geo, tx, tz, 18, 18, GROUND + 40, stone)
	Kit.railing(geo, tx, tz - 9, 18, GROUND + 40, true, stone)
	Kit.railing(geo, tx, tz + 9, 18, GROUND + 40, true, stone)
	Kit.railing(geo, tx - 9, tz, 18, GROUND + 40, false, stone)
	Kit.railing(geo, tx + 9, tz, 18, GROUND + 40, false, stone)
	Kit.neonStrip(geo, tx, GROUND + 41, tz, 6, 6, C.Light, 4)

	Kit.sign(geo, x, GROUND + 26, z - 33, "ST. MARY", Enum.NormalId.Front, C.Light, 22)

	Kit.patrolMarker(patrol, x, GROUND, z)
	Kit.patrolMarker(patrol, tx, GROUND + 40, tz)
end

local function park(geo: Instance, patrol: Instance, x: number, z: number)
	local wood = { Color = C.Wood, Material = Enum.Material.WoodPlanks }
	Kit.floor(geo, x, z, 70, 60, GROUND + 0.1, { Color = C.Grass, Material = Enum.Material.Grass })

	-- Bandstand: the one piece of raised cover in otherwise open ground.
	Kit.floor(geo, x, z, 26, 26, GROUND + 4, wood)
	Kit.stairs(geo, x, z + 16, 10, GROUND, GROUND + 4, 8, "-Z", wood)
	for _, cx in { x - 11, x + 11 } do
		for _, cz in { z - 11, z + 11 } do
			Kit.cylinder(geo, cx, GROUND + 4, cz, 1.6, 10, wood)
		end
	end
	Kit.floor(geo, x, z, 28, 28, GROUND + 14, { Color = C.Roof, Material = Enum.Material.Slate })
	Kit.neonStrip(geo, x, GROUND + 13.4, z, 20, 20, C.Light, 2)

	for _, bz in { z - 22, z + 22 } do
		Kit.box(geo, x - 18, GROUND, bz, 10, 2, 3, wood)
		Kit.box(geo, x + 18, GROUND, bz, 10, 2, 3, wood)
	end
	for _, hx in { x - 30, x + 30 } do
		Kit.box(geo, hx, GROUND, z, 4, 6, 40, { Color = C.Grass, Material = Enum.Material.Grass })
	end

	Kit.patrolMarker(patrol, x, GROUND, z)
	Kit.patrolMarker(patrol, x, GROUND + 4, z)
end

return {
	name = "Suburbia",
	build = function(): Model
		local map, geo, survivorSpawns, zombieSpawns, patrol = Kit.newMap("Suburbia")

		-- Ground plane, then a crossroads rather than a single corridor.
		Kit.floor(geo, 0, 0, 300, 220, GROUND, { Color = C.Grass, Material = Enum.Material.Grass })
		Kit.floor(geo, 0, 0, 300, ROAD_HALF * 2, GROUND + 0.1, {
			Color = C.Road,
			Material = Enum.Material.Asphalt,
		})
		Kit.floor(geo, 0, 0, ROAD_HALF * 2, 220, GROUND + 0.1, {
			Color = C.Road,
			Material = Enum.Material.Asphalt,
		})
		for _, sz in { -ROAD_HALF - 3, ROAD_HALF + 3 } do
			Kit.floor(geo, 0, sz, 300, 6, GROUND + 0.15, {
				Color = C.Concrete,
				Material = Enum.Material.Concrete,
			})
		end

		local fenceProps = { Color = C.Metal, Material = Enum.Material.Metal }
		Kit.wallX(geo, 0, -110, 300, 12, GROUND, fenceProps)
		Kit.wallX(geo, 0, 110, 300, 12, GROUND, fenceProps)
		Kit.wallZ(geo, -150, 0, 220, 12, GROUND, fenceProps)
		Kit.wallZ(geo, 150, 0, 220, 12, GROUND, fenceProps)

		-- Housing: four layouts, mirrored across the street, no layout beside its twin.
		local variants = { 1, 3, 2, 4, 2, 1 }
		for i = 0, 2 do
			local x = -105 + i * 70
			house(geo, zombieSpawns, patrol, x, -55, -1, variants[i + 1])
			house(geo, zombieSpawns, patrol, x, 55, 1, variants[i + 4])
		end

		gasStation(geo, patrol, 100, -50)
		church(geo, patrol, 105, 55)
		park(geo, patrol, -20, 0)

		-- Yard fences with gaps: approaches are channelled, never sealed.
		for _, fx in { -70, 0, 70 } do
			for _, fz in { -75, 75 } do
				Kit.part(geo, Vector3.new(1, 6, 34), CFrame.new(fx, GROUND + 3, fz), {
					Color = C.Wood,
					Material = Enum.Material.WoodPlanks,
				})
			end
		end

		-- Parked cars: hard cover along the road.
		for i, cx in { -120, -85, -45, 10, 55, 120 } do
			local cz = (if i % 2 == 0 then -1 else 1) * (ROAD_HALF - 4)
			Kit.box(geo, cx, GROUND, cz, 16, 4, 8, { Color = C.Accent, Material = Enum.Material.Metal })
			Kit.box(geo, cx, GROUND + 4, cz, 9, 3.5, 7, { Color = C.Glass, Material = Enum.Material.Glass })
			Kit.patrolMarker(patrol, cx, GROUND, cz)
		end

		-- Streetlamps. On a midnight map these define which routes you can see down.
		for i = -4, 4 do
			local lx = i * 34
			for _, lz in { -ROAD_HALF - 5, ROAD_HALF + 5 } do
				Kit.cylinder(geo, lx, GROUND, lz, 1, 16, { Color = C.Metal, Material = Enum.Material.Metal })
				Kit.neonStrip(geo, lx, GROUND + 16, lz, 3, 3, C.Light, 5)
			end
		end

		-- Survivor spawns stay on open road / sidewalk / park — NOT house centers or
		-- interior coords that can land you inside a wall or sofa.
		local spots = {
			{ -130, 0 },
			{ -100, 0 },
			{ -60, 0 },
			{ -20, 0 },
			{ 20, 0 },
			{ 60, 0 },
			{ 100, 0 },
			{ 130, 0 },
			{ 0, -40 },
			{ 0, 40 },
			{ 0, -80 },
			{ 0, 80 },
			{ -40, -20 },
			{ -40, 20 },
			{ 40, -20 },
			{ 40, 20 },
			{ -90, -30 },
			{ -90, 30 },
			{ 90, -30 },
			{ 90, 30 },
			{ -120, -40 },
			{ -120, 40 },
			{ 120, -40 },
			{ 120, 40 },
			{ -20, -50 },
			{ -20, 50 },
			{ 50, -80 },
			{ 50, 80 },
			{ -50, -80 },
			{ -50, 80 },
		}
		for _, spot in spots do
			Kit.spawnMarker(survivorSpawns, spot[1], GROUND, spot[2])
		end

		-- Zombie spawns at the map edges, away from the housing rows.
		Kit.spawnMarker(zombieSpawns, -142, GROUND, 0)
		Kit.spawnMarker(zombieSpawns, 142, GROUND, 0)
		Kit.spawnMarker(zombieSpawns, 0, GROUND, -102)
		Kit.spawnMarker(zombieSpawns, 0, GROUND, 102)
		-- Elevated zombie spawns: a survivor holding a roof is never unreachable, even if
		-- the navmesh declines to route a bot up the stairs.
		Kit.spawnMarker(zombieSpawns, -105, GROUND + 10, -55)
		Kit.spawnMarker(zombieSpawns, 35, GROUND + 10, 55)
		Kit.spawnMarker(zombieSpawns, 105, GROUND + 40, 15)
		Kit.spawnMarker(zombieSpawns, 100, GROUND + 13, -50)

		return map
	end,
	lighting = {
		-- Cold blue night, lifted well off the old near-black so a zombie silhouette reads
		-- against a wall; the streetlamps supply the contrast.
		Ambient = Color3.fromRGB(42, 46, 66),
		OutdoorAmbient = Color3.fromRGB(58, 64, 92),
		ClockTime = 23.2,
		Brightness = 2.2,
		Exposure = 0.1,
		FogStart = 40,
		FogEnd = 420,
		FogColor = Color3.fromRGB(22, 26, 40),
		sky = { StarCount = 9000, MoonAngularSize = 15, SunAngularSize = 0 },
		atmosphere = {
			Density = 0.36,
			Haze = 1.8,
			Glare = 0.2,
			Color = Color3.fromRGB(150, 165, 200),
			Decay = Color3.fromRGB(60, 70, 100),
		},
		postFx = {
			Contrast = 0.12,
			Saturation = -0.08,
			TintColor = Color3.fromRGB(214, 226, 255),
			BloomIntensity = 0.7,
			BloomThreshold = 0.9,
			BloomSize = 28,
		},
	},
}
