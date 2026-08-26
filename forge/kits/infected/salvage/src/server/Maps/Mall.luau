--!strict
-- ABANDONED MALL — three levels around a central atrium.
--
-- This was already the best map in the game and the only one with a second floor, reached
-- by two sloped slabs. It now has real escalators, a third-level catwalk ring overlooking
-- the atrium, four distinct storefront types instead of ten copies of one, and a
-- back-of-house service corridor so the concourse isn't a single loop.
--
-- Vertical structure is the point: concourse, gallery, catwalk ring. Sightlines cross
-- between levels, so holding a balcony is strong but leaves you exposed from above.

local Kit = require(script.Parent.Kit)

local C = Kit.Palettes.Mall

local GROUND = 0
local FLOOR2 = 16
local FLOOR3 = 32
local WIDTH, DEPTH = 280, 180
local ATRIUM_W, ATRIUM_D = 90, 70

-- Storefront. `kind` picks the layout so the concourse isn't one unit repeated.
--   1: deep store with a back-of-house door
--   2: wide open frontage with island counters
--   3: narrow unit, sealed at the back — the only genuine trap in the mall
--   4: corner unit with two frontages
local function storefront(
	geo: Instance,
	patrol: Instance,
	x: number,
	z: number,
	facing: number,
	y: number,
	kind: number,
	label: string
)
	local wallProps = { Color = C.Concrete, Material = Enum.Material.Concrete }
	local accent = ({ C.Storefront, C.Teal, C.Accent, C.Brick })[((kind - 1) % 4) + 1]
	local trim = { Color = accent, Material = Enum.Material.SmoothPlastic }

	local w = if kind == 3 then 22 else (if kind == 2 then 46 else 34)
	local d = if kind == 1 then 40 else 30
	local h = 14
	local backZ = z + facing * (d / 2)
	local frontZ = z - facing * (d / 2)

	Kit.floor(geo, x, z, w, d, y + 0.2, { Color = C.TileAlt, Material = Enum.Material.Concrete })

	local openW = if kind == 2 then w * 0.7 else w * 0.5
	Kit.wallXDoor(geo, x, frontZ, w, h, y, openW, wallProps)
	Kit.part(geo, Vector3.new(w, 1.6, 1.4), CFrame.new(x, y + h - 0.8, frontZ), trim)

	Kit.wallZ(geo, x - w / 2, z, d, h, y, wallProps)
	if kind == 4 then
		Kit.wallZDoor(geo, x + w / 2, z, d, h, y, 10, wallProps)
	else
		Kit.wallZ(geo, x + w / 2, z, d, h, y, wallProps)
	end

	-- Always leave a back exit. Kind 3 used to seal the rear wall, which created
	-- genuine soft-lock rooms if a spawn/path landed inside.
	Kit.wallXDoor(geo, x, backZ, w, h, y, 8, wallProps)

	Kit.floor(geo, x, z, w, d, y + h, { Color = C.DarkFloor, Material = Enum.Material.Concrete })

	if kind == 2 then
		Kit.box(geo, x - 12, y, z, 12, 4, 5, trim)
		Kit.box(geo, x + 12, y, z, 12, 4, 5, trim)
	else
		Kit.box(geo, x, y, z + facing * 4, w * 0.6, 4, 4, trim)
		Kit.box(geo, x - w / 4, y, z - facing * 6, 6, 7, 4, wallProps)
	end

	local face = if facing > 0 then Enum.NormalId.Back else Enum.NormalId.Front
	Kit.sign(geo, x, y + h - 6, frontZ - facing * 0.9, label, face, accent, math.min(w * 0.8, 26))
	Kit.neonStrip(geo, x, y + h - 1.5, z, w * 0.8, 2, C.Light, 2)

	Kit.patrolMarker(patrol, x, y, z)
end

-- Stepped escalator: reads as an escalator and pathfinding treats it as stairs.
local function escalator(geo: Instance, patrol: Instance, x: number, z: number, y0: number, facing: string)
	local metal = { Color = C.Metal, Material = Enum.Material.DiamondPlate }
	Kit.stairs(geo, x, z, 12, y0, y0 + 16, 26, facing, metal)
	local alongX = facing == "+X" or facing == "-X"
	if alongX then
		Kit.railing(geo, x, z - 6, 26, y0 + 8, true, metal)
		Kit.railing(geo, x, z + 6, 26, y0 + 8, true, metal)
	else
		Kit.railing(geo, x - 6, z, 26, y0 + 8, false, metal)
		Kit.railing(geo, x + 6, z, 26, y0 + 8, false, metal)
	end
	Kit.patrolMarker(patrol, x, y0, z)
end

