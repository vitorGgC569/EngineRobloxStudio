--!strict
-- RESEARCH FACILITY — a clinical interior on two levels.
--
-- The old file's own comment promised "flanking side halls connect the two corridors at
-- both map ends (no single choke)" and then never built them, so the map was two parallel
-- corridors with eight identical labs and one server room. The side halls exist now, plus:
--   • a REACTOR hall with a catwalk mezzanine reached by ladder and stairs
--   • crawl vents that break line of sight and are too low to shoot down
--   • four lab layouts instead of eight copies of one
--
-- Tight sightlines favour the knife, so the vertical and crawl routes are what give
-- survivors an answer.

local Kit = require(script.Parent.Kit)

local C = Kit.Palettes.Facility

local GROUND = 0
local MEZZ = 18
local WALL_H = 13
local W, D = 260, 190

-- Lab. `kind` varies the internal layout and which walls have doors.
local function lab(
	geo: Instance,
	patrol: Instance,
	x: number,
	z: number,
	w: number,
	d: number,
	kind: number,
	label: string
)
	local wallProps = { Color = C.Panel, Material = Enum.Material.Metal }
	local white = { Color = C.LabWhite, Material = Enum.Material.SmoothPlastic }

	Kit.floor(geo, x, z, w, d, GROUND + 0.2, white)
	Kit.floor(geo, x, z, w, d, GROUND + WALL_H, { Color = C.DarkFloor, Material = Enum.Material.Metal })

	-- Every lab has at least two ways in; kind 2 has three.
	Kit.wallXDoor(geo, x, z - d / 2, w, WALL_H, GROUND, 9, wallProps)
	Kit.wallXDoor(geo, x, z + d / 2, w, WALL_H, GROUND, if kind == 2 then 9 else 0, wallProps)
	Kit.wallZDoor(geo, x - w / 2, z, d, WALL_H, GROUND, 8, wallProps)
	Kit.wallZ(geo, x + w / 2, z, d, WALL_H, GROUND, wallProps)

	-- Observation glass onto the corridor: you can be seen, and see, without a clear shot.
	Kit.window(geo, x + w / 2, z, d * 0.6, 7, GROUND + 3, false, { Color = C.Glass })

	if kind == 1 then
		Kit.box(geo, x, GROUND, z, w * 0.5, 4, 5, { Color = C.Metal, Material = Enum.Material.Metal })
	elseif kind == 2 then
		for _, ox in { -w / 4, w / 4 } do
			Kit.box(
				geo,
				x + ox,
				GROUND,
				z,
				6,
				8,
				d * 0.5,
				{ Color = C.Metal, Material = Enum.Material.Metal }
			)
		end
	elseif kind == 3 then
		Kit.cylinder(geo, x, GROUND, z, 8, 10, { Color = C.Accent, Material = Enum.Material.Glass })
		Kit.box(
			geo,
			x - w / 4,
			GROUND,
			z + d / 4,
			8,
			4,
			5,
			{ Color = C.Metal, Material = Enum.Material.Metal }
		)
	else
		Kit.box(geo, x, GROUND, z - d / 4, w * 0.7, 4, 4, { Color = C.Metal, Material = Enum.Material.Metal })
		Kit.box(geo, x, GROUND, z + d / 4, w * 0.7, 4, 4, { Color = C.Metal, Material = Enum.Material.Metal })
	end

	Kit.sign(geo, x, GROUND + WALL_H - 3, z - d / 2 - 0.9, label, Enum.NormalId.Front, C.Accent, 14)
	Kit.neonStrip(geo, x, GROUND + WALL_H - 1, z, w * 0.7, 2, C.Light, 2)
	Kit.patrolMarker(patrol, x, GROUND, z)
end

-- Crawl vent: a low connector you can move through but not fight through.
local function vent(geo: Instance, patrol: Instance, x: number, z: number, length: number, alongX: boolean)
	local metal = { Color = C.Metal, Material = Enum.Material.DiamondPlate }
	local w = if alongX then length else 9
	local d = if alongX then 9 else length
	Kit.floor(geo, x, z, w, d, GROUND + 0.3, metal)
	-- Ceiling at 5 studs: too low to stand, so it breaks every sightline through it.
	Kit.floor(geo, x, z, w, d, GROUND + 5, metal)
	if alongX then
		Kit.wallX(geo, x, z - d / 2, w, 5, GROUND, metal)
		Kit.wallX(geo, x, z + d / 2, w, 5, GROUND, metal)
	else
		Kit.wallZ(geo, x - w / 2, z, d, 5, GROUND, metal)
		Kit.wallZ(geo, x + w / 2, z, d, 5, GROUND, metal)
	end
	Kit.patrolMarker(patrol, x, GROUND, z)
end

