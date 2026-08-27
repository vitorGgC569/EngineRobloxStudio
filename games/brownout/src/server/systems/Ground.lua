--!strict
--[[
	Ground — the basin the outpost sits in, and the night over it.

	Two jobs, and the second is not decoration.

	The floor is terrain rather than a slab because the play area is a 950-stud
	circle and a part that size is one instance streaming can never drop, with
	no texture at any distance. Terrain chunks itself.

	The night is the game. `brownout` is about a lit radius shrinking, and that
	reads as nothing at all if Roblox's default noon is on: a player standing
	outside the lamps in daylight sees a well-lit field and cannot understand
	why they are taking damage. So the look here is dark enough that the lamps
	are the only thing you can see by, and the fog wall is set close enough that
	the edge of the world is dark rather than empty.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local World = Forge.World
local Visual = Forge.Visual
local Material = Forge.Material
local Prop = Forge.Catalog.Prop
local Mark = Forge.Mark
local Boot = Forge.Core.Boot

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Props = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Props"))

local Ground = {}

--: Past the furthest cell ring, with room for a rim that reads as a horizon.
local RADIUS = 470

--[[
	The basin floor sits at +24, not at 0, and that is not an aesthetic choice.

	`World.paint` clamps each chunk's voxel region to `math.max(0, minH - 12)`
	(World/init.lua:271). A heightfield whose surface is below zero therefore
	gets a write region that starts *above* its own ground, every voxel computes
	as air, and the paint reports every chunk written having written nothing.

	It is silent. The first version of this file put the floor at 0 with a range
	of -5..-1, `forge doctor` was clean, `World.paint` logged "basin written (256
	chunks)", and a raycast at the origin found nothing at all — the only terrain
	in the world was the rim, which is the part that happened to rise above zero.
	Players spawned onto a floating pad over a void.

	Keeping the whole surface positive costs nothing and sidesteps it.
]]
local FLOOR_Y = 24

Ground.radius = RADIUS
Ground.floorY = FLOOR_Y
--: The heightfield, kept so other systems can sample it without rebuilding it.
Ground.field = nil :: any

-- ================================== the look ================================
--[[
	A clear, cold night with a moon in it.

	The temptation with a darkness game is to set ambient to near-black, and it
	is wrong: the player then cannot see the ground they are running on, and the
	game stops being tense and starts being unreadable. The rule used here is
	that unlit ground must be *navigable but useless* — you can see where your
	feet are, you cannot see a fuel cell twenty studs away. That is a low blue
	ambient with a hard fog wall, not black.
]]
local function defineLooks()
	Visual.defineLooks({
		outpost_night = {
			clockTime = 0.4,
			brightness = 1.05,
			--: Blue rather than grey. Grey night reads as fog at noon.
			ambient = Color3.fromRGB(21, 26, 41),
			outdoorAmbient = Color3.fromRGB(30, 38, 58),
			fogColor = Color3.fromRGB(9, 12, 22),
			fogStart = 60,
			--: The fog wall is the map boundary the player can see. Set beyond
			--: the last cell ring so the furthest run is still just possible.
			fogEnd = 430,
			environmentDiffuse = 0.35,
			environmentSpecular = 0.55,
			shadowSoftness = 0.6,
			geographicLatitude = 41,
			atmosphere = {
				density = 0.42,
				haze = 0.6,
				glare = 0.1,
				color = Color3.fromRGB(96, 116, 156),
				decay = Color3.fromRGB(24, 30, 48),
			},
			--[[
				Generous bloom, because every light source in this game is a
				gameplay signal and bloom is what makes one readable at 300 studs.

				The threshold is 1.6 and not the 1.05 it started at. At 1.05 any
				ordinary lit surface blooms, and standing on the generator pad —
				where four lamps of the inner ring overlap — turned the player
				into a white blob with a face somewhere in it. Neon parts and
				lamp bulbs are well above 1.6, so the far-away readability the
				low threshold was for survives it.
			]]
			bloom = { intensity = 1.15, size = 30, threshold = 1.6 },
			colorCorrection = {
				contrast = 0.16,
				saturation = 0.1,
				tint = Color3.fromRGB(226, 234, 255),
			},
		},

		--: Dawn. The payout has a sky behind it, which is most of why surviving
		--: the night feels like anything.
		outpost_dawn = {
			clockTime = 6.4,
			brightness = 2.2,
			ambient = Color3.fromRGB(88, 84, 96),
			outdoorAmbient = Color3.fromRGB(150, 142, 150),
			fogColor = Color3.fromRGB(214, 176, 152),
			fogStart = 160,
			fogEnd = 1400,
			environmentDiffuse = 0.6,
			environmentSpecular = 0.5,
			geographicLatitude = 41,
			atmosphere = {
				density = 0.3,
				haze = 1.6,
				glare = 0.5,
				color = Color3.fromRGB(244, 214, 190),
				decay = Color3.fromRGB(140, 120, 130),
			},
			bloom = { intensity = 0.8, size = 26, threshold = 1.4 },
			sunRays = { intensity = 0.14, spread = 0.9 },
			colorCorrection = { contrast = 0.08, saturation = 0.12, tint = Color3.fromRGB(255, 246, 236) },
		},
	})
end

-- =============================== terrain colour =============================
--[[
	Restain the terrain, dark and cool.

	The first build called `Material.palette("stylised")`, which is a good
	general-purpose palette and completely wrong here: it stains Ground to a
	warm sand, and the screenshot came back with the brightest thing on screen
	being the floor. In a game whose entire premise is that light is scarce, a
	ground that glows undoes the lighting, the lamps, the lantern and the fear
	all at once.

	These are the colours of rock at night. The lamps are then the only warm
	thing in the frame, which is the point.
]]
local function paintTerrain()
	Material.tintAll({
		[Enum.Material.Ground] = Color3.fromRGB(46, 48, 58),
		[Enum.Material.Rock] = Color3.fromRGB(58, 60, 70),
		[Enum.Material.Slate] = Color3.fromRGB(40, 43, 53),
		[Enum.Material.Sand] = Color3.fromRGB(54, 54, 62),
		[Enum.Material.Mud] = Color3.fromRGB(38, 38, 44),
		[Enum.Material.Concrete] = Color3.fromRGB(64, 66, 74),
	})
	Debug.info("terrain restained for night")
end

-- ================================= the floor ================================
local function layFloor()
	--[[
		A shallow basin with a raised rim.

		The rim is load-bearing for the fiction and for the level: it hides the
		terrain edge, it stops a player sprinting off the map into void, and it
		gives the far cells a silhouette to be found against.
	]]
	local field = World.heightfield({
		size = RADIUS * 2 + 60,
		seed = Config.seed,
		base = { { frequency = 0.0035, octaves = 3, weight = 1 } },
		range = { FLOOR_Y - 5, FLOOR_Y - 1 },
		features = {
			--: Flat where the outpost and the lamp rings are; a generator built
			--: on noise sits half in the ground.
			{ kind = "flat", center = Vector2.new(0, 0), radius = 190, height = FLOOR_Y - 2, blend = 1.5 },
			{ kind = "rim", center = Vector2.new(0, 0), radius = RADIUS, inner = RADIUS - 90, amount = 62, sharpness = 1.7 },
		},
		--: Above zero for the same reason the floor is. See the note on FLOOR_Y.
		floor = 4,
	})

	World.paint(field, {
		clear = true,
		chunk = 64,
		budgetMs = 10,
		material = function(_x, _z, height, slope)
			if height > FLOOR_Y + 10 then
				return Enum.Material.Rock
			end
			if slope > 0.7 then
				return Enum.Material.Slate
			end
			return Enum.Material.Ground
		end,
		onProgress = function(done, total)
			if done == total then
				Debug.info(string.format("basin written (%d chunks)", total))
			end
		end,
	})

	return field
end

-- ================================== spawn ===================================
--[[
	A real SpawnLocation, on measured ground.

	Positioning players by code leaves the place with no spawn as far as Roblox
	or any tool is concerned, and a spawn placed at a remembered height drops
	people through terrain that turned out to be higher there. So: measure, then
	place.
]]
local function placeSpawn(container: Instance)
	local x, z = 0, 26
	local ground = World.surface(x, z) or Vector3.new(x, FLOOR_Y, z)

	local pad = Instance.new("SpawnLocation")
	pad.Name = "OutpostSpawn"
	pad.Size = Vector3.new(14, 1, 14)
	pad.CFrame = CFrame.new(ground + Vector3.new(0, 0.5, 0))
	pad.Anchored = true
	pad.CanCollide = true
	pad.Neutral = true
	pad.Duration = 0
	pad.Color = Color3.fromRGB(180, 172, 154)
	pad.Material = Enum.Material.Concrete
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.Parent = container

	--: Players spawn inside the lit ring, so nobody's first two seconds of the
	--: game are spent taking damage from a mechanic nobody has explained yet.
	Mark.exclude(pad)
	Debug.info(string.format("spawn at %d, %d, %d", ground.X, ground.Y, ground.Z))
	return pad
end

-- ================================= scenery ==================================
--[[
	Rocks, scrub and dead trees between the lamp rings.

	Not decoration: an empty plain gives the eye nothing to judge distance or
	speed against, and the single most common reason a Roblox place reads as
	unfinished is that it is made of ground and nothing. These are baked store
	props — real geometry, rebuilt from data, no `InsertService` at runtime.

	Kept out of the inner 150 studs, where the outpost and the lamps are, and
	off the cell rings, where a prop would hide a fuel cell.
]]
local function scatterScenery(container: Instance)
	local placed = 0
	--: Deterministic: the same seed lays the same field every run, so a scene
	--: can be authored against and a bug can be reproduced.
	local rand = Random.new(Config.seed)

	local TOPICS = { "rock", "rock", "bush", "tree", "log", "barrel", "crate", "pipe" }

	for i = 1, 190 do
		local angle = rand:NextNumber() * math.pi * 2
		local radius = 150 + rand:NextNumber() ^ 0.7 * (RADIUS - 210)

		--: Keep a corridor clear on each cell ring so props never bury a cell.
		local blocked = false
		for _, ring in Config.cells.rings do
			if math.abs(radius - ring.radius) < 16 then
				blocked = true
				break
			end
		end
		if blocked then
			continue
		end

		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		local ground = World.surface(x, z)
		if not ground then
			continue
		end

		local topic = TOPICS[rand:NextInteger(1, #TOPICS)]
		local height
		if topic == "tree" then
			height = rand:NextNumber(9, 15)
		elseif topic == "rock" then
			height = rand:NextNumber(3, 8)
		elseif topic == "bush" then
			height = rand:NextNumber(1.6, 3)
		else
			height = rand:NextNumber(2, 3.6)
		end

		local solid = topic == "rock" or topic == "tree"
		local prop = Props.place(topic, i * 7919 + Config.seed, ground, {
			height = height,
			parent = container,
			--: Rocks and trees collide. A rock you can walk through is worse
			--: than no rock: it tells the player nothing here is solid.
			canCollide = solid,
			--: Scenery may sprawl a little; a wide flat rock is a rock.
			maxAspect = 3.5,
		})
		if prop then
			placed += 1
		end
	end

	Debug.info(string.format("scenery: %d props placed", placed))
	return placed
end

function Ground.start()
	--[[
		Spawned, not inline.

		The bootstrap starts systems in a loop and every other system here waits
		on `ground_ready`. If this one blocked the loop while the systems that
		wait on it had not started yet, the wait would be for a signal nobody
		was left running to send.
	]]
	task.spawn(function()
		defineLooks()
		paintTerrain()
		Visual.apply("outpost_night")

		local field = layFloor()
		Ground.field = field

		local props = Workspace:FindFirstChild("Props") or Workspace
		placeSpawn(props)
		scatterScenery(props)

		--: Everything downstream measures the ground it builds on. Nothing may
		--: place a lamp or a cell before the terrain those sit on exists.
		Boot.signal("ground_ready")
		Debug.info("ground ready")
	end)
end

return Ground