local function foodCourt(geo: Instance, patrol: Instance, x: number, z: number, y: number)
	Kit.floor(geo, x, z, 70, 56, y + 0.25, { Color = C.Tile, Material = Enum.Material.Concrete })

	-- A forest of low cover in an open room: good for a knife, bad for a rifle.
	for ix = -2, 2 do
		for iz = -1, 1 do
			local tx, tz = x + ix * 14, z + iz * 18
			Kit.cylinder(geo, tx, y, tz, 1.2, 4, { Color = C.Metal, Material = Enum.Material.Metal })
			Kit.box(geo, tx, y + 4, tz, 8, 0.6, 8, { Color = C.Storefront, Material = Enum.Material.Wood })
		end
	end

	for _, ox in { -22, 0, 22 } do
		Kit.box(geo, x + ox, y, z - 26, 18, 6, 5, { Color = C.Teal, Material = Enum.Material.SmoothPlastic })
	end
	Kit.sign(geo, x, y + 11, z - 29, "FOOD COURT", Enum.NormalId.Front, C.Light, 30)
	Kit.patrolMarker(patrol, x, y, z)
end

return {
	name = "Abandoned Mall",
	build = function(): Model
		local map, geo, survivorSpawns, zombieSpawns, patrol = Kit.newMap("Abandoned Mall")

		local tile = { Color = C.Tile, Material = Enum.Material.Concrete }
		local tileAlt = { Color = C.TileAlt, Material = Enum.Material.Concrete }
		local wallProps = { Color = C.Concrete, Material = Enum.Material.Concrete }
		local metal = { Color = C.Metal, Material = Enum.Material.DiamondPlate }

		Kit.floor(geo, 0, 0, WIDTH, DEPTH, GROUND, tile)

		Kit.wallX(geo, 0, -DEPTH / 2, WIDTH, 48, GROUND, wallProps)
		Kit.wallX(geo, 0, DEPTH / 2, WIDTH, 48, GROUND, wallProps)
		Kit.wallZ(geo, -WIDTH / 2, 0, DEPTH, 48, GROUND, wallProps)
		Kit.wallZ(geo, WIDTH / 2, 0, DEPTH, 48, GROUND, wallProps)

		-- Gallery (level 2): a ring around an open atrium.
		for _, gz in { -1, 1 } do
			Kit.floor(geo, 0, gz * (ATRIUM_D / 2 + 28), WIDTH, 56, FLOOR2, tileAlt)
			Kit.railing(geo, 0, gz * (ATRIUM_D / 2), WIDTH, FLOOR2, true, metal)
		end
		for _, gx in { -1, 1 } do
			Kit.floor(geo, gx * (ATRIUM_W / 2 + 40), 0, 80, DEPTH, FLOOR2, tileAlt)
			Kit.railing(geo, gx * (ATRIUM_W / 2), 0, ATRIUM_D, FLOOR2, false, metal)
		end

		-- Catwalk ring (level 3): narrow, exposed, overlooks everything.
		for _, gz in { -1, 1 } do
			Kit.catwalk(geo, 0, gz * (ATRIUM_D / 2 + 12), WIDTH - 40, 20, FLOOR3, metal)
		end
		for _, gx in { -1, 1 } do
			Kit.catwalk(geo, gx * (ATRIUM_W / 2 + 10), 0, 20, ATRIUM_D + 4, FLOOR3, metal)
		end

		-- Roof and skylight, so the middle of the map is naturally lit.
		Kit.floor(geo, 0, 0, WIDTH, DEPTH, 48, { Color = C.Roof, Material = Enum.Material.Metal })
		local skylight = Kit.floor(geo, 0, 0, ATRIUM_W, ATRIUM_D, 48, { Color = C.Glass })
		skylight.Transparency = 0.55
		skylight.Material = Enum.Material.Glass
		Kit.neonStrip(geo, 0, 46, 0, ATRIUM_W * 0.9, ATRIUM_D * 0.9, C.Light, 3)

		-- Vertical routes cross axes rather than stacking, so no single choke owns the map.
		escalator(geo, patrol, -100, -ATRIUM_D / 2 - 20, GROUND, "+Z")
		escalator(geo, patrol, 100, ATRIUM_D / 2 + 20, GROUND, "-Z")
		escalator(geo, patrol, -ATRIUM_W / 2 - 10, -60, FLOOR2, "+Z")
		escalator(geo, patrol, ATRIUM_W / 2 + 10, 60, FLOOR2, "-Z")

		local kinds = { 1, 2, 3, 4, 2, 1, 4, 3 }
		local labels =
			{ "ELECTRONICS", "GROCER", "PHARMACY", "OUTFITTERS", "TOYS", "HARDWARE", "BOOKS", "SHOES" }
		for i = 0, 3 do
			local x = -105 + i * 70
			storefront(geo, patrol, x, -DEPTH / 2 + 22, -1, GROUND, kinds[i + 1], labels[i + 1])
			storefront(geo, patrol, x, DEPTH / 2 - 22, 1, GROUND, kinds[i + 5], labels[i + 5])
		end
		for i = 0, 2 do
			local x = -80 + i * 80
			storefront(geo, patrol, x, -DEPTH / 2 + 20, -1, FLOOR2, ((i + 1) % 4) + 1, "UNIT " .. (i + 1))
		end

		-- Back-of-house service corridor: the flanking route behind the north units.
		Kit.floor(geo, 0, -DEPTH / 2 + 48, WIDTH - 30, 14, GROUND + 0.2, {
			Color = C.DarkFloor,
			Material = Enum.Material.Concrete,
		})
		Kit.wallX(geo, 0, -DEPTH / 2 + 55, WIDTH - 30, 14, GROUND, wallProps)
		for _, sx in { -110, 0, 110 } do
			Kit.neonStrip(geo, sx, GROUND + 13, -DEPTH / 2 + 48, 10, 6, C.Accent, 1.5)
		end
		Kit.ladder(geo, WIDTH / 2 - 20, -DEPTH / 2 + 48, GROUND, FLOOR2, metal)

		foodCourt(geo, patrol, 0, 0, GROUND)

		-- Planters and kiosks: cover under the skylight.
		for _, px in { -60, 60 } do
			for _, pz in { -25, 25 } do
				Kit.box(geo, px, GROUND, pz, 12, 5, 12, { Color = C.Teal, Material = Enum.Material.Grass })
			end
		end
		for _, kx in { -30, 30 } do
			Kit.box(geo, kx, GROUND, 0, 14, 9, 10, { Color = C.Storefront, Material = Enum.Material.Wood })
			Kit.patrolMarker(patrol, kx, GROUND, 0)
		end

		for i = 0, 5 do
			local x = -100 + i * 40
			Kit.box(geo, x, FLOOR2, -DEPTH / 2 + 40, 8, 8, 8, {
				Color = C.Brick,
				Material = Enum.Material.Wood,
			})
			Kit.patrolMarker(patrol, x, FLOOR2, -DEPTH / 2 + 40)
		end
		for _, cx in { -60, 0, 60 } do
			Kit.patrolMarker(patrol, cx, FLOOR3, -ATRIUM_D / 2 - 12)
		end

		-- Concourse + atrium ring only (open walkways). Avoid deep store interiors.
		local spots = {
			{ -40, -20, GROUND },
			{ -40, 20, GROUND },
			{ 40, -20, GROUND },
			{ 40, 20, GROUND },
			{ 0, -30, GROUND },
			{ 0, 30, GROUND },
			{ -80, 0, GROUND },
			{ 80, 0, GROUND },
			{ -20, -60, GROUND },
			{ -20, 60, GROUND },
			{ 20, -60, GROUND },
			{ 20, 60, GROUND },
			{ -100, -40, GROUND },
			{ -100, 40, GROUND },
			{ 100, -40, GROUND },
			{ 100, 40, GROUND },
			{ 0, -75, GROUND },
			{ 0, 75, GROUND },
			{ -50, 0, FLOOR2 },
			{ 50, 0, FLOOR2 },
			{ 0, -50, FLOOR2 },
			{ 0, 50, FLOOR2 },
			{ -90, -30, FLOOR2 },
			{ 90, 30, FLOOR2 },
			{ -30, -55, FLOOR2 },
			{ 30, 55, FLOOR2 },
			{ -40, -40, FLOOR3 },
			{ 40, 40, FLOOR3 },
			{ 0, -40, FLOOR3 },
			{ 0, 40, FLOOR3 },
		}
		for _, spot in spots do
			Kit.spawnMarker(survivorSpawns, spot[1], spot[3], spot[2])
		end

		Kit.spawnMarker(zombieSpawns, -130, GROUND, -DEPTH / 2 + 48)
		Kit.spawnMarker(zombieSpawns, 130, GROUND, -DEPTH / 2 + 48)
		Kit.spawnMarker(zombieSpawns, -130, GROUND, 0)
		Kit.spawnMarker(zombieSpawns, 130, GROUND, 0)
		Kit.spawnMarker(zombieSpawns, -120, FLOOR2, -60)
		Kit.spawnMarker(zombieSpawns, 120, FLOOR2, 60)
		Kit.spawnMarker(zombieSpawns, 0, FLOOR3, -47)
		Kit.spawnMarker(zombieSpawns, 0, FLOOR3, 47)
		Kit.spawnMarker(zombieSpawns, -100, GROUND, 80)
		Kit.spawnMarker(zombieSpawns, 100, GROUND, -80)
		Kit.spawnMarker(zombieSpawns, 0, GROUND, -80)
		Kit.spawnMarker(zombieSpawns, 0, GROUND, 80)

		return map
	end,
	lighting = {
		-- Warm amber interior with teal shadow: a dead mall with the lights half on.
		Ambient = Color3.fromRGB(70, 64, 58),
		OutdoorAmbient = Color3.fromRGB(96, 88, 78),
		ClockTime = 17.5,
		Brightness = 2.6,
		Exposure = 0.05,
		FogStart = 60,
		FogEnd = 460,
		FogColor = Color3.fromRGB(54, 48, 44),
		sky = { StarCount = 0, SunAngularSize = 28 },
		atmosphere = {
			Density = 0.3,
			Haze = 1.4,
			Glare = 0.35,
			Color = Color3.fromRGB(216, 196, 168),
			Decay = Color3.fromRGB(96, 84, 74),
		},
		postFx = {
			Contrast = 0.1,
			Saturation = 0.06,
			TintColor = Color3.fromRGB(255, 244, 226),
			BloomIntensity = 0.85,
			BloomThreshold = 0.88,
			BloomSize = 30,
		},
	},
}