local function reactorHall(geo: Instance, patrol: Instance, zombieSpawns: Instance, x: number, z: number)
	local metal = { Color = C.Metal, Material = Enum.Material.DiamondPlate }
	local panel = { Color = C.Panel, Material = Enum.Material.Metal }
	local hallW, hallD = 90, 80

	Kit.floor(geo, x, z, hallW, hallD, GROUND + 0.2, {
		Color = C.DarkFloor,
		Material = Enum.Material.DiamondPlate,
	})
	Kit.wallXDoor(geo, x, z - hallD / 2, hallW, 34, GROUND, 12, panel)
	Kit.wallXDoor(geo, x, z + hallD / 2, hallW, 34, GROUND, 12, panel)
	Kit.wallZDoor(geo, x - hallW / 2, z, hallD, 34, GROUND, 12, panel)
	Kit.wallZDoor(geo, x + hallW / 2, z, hallD, 34, GROUND, 12, panel)
	Kit.floor(geo, x, z, hallW, hallD, GROUND + 34, panel)

	-- The reactor core: a glowing cylinder that lights the room and blocks the centre.
	Kit.cylinder(geo, x, GROUND, z, 22, 30, { Color = C.Accent, Material = Enum.Material.Neon })
	Kit.neonStrip(geo, x, GROUND + 31, z, 24, 24, C.Accent, 6)

	-- Mezzanine catwalk ringing the core, with two independent ways up.
	for _, mz in { z - 28, z + 28 } do
		Kit.catwalk(geo, x, mz, hallW - 12, 12, MEZZ, metal)
	end
	for _, mx in { x - 33, x + 33 } do
		Kit.catwalk(geo, mx, z, 12, hallD - 12, MEZZ, metal)
	end
	Kit.stairs(geo, x - 33, z - 40, 10, GROUND, MEZZ, 18, "+Z", metal)
	Kit.ladder(geo, x + 33, z + 34, GROUND, MEZZ, metal)

	-- Hazard striping so the drop reads before you walk off it.
	for _, hx in { x - 33, x + 33 } do
		Kit.box(geo, hx, MEZZ, z, 12, 0.4, 4, { Color = C.Hazard, Material = Enum.Material.Neon })
	end

	Kit.sign(geo, x, GROUND + 20, z - hallD / 2 - 0.9, "REACTOR", Enum.NormalId.Front, C.Danger, 26)

	Kit.patrolMarker(patrol, x - 33, MEZZ, z)
	Kit.patrolMarker(patrol, x + 33, MEZZ, z)
	Kit.patrolMarker(patrol, x, GROUND, z - 34)
	Kit.spawnMarker(zombieSpawns, x, GROUND, z - 34)
	Kit.spawnMarker(zombieSpawns, x, MEZZ, z + 28)
end

