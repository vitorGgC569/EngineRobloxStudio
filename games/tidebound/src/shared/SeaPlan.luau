--!strict
--[[
	SeaPlan — the shape of the sea, as a pure value.

	One description of the world: the base relief, the islets, the dock
	flats, and which way each dock faces. `WorldService` builds a
	heightfield from it; the headless tests measure the same numbers with
	no Studio involved, because the failure this module exists to prevent
	is a plan that looks right and is dry: an early `range` put the mean
	height above the waterline, so every ring of every zone sampled land,
	and only a live smoke test noticed.

	Keep everything here pure: `Vector2` arithmetic, `Config`, and
	nothing that needs the engine. `heightfieldConfig` returns the plain
	table `World.heightfield` takes.
]]

local Config = require(script.Parent.Config)

local SeaPlan = {}

SeaPlan.sea = Config.waterLevel
SeaPlan.size = Config.worldSize
SeaPlan.floor = 3

--[[
	The base relief the islets stand on. fbm01 is Perlin remapped to 0..1
	and lives almost entirely inside 0.35..0.65, so this range is what
	decides the water: 3 + 0.35*29 = 13 studs at the low end, 21.9 at the
	high end, both comfortably below the waterline at 24. Land is made by
	the features below, deliberately, not by the base drifting upward.
]]
SeaPlan.range = { 3, 32 }
SeaPlan.base = {
	{ frequency = 0.0016, octaves = 4, weight = 0.62 },
	{ frequency = 0.0068, octaves = 5, weight = 0.30 },
	{ frequency = 0.024, octaves = 3, weight = 0.08 },
}

--: Where a zone's pier is anchored: on the rim of the zone circle facing the
--: hub, so the walkable islet is outside the water and always inside the
--: heightfield. (A fixed direction put the abyss islet two studs off the map,
--: and a dock that is not on land fails the smoke test for good reason.)
function SeaPlan.dockPoint(zone: any): Vector2
	local outward = zone.center.Magnitude > 0
		and -zone.center.Unit
		or Vector2.new(0, -1)
	return zone.center + outward * (zone.radius + 46)
end

--[[
	The features, in the order they are applied.

	The hub is a broad flat with hills behind it. Every outer zone gets a
	dock flat plus one character islet -- and the islets are sized as
	islands *inside* the fishing water, not continents over it: the first
	version drew the kelp ridge at zoneRadius + 60 around a zone of 260,
	which is a landmass wider than its own water.
]]
function SeaPlan.features(): { any }
	local features: { any } = {
		{ kind = "flat", center = SeaPlan.dockPoint(Config.zone("shallows")), radius = 96, height = SeaPlan.sea + 7, blend = 2.1 },
		{ kind = "mound", center = Vector2.new(120, 150), radius = 220, amount = 46, sharpness = 1.9 },
		{ kind = "ridge", center = Vector2.new(-180, 190), radius = 200, amount = 64, sharpness = 1.7 },
		-- Background silhouettes far out, so the horizon is not an edge.
		{ kind = "ridge", center = Vector2.new(-940, -120), radius = 260, amount = 120, sharpness = 1.6 },
		{ kind = "ridge", center = Vector2.new(760, -210), radius = 240, amount = 96, sharpness = 1.7 },
		{ kind = "mound", center = Vector2.new(880, 260), radius = 200, amount = 72, sharpness = 1.8 },
	}

	for _, zone in Config.zones do
		if zone.id == "shallows" then
			continue
		end
		local dock = SeaPlan.dockPoint(zone)
		if zone.id == "kelp" then
			table.insert(features, { kind = "ridge", center = zone.center, radius = zone.radius * 0.55, amount = 38, sharpness = 1.8 })
			table.insert(features, { kind = "flat", center = dock, radius = 70, height = SeaPlan.sea + 5.5, blend = 2.0 })
		elseif zone.id == "coral" then
			table.insert(features, { kind = "mound", center = zone.center, radius = zone.radius * 0.5, amount = 30, sharpness = 2.0 })
			table.insert(features, { kind = "flat", center = dock, radius = 66, height = SeaPlan.sea + 5, blend = 2.0 })
		elseif zone.id == "storm" then
			table.insert(features, { kind = "ridge", center = zone.center, radius = zone.radius * 0.5, amount = 52, sharpness = 1.5 })
			table.insert(features, { kind = "flat", center = dock, radius = 62, height = SeaPlan.sea + 9, blend = 1.8 })
		elseif zone.id == "abyss" then
			-- The trench itself: a basin with a rim, dark and deep.
			table.insert(features, { kind = "basin", center = zone.center, radius = zone.radius, amount = 34, sharpness = 1.4 })
			table.insert(features, { kind = "rim", center = zone.center, radius = zone.radius + 90, inner = zone.radius - 40, amount = 62, sharpness = 1.7 })
			table.insert(features, { kind = "flat", center = dock, radius = 58, height = SeaPlan.sea + 6, blend = 1.9 })
		end
	end

	return features
end

--: The plain table `World.heightfield` takes. Built fresh each call so a
--: caller cannot mutate the plan through it.
function SeaPlan.heightfieldConfig(): any
	return {
		size = SeaPlan.size,
		seed = Config.seed,
		base = SeaPlan.base,
		range = SeaPlan.range,
		floor = SeaPlan.floor,
		features = SeaPlan.features(),
	}
end

return SeaPlan
