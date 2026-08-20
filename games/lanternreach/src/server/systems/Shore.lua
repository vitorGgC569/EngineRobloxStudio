--!strict
--[[
	Shore — the tidal shelf, as terrain plus a streamed Scene.

	The split matters. Terrain is a function of a seed and belongs in code:
	nobody hand-places a heightfield. Everything standing *on* it — reeds,
	rocks, pilings, the lighthouse, the Keeper — is a Scene placement, which
	means it can be listed, saved, diffed, streamed and edited by hand in the
	overlay.

	This is the version of the file that proves Scene under load: roughly a
	thousand placements, none of which exist in the world until somebody walks
	near them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local World = Forge.World
local Scene = Forge.Scene
local Streaming = Forge.Streaming
local Assets = Forge.Assets
local Rng = Forge.Core.Rng
local Visual = Forge.Visual
local Debug = Forge.Debug

local Shore = {}

Shore.field = nil
Shore.scene = nil
Shore.streamer = nil
Shore.seaLevel = 26
Shore.dock = Vector3.new(0, 30, 0)

local ISLETS = {
	{ Vector2.new(-118, 92), 46, 16 },
	{ Vector2.new(146, -64), 54, 19 },
	{ Vector2.new(74, 158), 40, 13 },
	{ Vector2.new(-172, -128), 62, 22 },
	{ Vector2.new(-46, -186), 38, 11 },
	{ Vector2.new(196, 118), 44, 15 },
}

-- =============================== prop assets ================================
-- Registered as producers so they can be Scene placements, appear in the
-- editor palette, and be re-created identically after a chunk unloads.
local function registerProps()
	Assets.producer("Prop", function(id, definition)
		local model = Instance.new("Model")
		model.Name = definition.label or id
		local stream = Rng.stream("prop." .. id)
		-- One palette for the whole shore, so a hundred props read as a place
		-- instead of as a hundred independent colour decisions.
		local palette = Visual.palette("shore")

		if definition.kind == "reeds" then
			for i = 1, 5 do
				local blade = Instance.new("Part")
				blade.Size = Vector3.new(0.16, stream:number(2.4, 5.2), 0.16)
				blade.CFrame = CFrame.new(stream:number(-1.6, 1.6), blade.Size.Y / 2, stream:number(-1.6, 1.6))
					* CFrame.Angles(math.rad(stream:number(-14, 14)), stream:number(0, 6.28), math.rad(stream:number(-14, 14)))
				blade.Color = palette:vary("foliage", stream:number(0, 1))
				blade.Material = Enum.Material.Grass
				blade.Anchored = true
				blade.CanCollide = false
				blade.CanQuery = false
				blade.Parent = model
			end
		elseif definition.kind == "rock" then
			for i = 1, 3 do
				local size = stream:number(2.2, 5.4) / i
				local chunk = Instance.new("Part")
				chunk.Size = Vector3.new(size * 1.3, size, size * 1.1)
				chunk.CFrame = CFrame.new(stream:number(-2, 2), size * 0.3, stream:number(-2, 2))
					* CFrame.Angles(stream:number(0, 0.6), stream:number(0, 6.28), stream:number(0, 0.6))
				chunk.Color = palette:vary("stone", stream:number(0, 1))
				chunk.Material = Visual.material("stone", stream:number(0, 1))
				chunk.Anchored = true
				chunk.Parent = model
			end
		elseif definition.kind == "piling" then
			local post = Instance.new("Part")
			post.Size = Vector3.new(1.1, stream:number(6, 11), 1.1)
			post.CFrame = CFrame.new(0, post.Size.Y / 2, 0) * CFrame.Angles(0, stream:number(0, 6.28), math.rad(stream:number(-6, 6)))
			post.Color = Color3.fromRGB(62, 52, 44)
			post.Material = Enum.Material.Wood
			post.Anchored = true
			post.Parent = model
		end

		local first = model:FindFirstChildWhichIsA("BasePart")
		model.PrimaryPart = first
		model:SetAttribute("ForgeAsset", id)
		return model
	end)

	Assets.registerMany("Prop", {
		Reeds = { kind = "reeds", label = "Reeds" },
		Rock = { kind = "rock", label = "Shelf Rock" },
		Piling = { kind = "piling", label = "Piling" },
	})

	Assets.producer("Structure", function(id, definition)
		local model = Instance.new("Model")
		model.Name = definition.label

		if definition.kind == "lighthouse" then
			local height = 58
			local tower = Instance.new("Part")
			tower.Size = Vector3.new(11, height, 11)
			-- Sunk well below the pivot: a single surface sample is the centre
			-- of a voxel-rounded mound, so a tower placed exactly on it floats
			-- from every angle but straight down.
			tower.CFrame = CFrame.new(0, height / 2 - 14, 0)
			tower.Color = Color3.fromRGB(198, 194, 186)
			tower.Material = Enum.Material.Concrete
			tower.Anchored = true
			tower.Parent = model
			model.PrimaryPart = tower

			local lamp = Instance.new("Part")
			lamp.Name = "Lamp"
			lamp.Size = Vector3.new(6, 5, 6)
			lamp.CFrame = CFrame.new(0, height - 14 + 2.5, 0)
			lamp.Color = Color3.fromRGB(255, 224, 160)
			lamp.Material = Enum.Material.Neon
			lamp.Anchored = true
			lamp.Parent = model

			local beam = Instance.new("SpotLight")
			beam.Color = Color3.fromRGB(255, 226, 170)
			beam.Range = 220
			beam.Brightness = 6
			beam.Angle = 42
			beam.Face = Enum.NormalId.Front
			beam.Parent = lamp

			local glow = Instance.new("PointLight")
			glow.Color = Color3.fromRGB(255, 218, 150)
			glow.Range = 120
			glow.Brightness = 3
			glow.Parent = lamp

			-- The sweep is the game's clock: when the beam passes, you can see.
			task.spawn(function()
				while lamp.Parent do
					lamp.CFrame = lamp.CFrame * CFrame.Angles(0, math.rad(1.1), 0)
					task.wait(0.03)
				end
			end)
		end

		model:SetAttribute("ForgeAsset", id)
		return model
	end)

	Assets.register("Structure.Lighthouse", { kind = "lighthouse", label = "Lighthouse" })
end

-- ================================== build ===================================
function Shore.start()
	local t0 = os.clock()
	registerProps()

	local features = {
		{ kind = "mound", center = Vector2.new(0, 0), radius = 58, amount = 34, sharpness = 2.4 },
	}
	for _, islet in ISLETS do
		table.insert(features, {
			kind = "mound",
			center = islet[1],
			radius = islet[2],
			amount = islet[3],
			sharpness = 2.1,
		})
	end

	local field = World.heightfield({
		size = 560,
		seed = Rng.masterSeed(),
		base = {
			{ frequency = 0.0055, octaves = 4, weight = 0.62 },
			{ frequency = 0.024, octaves = 3, weight = 0.38 },
		},
		-- The whole map sits just under and just over the waterline. That
		-- narrow band is the game: everything interesting is wadeable.
		range = { 18, 30 },
		falloff = { power = 3.1, radius = 300 },
		features = features,
		floor = 6,
	})
	Shore.field = field

	World.paint(field, {
		clear = true,
		seaLevel = Shore.seaLevel,
		chunk = 64,
		budgetMs = 10,
		material = function(_x, _z, height, slope)
			if height > Shore.seaLevel + 12 then
				return Enum.Material.Rock
			end
			if height > Shore.seaLevel + 2 then
				return slope < 0.7 and Enum.Material.Rock or Enum.Material.Sand
			end
			if height > Shore.seaLevel - 3 then
				return Enum.Material.Sand
			end
			return Enum.Material.Mud
		end,
	})

	local dockX, dockZ = 26, 18
	local dockGround = World.surface(dockX, dockZ) or Vector3.new(dockX, Shore.seaLevel + 4, dockZ)
	Shore.dock = dockGround + Vector3.new(0, 3, 0)

	Shore.buildScene()
	-- Lighting moved to the client's Sky cycle: a server-set look cannot
	-- interpolate per frame and cannot scale to a device's quality tier.

	Debug.probe("shore", function()
		return {
			seaLevel = Shore.seaLevel,
			islets = #ISLETS,
			dock = { Shore.dock.X, Shore.dock.Y, Shore.dock.Z },
			placements = Shore.scene and #Shore.scene.placements or 0,
		}
	end)

	Debug.info(string.format("shore ready in %.1fs", os.clock() - t0))
end

--[[
	Compose the scene. Nothing here creates an Instance: it writes placements,
	and the streamer decides what becomes real.
]]
function Shore.buildScene()
	local scene = Scene.create("shelf")
	Shore.scene = scene

	local lighthouseGround = World.surface(0, 0) or Vector3.new(0, 30, 0)
	scene:add("Structure.Lighthouse", CFrame.new(lighthouseGround))
	scene:spawnPoint("dock", CFrame.new(Shore.dock))

	-- pilings marking the dock
	for i = 1, 6 do
		local angle = (i / 6) * math.pi * 2
		local x = Shore.dock.X + math.cos(angle) * 9
		local z = Shore.dock.Z + math.sin(angle) * 9
		local ground = World.surface(x, z)
		if ground then
			scene:add("Prop.Piling", CFrame.new(ground))
		end
	end

	-- reeds in the shallows and rocks on the islets, as data
	local reeds, rocks = 0, 0
	local step = 11
	local half = Shore.field.half

	for x = -half, half, step do
		for z = -half, half, step do
			local stream = Rng.at("shelf.props", x, z)
			local px = x + stream:number(-step / 2, step / 2)
			local pz = z + stream:number(-step / 2, step / 2)
			local height = Shore.field:height(px, pz)
			local slope = Shore.field:slope(px, pz)

			if height <= Shore.seaLevel + 1 and height >= Shore.seaLevel - 4 and slope > 0.86 then
				if stream:bool(0.42) then
					scene:add("Prop.Reeds", CFrame.new(px, height, pz))
					reeds += 1
				end
			elseif height > Shore.seaLevel + 3 and slope > 0.72 then
				if stream:bool(0.2) then
					scene:add("Prop.Rock", CFrame.new(px, height, pz))
					rocks += 1
				end
			end
		end
	end

	-- No `scene:load()` here. Attaching the streamer first means the scene is
	-- never materialised in full even for an instant, which on a large map is
	-- the difference between a smooth start and a two-second stall.

	-- Chunks small enough that a boundary crossing is cheap, radii far enough
	-- apart that walking one does not thrash.
	-- Chunk size is relative to the world, not absolute. At 96 studs a 560-stud
	-- map has 26 chunks and a two-chunk pin radius covers a third of it, which
	-- is streaming that streams nothing. 48 gives enough granularity to matter.
	Shore.streamer = Streaming.attach(scene, {
		chunkSize = 48,
		loadRadius = 180,
		unloadRadius = 250,
		budget = 14,
		rate = 4,
	})
	-- Only what someone spawns onto is pinned: the dock and the lighthouse rock.
	Shore.streamer:pin(Shore.dock, 40)
	Shore.streamer:pin(Vector3.new(0, 0, 0), 40)
	Shore.streamer:start()

	Debug.info(string.format(
		"shelf scene: %d placements (%d reeds, %d rocks) across %d chunks",
		#scene.placements, reeds, rocks, Shore.streamer:chunkCount()
	))
end

--[[
	Art direction, as a named look rather than eleven Lighting assignments.

	The values that used to live here are now `Visual.presets.drowned_night`
	with two overrides. That matters for more than tidiness: a look can be
	transitioned into, captured, swapped for a quality tier, and read back by a
	validator — none of which a pile of property writes can do.
]]
function Shore.setNight()
	Visual.defineLook("shelf_night", (function()
		local look = table.clone(Visual.presets.drowned_night)
		-- This shelf is foggier and colder than the preset: the lighthouse beam
		-- has to be the only thing that reaches.
		look.fogEnd = 240
		look.atmosphere = table.clone(look.atmosphere)
		look.atmosphere.density = 0.58
		return look
	end)())

	Visual.apply("shelf_night")
end

-- Dawn, for when the night ends. One call, and every property moves together.
function Shore.setDawn(seconds: number?)
	Visual.transition("overcast_morning", seconds or 8)
end

-- Somewhere shallow enough to wade, far enough out to be worth the walk.
function Shore.salvagePoint(): Vector3?
	local stream = Rng.stream("shore.salvage")
	for _ = 1, 24 do
		local angle = stream:number(0, math.pi * 2)
		local distance = stream:number(48, 250)
		local x, z = math.cos(angle) * distance, math.sin(angle) * distance
		local point = World.surface(x, z, { ignoreWater = true })
		if point then
			local height = point.Y
			if height > Shore.seaLevel - 5 and height < Shore.seaLevel + 9 then
				return point + Vector3.new(0, 1.4, 0)
			end
		end
	end
	return nil
end

return Shore