return {
	name = "Research Facility",
	build = function(): Model
		local map, geo, survivorSpawns, zombieSpawns, patrol = Kit.newMap("Research Facility")

		local white = { Color = C.LabWhite, Material = Enum.Material.SmoothPlastic }
		local panel = { Color = C.Panel, Material = Enum.Material.Metal }
		local metal = { Color = C.Metal, Material = Enum.Material.DiamondPlate }

		Kit.floor(geo, 0, 0, W, D, GROUND, white)
		Kit.floor(geo, 0, 0, W, D, GROUND + 34, panel)

		Kit.wallX(geo, 0, -D / 2, W, 34, GROUND, panel)
		Kit.wallX(geo, 0, D / 2, W, 34, GROUND, panel)
		Kit.wallZ(geo, -W / 2, 0, D, 34, GROUND, panel)
		Kit.wallZ(geo, W / 2, 0, D, 34, GROUND, panel)

		-- Two main corridors running the length of the map...
		for _, cz in { -34, 34 } do
			Kit.floor(geo, 0, cz, W - 20, 16, GROUND + 0.25, {
				Color = C.Concrete,
				Material = Enum.Material.Concrete,
			})
			for i = -5, 5 do
				Kit.neonStrip(geo, i * 22, GROUND + WALL_H, cz, 12, 5, C.Light, 2)
			end
		end

		-- ...and the flanking side halls that connect them. These are the ones the original
		-- file's comment promised and never built, leaving a single choke through the middle.
		for _, sx in { -W / 2 + 24, W / 2 - 24 } do
			Kit.floor(geo, sx, 0, 16, 84, GROUND + 0.25, {
				Color = C.Concrete,
				Material = Enum.Material.Concrete,
			})
			Kit.neonStrip(geo, sx, GROUND + WALL_H, 0, 5, 40, C.Light, 2)
			Kit.patrolMarker(patrol, sx, GROUND, 0)
		end

		-- Labs off the outer edge of each corridor, four layouts.
		local kinds = { 1, 3, 2, 4, 4, 2, 3, 1 }
		local labels = { "BIO-1", "BIO-2", "CHEM", "COLD", "ASSAY", "OPTICS", "GENOME", "STORES" }
		for i = 0, 3 do
			local x = -84 + i * 56
			lab(geo, patrol, x, -D / 2 + 26, 48, 34, kinds[i + 1], labels[i + 1])
			lab(geo, patrol, x, D / 2 - 26, 48, 34, kinds[i + 5], labels[i + 5])
		end

		reactorHall(geo, patrol, zombieSpawns, 0, 0)

		-- Crawl vents: low flanking routes between the corridors and the reactor.
		vent(geo, patrol, -70, 0, 60, false)
		vent(geo, patrol, 70, 0, 60, false)
		vent(geo, patrol, 0, -60, 70, true)

		-- Server room: a holdout with three ways in, off the north corridor.
		local sx, sz = -95, 0
		Kit.floor(geo, sx, sz, 46, 46, GROUND + 0.2, metal)
		Kit.wallXDoor(geo, sx, sz - 23, 46, WALL_H, GROUND, 9, panel)
		Kit.wallXDoor(geo, sx, sz + 23, 46, WALL_H, GROUND, 9, panel)
		Kit.wallZDoor(geo, sx - 23, sz, 46, WALL_H, GROUND, 9, panel)
		Kit.wallZ(geo, sx + 23, sz, 46, WALL_H, GROUND, panel)
		Kit.floor(geo, sx, sz, 46, 46, GROUND + WALL_H, panel)
		for _, rx in { sx - 12, sx, sx + 12 } do
			Kit.box(geo, rx, GROUND, sz, 6, 10, 30, { Color = C.DarkFloor, Material = Enum.Material.Metal })
			Kit.neonStrip(geo, rx, GROUND + 10.4, sz, 4, 26, C.Accent, 1.2)
		end
		Kit.sign(geo, sx, GROUND + WALL_H - 3, sz - 23.9, "SERVER", Enum.NormalId.Front, C.Accent, 16)
		Kit.patrolMarker(patrol, sx, GROUND, sz)

		-- Decontamination bay opposite, a second named holdout.
		local dx = 95
		Kit.floor(geo, dx, 0, 46, 46, GROUND + 0.2, white)
		Kit.wallXDoor(geo, dx, -23, 46, WALL_H, GROUND, 9, panel)
		Kit.wallXDoor(geo, dx, 23, 46, WALL_H, GROUND, 9, panel)
		Kit.wallZDoor(geo, dx + 23, 0, 46, WALL_H, GROUND, 9, panel)
		Kit.window(geo, dx - 23, 0, 30, 8, GROUND + 3, false, { Color = C.Glass })
		Kit.floor(geo, dx, 0, 46, 46, GROUND + WALL_H, panel)
		for _, oz in { -12, 12 } do
			Kit.cylinder(geo, dx, GROUND, oz, 7, 11, { Color = C.Glass, Material = Enum.Material.Glass })
		end
		Kit.sign(geo, dx, GROUND + WALL_H - 3, -23.9, "DECON", Enum.NormalId.Front, C.Hazard, 16)
		Kit.patrolMarker(patrol, dx, GROUND, 0)

		-- Corridor / open lab axes — keep off solid wall lines and sealed rooms.
		local spots = {
			{ -100, 0 },
			{ -70, 0 },
			{ -40, 0 },
			{ 0, 0 },
			{ 40, 0 },
			{ 70, 0 },
			{ 100, 0 },
			{ -100, -40 },
			{ -100, 40 },
			{ 100, -40 },
			{ 100, 40 },
			{ -50, -50 },
			{ -50, 50 },
			{ 50, -50 },
			{ 50, 50 },
			{ 0, -50 },
			{ 0, 50 },
			{ -80, -25 },
			{ -80, 25 },
			{ 80, -25 },
			{ 80, 25 },
			{ -30, -60 },
			{ -30, 60 },
			{ 30, -60 },
			{ 30, 60 },
			{ -120, 0 },
			{ 120, 0 },
			{ -60, -60 },
			{ 60, 60 },
			{ 0, -70 },
			{ 0, 70 },
		}
		for _, spot in spots do
			Kit.spawnMarker(survivorSpawns, spot[1], GROUND, spot[2])
		end

		Kit.spawnMarker(zombieSpawns, -W / 2 + 24, GROUND, 0)
		Kit.spawnMarker(zombieSpawns, W / 2 - 24, GROUND, 0)
		Kit.spawnMarker(zombieSpawns, -120, GROUND, -34)
		Kit.spawnMarker(zombieSpawns, 120, GROUND, 34)
		Kit.spawnMarker(zombieSpawns, 0, GROUND, -60)

		return map
	end,
	lighting = {
		-- Clinical cyan-white: the only map where you can see clearly, which is the trade
		-- for how little cover it gives you.
		Ambient = Color3.fromRGB(96, 104, 112),
		OutdoorAmbient = Color3.fromRGB(110, 120, 130),
		ClockTime = 12,
		Brightness = 3,
		Exposure = 0,
		FogStart = 80,
		FogEnd = 520,
		FogColor = Color3.fromRGB(120, 134, 144),
		sky = { StarCount = 0, SunAngularSize = 18 },
		atmosphere = {
			Density = 0.22,
			Haze = 0.8,
			Glare = 0.1,
			Color = Color3.fromRGB(226, 240, 248),
			Decay = Color3.fromRGB(120, 140, 155),
		},
		postFx = {
			Contrast = 0.06,
			Saturation = -0.12,
			TintColor = Color3.fromRGB(232, 246, 255),
			BloomIntensity = 0.5,
			BloomThreshold = 0.94,
			BloomSize = 20,
		},
	},
}
