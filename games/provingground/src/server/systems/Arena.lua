--!strict
--[[
	Arena — the ground this game is fought on.

	Every line here is a decision about *this* game. The engine supplied the
	heightfield, the painter and the scatter; what a bowl-shaped arena ringed
	by cliffs means is not something Forge knows or should.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local World = Forge.World
local Rng = Forge.Core.Rng
local Debug = Forge.Debug
local Catalog = Forge.Catalog
local Material = Forge.Material
local Mark = Forge.Mark
local Nav = Forge.Nav

local Arena = {}

--[[
	The names the Quality Engine's visual spec looks for.

	Declared here and generated into the spec by `forge quality`, so the game
	and the contract cannot disagree about what the landmark is called. A
	mismatch is silent on both sides: the spec finds nothing and the game
	marks something nobody asked about.
]]
local LANDMARK = "arena-ring"
local REGION_PROFILE = "arena"

Arena.field = nil
Arena.spawnPoint = Vector3.new(0, 40, 0)
Arena.radius = 190

local MATERIALS = {
	floor = Enum.Material.Ground,
	path = Enum.Material.Slate,
	wall = Enum.Material.Rock,
	high = Enum.Material.Basalt,
}

function Arena.start()
	local t0 = os.clock()

	-- A bowl: flat in the middle, walls rising at the rim. One `flat` feature
	-- and one inverted ring is the whole shape.
	local field = World.heightfield({
		size = 520,
		seed = Rng.masterSeed(),
		base = {
			{ frequency = 0.006, octaves = 4, weight = 0.7 },
			{ frequency = 0.03, octaves = 3, weight = 0.3 },
		},
		range = { 26, 44 },
		features = {
			-- Order matters: floor first, then the wall that rings it.
			-- `rim` and not `mound` — a mound peaks at the centre, which turns
			-- the arena into a hill. That mistake shipped once and was only
			-- visible in a screenshot.
			{ kind = "flat", center = Vector2.new(0, 0), radius = 130, height = 32, blend = 1.3 },
			{ kind = "rim", center = Vector2.new(0, 0), radius = 250, inner = 108, amount = 82, sharpness = 2.1 },
			-- low cover inside the ring, so the floor is not a featureless disc
			{ kind = "mound", center = Vector2.new(64, -44), radius = 30, amount = 9, sharpness = 2 },
			{ kind = "mound", center = Vector2.new(-72, 56), radius = 34, amount = 12, sharpness = 2 },
			{ kind = "basin", center = Vector2.new(-30, -70), radius = 26, amount = 5, sharpness = 2 },
		},
		floor = 10,
	})
	Arena.field = field

	World.paint(field, {
		clear = true,
		seaLevel = 14,
		chunk = 64,
		budgetMs = 10,
		-- Material by position, not by height. Keying the fighting ring off a
		-- height band looked right in the table and painted the entire floor
		-- one flat colour in the game, because the floor is a plateau at
		-- exactly that height. Distance from the centre is what actually
		-- describes "the ring you fight in".
		material = function(x, z, height, slope)
			if slope < 0.55 then
				return MATERIALS.wall
			end
			if height > 78 then
				return MATERIALS.high
			end
			if height > 46 then
				return MATERIALS.wall
			end

			local distance = math.sqrt(x * x + z * z)
			if distance < 34 then
				return MATERIALS.path -- the duelling circle, visibly different
			end
			if distance > 104 then
				return Enum.Material.Sand -- the run-up to the wall
			end
			return MATERIALS.floor
		end,
		onProgress = function(done, total)
			if done == total then
				Debug.info(string.format("arena terrain written (%d chunks)", total))
			end
		end,
	})

	local props = Workspace:FindFirstChild("Props") :: Folder

	-- Rocks: cover, and something for the eye to measure distance against.
	local placed = World.scatter(field, {
		id = "arena.rocks",
		step = 16,
		budget = 220,
		density = function(x, z, height, slope)
			-- inside the ring only. Rocks on the wall read as visual noise and
			-- cost part budget for scenery nobody walks past.
			if math.sqrt(x * x + z * z) > 116 then
				return 0
			end
			if height < 30 or height > 40 or slope < 0.8 then
				return 0
			end
			return 0.3
		end,
		--[[
			Scenery, from the verified catalogue.

			These used to be three boxes each, rotated randomly and tinted
			grey. They read as three boxes, because that is what they were —
			and no amount of lighting work fixes a silhouette.

			`Catalog` holds two hundred pieces that were pulled out of Synty
			packs Roblox released free, loaded inside Studio, measured and
			scanned for scripts before they earned an entry. Using them is the
			single largest visual change available to this game and it costs a
			lookup.

			The hand-built rock stays as the fallback. A catalogue miss must
			not produce an empty arena: a world with worse rocks is a world, a
			world with no rocks is a bug.
		]]
		place = function(position, stream)
			local pieces = Catalog.byCategory("ground")
			if #pieces > 0 then
				local entry = pieces[stream:int(1, #pieces)]
				local model = Catalog.load(entry)
				if model then
					model.Name = "Rock"
					if model:IsA("Model") then
						model:PivotTo(CFrame.new(position + Vector3.new(0, entry.size.Y * 0.3, 0))
							* CFrame.Angles(0, stream:number(0, 6.28), 0))
					elseif model:IsA("BasePart") then
						(model :: BasePart).CFrame = CFrame.new(position)
							* CFrame.Angles(0, stream:number(0, 6.28), 0)
					end
					for _, d in model:GetDescendants() do
						if d:IsA("BasePart") then
							d.Anchored = true
						end
					end
					if model:IsA("BasePart") then
						(model :: BasePart).Anchored = true
					end
					-- Distance fidelity and no shadows on the small stuff:
					-- a field of scattered props each casting a shadow is a
					-- measurable share of a frame for detail nobody sees.
					Material.renderFidelity(model, Enum.RenderFidelity.Automatic)
					Material.shadowBudget(model, 3)
					-- Parent, do not return. `World.scatter` expects the
					-- callback to place the thing; a returned model is an
					-- orphan that exists in memory and in no world.
					model.Parent = props
					return
				end
			end

			-- Fallback: the original boxes.
			local model = Instance.new("Model")
			model.Name = "Rock"
			local chunks = stream:int(1, 3)
			for i = 1, chunks do
				local size = stream:number(2.5, 7.5) / i
				local part = Instance.new("Part")
				part.Size = Vector3.new(size * stream:number(0.8, 1.5), size, size * stream:number(0.8, 1.5))
				part.CFrame = CFrame.new(position + Vector3.new(stream:number(-3, 3), size * 0.28, stream:number(-3, 3)))
					* CFrame.Angles(stream:number(0, 1), stream:number(0, 6.28), stream:number(0, 1))
				part.Color = Color3.fromRGB(104, 100, 96):Lerp(Color3.new(0, 0, 0), stream:number(0, 0.25))
				part.Material = Enum.Material.Slate
				part.Anchored = true
				part.TopSurface = Enum.SurfaceType.Smooth
				part.BottomSurface = Enum.SurfaceType.Smooth
				part.Parent = model
			end
			model.Parent = props
		end,
	})

	--[[
		Planting, from the same verified catalogue.

		Rocks alone gave the arena something to measure distance against and
		left it looking like a quarry. Foliage is what makes ground read as
		ground: a Synty bush is a textured MeshPart, so this costs no upload,
		no texture authoring and no invented asset id — the pieces were loaded,
		measured and scanned before they were written into the catalogue.

		Kept to the outer band and off the fighting floor. Scenery a player
		walks through is scenery that hides an enemy, and this game's whole
		loop is seeing an attack coming.
	]]
	local planted = 0
	do
		local foliage = Catalog.byCategory("foliage")
		if #foliage > 0 then
			planted = World.scatter(field, {
				id = "arena.foliage",
				step = 14,
				budget = 260,
				density = function(x, z, height, slope)
					local distance = math.sqrt(x * x + z * z)
					-- Between the fighting floor and the wall.
					if distance < 96 or distance > 150 then
						return 0
					end
					if slope < 0.7 then
						return 0
					end
					return 0.55
				end,
				place = function(position, stream)
					local entry = foliage[stream:int(1, #foliage)]
					local model = Catalog.load(entry)
					if not model then
						return
					end
					model.Name = "Foliage"
					local turn = CFrame.Angles(0, stream:number(0, 6.28), 0)
					if model:IsA("Model") then
						model:PivotTo(CFrame.new(position) * turn)
					elseif model:IsA("BasePart") then
						(model :: BasePart).CFrame = CFrame.new(position) * turn
					end
					for _, d in model:GetDescendants() do
						if d:IsA("BasePart") then
							d.Anchored = true
							-- Plants are not cover and must not block a path;
							-- an enemy pathing around a fern reads as a bug.
							d.CanCollide = false
						end
					end
					if model:IsA("BasePart") then
						(model :: BasePart).Anchored = true
						;(model :: BasePart).CanCollide = false
					end
					Material.renderFidelity(model, Enum.RenderFidelity.Automatic)
					Material.shadowBudget(model, 4)
					model.Parent = props
				end,
			})
		end
	end

	--[[
		Braziers mark the fighting ring.

		A readable boundary beats an invisible wall: the player learns where
		the arena ends by seeing it, not by walking into something.

		Restored after an over-wide edit removed them along with the rock
		placement it was meant to change. Worth naming, because the world
		looked merely emptier rather than broken, and an absence is the hardest
		kind of regression to notice.
	]]
	for i = 1, 8 do
		local angle = (i / 8) * math.pi * 2
		local x, z = math.cos(angle) * 96, math.sin(angle) * 96
		local ground = World.surface(x, z) or Vector3.new(x, 32, z)

		local post = Instance.new("Part")
		post.Name = "Brazier"
		post.Size = Vector3.new(1.2, 9, 1.2)
		post.CFrame = CFrame.new(ground + Vector3.new(0, 4.5, 0))
		post.Color = Color3.fromRGB(58, 52, 48)
		post.Material = Enum.Material.Metal
		post.Anchored = true
		post.Parent = props

		local flame = Instance.new("Part")
		flame.Name = "Flame"
		flame.Size = Vector3.new(2.2, 2.2, 2.2)
		flame.Shape = Enum.PartType.Ball
		flame.CFrame = CFrame.new(ground + Vector3.new(0, 9.6, 0))
		flame.Color = Color3.fromRGB(255, 148, 62)
		flame.Material = Enum.Material.Neon
		flame.Anchored = true
		flame.CanCollide = false
		flame.Parent = props

		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 160, 80)
		light.Range = 42
		light.Brightness = 2.4
		light.Parent = flame
	end

	local spawn = World.surface(0, 0)
	Arena.spawnPoint = (spawn or Vector3.new(0, 34, 0)) + Vector3.new(0, 4, 0)

	Arena.placeSpawn(props)
	Arena.markForReview(props)

	Debug.probe("arena", function()
		return {
			radius = Arena.radius,
			props = #props:GetChildren(),
			plants = planted,
			spawnPoint = { Arena.spawnPoint.X, Arena.spawnPoint.Y, Arena.spawnPoint.Z },
			seed = Rng.masterSeed(),
		}
	end)

	Debug.info(string.format("arena ready in %.1fs (%d rocks, %d plants)", os.clock() - t0, placed, planted))
end

--[[
	A real SpawnLocation, on the ground the fight happens on.

	This game placed players by code — `PivotTo` on the character, at a point
	the arena computed — and never created one. It works, and it is invisible
	to everything that is not this game: Roblox itself, any validator, and any
	tool that asks where a player enters. The release run measured zero spawns
	and could say nothing at all about navigation as a result, because "can a
	player reach the objective" has no meaning without a place they start.

	Neutral team and no forcefield: this is an arena, and a spawn that hands
	out ten seconds of invulnerability is a spawn people camp.
]]
function Arena.placeSpawn(parent: Instance)
	local existing = parent:FindFirstChild("ArenaSpawn")
	if existing then
		existing:Destroy()
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ArenaSpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	-- Sunk half a stud so it reads as part of the floor rather than a slab
	-- dropped on top of it.
	spawn.CFrame = CFrame.new(Arena.spawnPoint - Vector3.new(0, 4.5, 0))
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Color = Color3.fromRGB(196, 202, 214)
	spawn.Material = Enum.Material.Slate
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = parent

	Debug.info(string.format("spawn placed at %d, %d, %d",
		Arena.spawnPoint.X, Arena.spawnPoint.Y, Arena.spawnPoint.Z))
	return spawn
end

--[[
	Say what this world is, so it can be looked at.

	The Quality Engine measures composition, palette and whether the subject of
	a scene stays visible — and it finds all of that by tag. An untagged world
	is not a world that scores badly; it is a world the validator reports as
	containing nothing to look at, which is indistinguishable from an empty
	place. Every Forge game was in that state until this ran.

	Three things have to be said, and only three:

	  what the eye lands on   the ring of braziers, which the game already
	                          builds to mark the fighting boundary
	  where the play happens  the floor inside that ring
	  what is scenery         the rocks and the planting

	Nothing here changes how anything looks. It is all labels, and one
	invisible part that exists so a region has an instance to be.
]]
function Arena.markForReview(props: Instance)
	--[[
		The braziers, gathered into the thing they already were.

		Eight separate posts are eight props; the ring they describe is the
		landmark, and a landmark has to be one instance for the camera to be
		pointed at it. Reparenting rather than rebuilding, so the world on
		screen is identical to the world before this function existed.
	]]
	local ring = Instance.new("Model")
	ring.Name = "ArenaRing"
	for _, child in props:GetChildren() do
		if child.Name == "Brazier" or child.Name == "Flame" then
			child.Parent = ring
		end
	end
	ring.Parent = props

	if #ring:GetChildren() > 0 then
		Mark.landmark(ring, LANDMARK)
		Mark.ringAnchors(ring, LANDMARK, 8, Arena.radius * 0.75)
	end

	--[[
		The fighting floor, as an instance.

		The floor is terrain, and terrain cannot carry a tag. A region needs
		something to be, so this is an invisible, non-colliding slab over the
		ground the fight happens on — apparatus rather than scenery, and
		excluded from classification for exactly that reason.
	]]
	local floor = Instance.new("Part")
	floor.Name = "ArenaFloorRegion"
	floor.Size = Vector3.new(Arena.radius * 2, 1, Arena.radius * 2)
	floor.CFrame = CFrame.new(Arena.spawnPoint - Vector3.new(0, 4, 0))
	floor.Transparency = 1
	floor.CanCollide = false
	floor.CanQuery = false
	floor.CanTouch = false
	floor.Anchored = true
	floor.Parent = props
	Mark.region(floor, REGION_PROFILE)
	Mark.exclude(floor)

	local rocks, plants = 0, 0
	for _, child in props:GetChildren() do
		if child == ring or child == floor then
			continue
		end
		if child:IsA("SpawnLocation") then
			-- Functional, not scenery. Counted as a prop it would move every
			-- density number the visual spec computes, and the spawn is the
			-- one part of this world that is there for a rule rather than a
			-- picture.
			Mark.exclude(child)
			continue
		end
		if child.Name == "Rock" then
			Mark.root(child, "rock")
			rocks += 1
		elseif child:IsA("Model") or child:IsA("BasePart") then
			Mark.root(child, "plant")
			plants += 1
		end
	end

	Debug.probe("marks", function()
		return Mark.describe()
	end)
	Debug.info(string.format(
		"marked for review: %d rocks, %d plants, 1 landmark, 1 region", rocks, plants))
end

-- Somewhere standable, at least `minDistance` from the centre.
function Arena.pointInRing(minDistance: number, maxDistance: number): Vector3?
	local stream = Rng.stream("arena.spawns")
	for _ = 1, 16 do
		local angle = stream:number(0, math.pi * 2)
		local dist = stream:number(minDistance, maxDistance)
		local x, z = math.cos(angle) * dist, math.sin(angle) * dist
		local point = World.surface(x, z)
		if point and Arena.field and Arena.field:slope(x, z) > 0.75 then
			return point + Vector3.new(0, 3, 0)
		end
	end
	return nil
end

return Arena
