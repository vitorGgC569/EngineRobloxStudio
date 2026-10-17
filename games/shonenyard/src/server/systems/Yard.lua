--!strict
--[[
	Yard — the dojo, as a place you can stand in.

	The first build of this game had systems that all worked and no world at
	all: a HUD floating over empty sky, and a player with nothing under their
	feet. Every scenario passed. The screenshot said the whole truth in one
	frame, which is why the screenshot is the criterion.

	Idempotent on purpose
	---------------------

	Everything here goes through `World.Builders`, which finds-or-creates. A
	world built by a script that runs twice must not be two worlds, and in
	Studio it runs twice constantly -- a rebuild, a rejoin, a hot reload. The
	alternative is a yard with two of every wall, discovered as a frame-rate
	problem an hour later.

	What is built, and why it is arranged this way
	---------------------------------------------

	A courtyard the player lands in the middle of, with the station pads on a
	visible ring around them. The ring matters: a tycoon whose next purchase is
	behind the player is a tycoon where the next purchase is invisible, and
	"nothing happens" is what that feels like from inside.

	Each pad carries its own prompt, so the whole game is reachable from the
	world rather than from a menu. `Loop.Hatch`'s dead-time rule is about
	exactly this -- ninety seconds with nothing to press is where players go.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local Builders = Forge.World.Builders
local Dress = require(script.Parent.Dress)

local Yard = {}

--: Where the yard is, and how big. One place, so the pads, the walls and the
--: spawn cannot drift apart.
local ORIGIN = Vector3.new(0, 8, 0)
local COURT = 96
--: Six and a half: below the eye line of a standing player.
--:
--: Fourteen made the yard a pit. Nine still hid it -- a screenshot from the
--: gate was one unbroken wall with the altar's tip over the top. A boundary
--: you cannot see over is a boundary that hides the game, and the game is the
--: reason somebody walked to the gate.
local WALL = 6.5

--: Muted stone and dark timber: the anime-dojo idiom is high contrast between
--: a plain ground and one saturated accent, which is what makes a banner read
--: from across the courtyard.
local STONE = { r = 0.61, g = 0.60, b = 0.58 }
local TIMBER = { r = 0.31, g = 0.19, b = 0.15 }
local ACCENT = { r = 0.78, g = 0.24, b = 0.30 }
local SAND = { r = 0.62, g = 0.57, b = 0.47 }

--: Rarity as a colour, so a mythic standing on a pad is visibly not a common
--: from across the courtyard. The same five the reveal card uses -- one
--: vocabulary, or the world and the interface disagree about what rare means.
local RARITY = {
	[1] = Color3.fromRGB(148, 152, 162),
	[2] = Color3.fromRGB(104, 190, 126),
	[3] = Color3.fromRGB(88, 158, 232),
	[4] = Color3.fromRGB(206, 142, 62),
	[5] = Color3.fromRGB(226, 88, 108),
}

local function place(parent: Instance, name: string, size: Vector3,
                    at: Vector3, colour: any, material: string?): BasePart
	local part = Builders.ensurePart(parent, {
		name = name,
		size = { x = size.X, y = size.Y, z = size.Z },
		position = { x = at.X, y = at.Y, z = at.Z },
		color = colour,
		material = material or "Slate",
		anchored = true,
	})
	return part :: any
end

-- ================================================================= the court

local function courtyard(root: Instance)
	--[[
		Ground, then floor.

		The first build was a ninety-six-stud box suspended in open sky, and
		from any angle outside it that is what it looked like -- a blockout,
		not a place. A wide, low apron underneath costs one part and gives the
		yard something to sit on, which is the whole difference between a
		courtyard and a platform.
	]]
	place(root, "Ground", Vector3.new(COURT * 3.2, 6, COURT * 3.2),
		ORIGIN - Vector3.new(0, 5, 0), { r = 0.30, g = 0.33, b = 0.26 }, "Grass")
	place(root, "Apron", Vector3.new(COURT + 34, 2, COURT + 34),
		ORIGIN - Vector3.new(0, 2.2, 0), { r = 0.36, g = 0.37, b = 0.39 }, "Cobblestone")

	--: The floor. Without it the player falls, and a falling player reads
	--: every other problem as this one.
	place(root, "Floor", Vector3.new(COURT, 2, COURT),
		ORIGIN - Vector3.new(0, 1, 0), STONE, "Slate")

	--: Raked sand inside the stone rim. Two materials rather than one, because
	--: a single flat plane is what an empty test map looks like.
	place(root, "Sand", Vector3.new(COURT - 18, 2.4, COURT - 18),
		ORIGIN - Vector3.new(0, 0.8, 0), SAND, "Sand")

	local half = COURT / 2

	--[[
		Three walls and an entrance, not four walls.

		This is the finding a screenshot made and nothing else could have. From
		the gate, at eye height, the whole frame was a wall: the courtyard hid
		behind its own boundary and the only thing visible over the top was the
		altar's neon tip. A walled yard on flat ground shows a wall from
		outside and walls from inside, and the game is in between.

		So the near wall has a gap the width of the gate, and the walls came
		down to eye height. Standing at the torii you now look *through* the
		opening at the altar, the pads and the rank stone -- which is the frame
		that says what this place is before any interface is read.
	]]
	local GAP = 30
	local shoulder = (COURT - GAP) / 2

	--: The far wall and the two sides, whole.
	place(root, "WallBack", Vector3.new(COURT, WALL, 2),
		ORIGIN + Vector3.new(0, WALL / 2, half), TIMBER, "WoodPlanks")
	place(root, "WallLeft", Vector3.new(2, WALL, COURT),
		ORIGIN + Vector3.new(-half, WALL / 2, 0), TIMBER, "WoodPlanks")
	place(root, "WallRight", Vector3.new(2, WALL, COURT),
		ORIGIN + Vector3.new(half, WALL / 2, 0), TIMBER, "WoodPlanks")

	--: The front, in two shoulders with the entrance between them.
	for index, side in { -1, 1 } do
		place(root, "WallFront" .. index, Vector3.new(shoulder, WALL, 2),
			ORIGIN + Vector3.new(side * (GAP + shoulder) / 2, WALL / 2, -half),
			TIMBER, "WoodPlanks")
		--: A post either side of the opening, so the gap reads as a doorway
		--: rather than as a wall somebody forgot to finish.
		place(root, "EntryPost" .. index, Vector3.new(2.6, WALL + 4, 2.6),
			ORIGIN + Vector3.new(side * GAP / 2, (WALL + 4) / 2, -half),
			ACCENT, "WoodPlanks")
	end

	--[[
		Banners down the side walls.

		Four dark rectangles is what an unfinished blockout looks like from
		inside. A vertical accent at intervals is the cheapest thing that makes
		a wall read as built rather than as a boundary -- and it is the anime
		dojo idiom, which is the point.
	]]
	for step = -2, 2 do
		local z = step * 18
		place(root, "BannerL" .. (step + 3), Vector3.new(0.6, 5.5, 4),
			ORIGIN + Vector3.new(-half + 1.6, WALL * 0.55, z), ACCENT, "Fabric")
		place(root, "BannerR" .. (step + 3), Vector3.new(0.6, 5.5, 4),
			ORIGIN + Vector3.new(half - 1.6, WALL * 0.55, z), ACCENT, "Fabric")
	end

	--: The gate. One saturated thing, placed where a player who spawns facing
	--: the middle sees it, so the courtyard has a front.
	--: A torii, sitting outside the wall rather than in it, and tall enough to
	--: be the silhouette this place is recognised by from a distance.
	local gateZ = -half - 14
	place(root, "GateLeft", Vector3.new(3.4, 30, 3.4),
		ORIGIN + Vector3.new(-13, 15, gateZ), ACCENT, "WoodPlanks")
	place(root, "GateRight", Vector3.new(3.4, 30, 3.4),
		ORIGIN + Vector3.new(13, 15, gateZ), ACCENT, "WoodPlanks")
	place(root, "GateBeam", Vector3.new(40, 3.2, 4.6),
		ORIGIN + Vector3.new(0, 31, gateZ), ACCENT, "WoodPlanks")
	place(root, "GateBeamUpper", Vector3.new(31, 2.2, 3.4),
		ORIGIN + Vector3.new(0, 35, gateZ), TIMBER, "WoodPlanks")
	place(root, "GateSill", Vector3.new(31, 1.6, 3),
		ORIGIN + Vector3.new(0, 26, gateZ), TIMBER, "WoodPlanks")
end

-- ================================================================== the pads

--[[
	One pad per station, on a ring the player is standing inside.

	The unbuilt ones are present and dark rather than absent. A tycoon where
	the next purchase does not exist yet has nothing to walk towards, and
	walking towards the next thing *is* the tycoon.
]]
function Yard.padPosition(index: number, total: number): Vector3
	local angle = (index - 1) / total * math.pi * 2 - math.pi / 2
	local radius = COURT * 0.32
	return ORIGIN + Vector3.new(math.cos(angle) * radius, 1.6,
		math.sin(angle) * radius)
end

local function pads(root: Instance): { [string]: BasePart }
	local built: { [string]: BasePart } = {}
	local total = #Content.stations
	for index, station in Content.stations do
		local at = Yard.padPosition(index, total)
		--: A rim under the pad, so it reads as a platform from a third-person
		--: camera rather than as a lighter square of floor.
		place(root, "Rim_" .. station.id, Vector3.new(17, 1.4, 17),
			at - Vector3.new(0, 1.0, 0), TIMBER, "WoodPlanks")
		local pad = place(root, "Pad_" .. station.id, Vector3.new(14, 1.2, 14),
			at + Vector3.new(0, 0.4, 0), STONE, "Concrete")

		--: A post so the pad reads from eye height. A flat square on the floor
		--: is invisible from a third-person camera, which is the only camera
		--: anybody plays this from.
		place(root, "Post_" .. station.id, Vector3.new(2, 9, 2),
			at + Vector3.new(0, 5, 0), TIMBER, "WoodPlanks")

		--[[
			Staggered, small, and near-sighted.

			The first build gave every pad a 220px sign at the same height with
			a 140-stud range, and the result was four of them piled at one
			screen height, overlapping each other and the altar: "Spi.. Forge",
			"Weigh. Rack", and the altar's own text through the middle of both.

			Three changes, each against one cause: alternating heights so
			neighbours never share a line, a shorter range so only what is
			near enough to walk to is drawn, and a smaller box so a sign is a
			label rather than a banner.
		]]
		local sign = Instance.new("BillboardGui")
		sign.Name = "Sign"
		sign.Size = UDim2.fromOffset(170, 46)
		sign.StudsOffset = Vector3.new(0, if index % 2 == 0 then 9.5 else 6.5, 0)
		sign.AlwaysOnTop = false
		--: Forty, not sixty-two. From across the courtyard four signs plus the
		--: altar's plus the rank stone's occupied one band of screen and read
		--: as a single illegible line. A sign is for a player who could walk
		--: over and press it.
		sign.MaxDistance = 40
		sign.Parent = pad

		local title = Instance.new("TextLabel")
		title.Size = UDim2.new(1, 0, 0.55, 0)
		title.BackgroundTransparency = 1
		title.Text = station.name
		title.TextScaled = true
		title.TextColor3 = Color3.fromRGB(240, 236, 230)
		title.Font = Enum.Font.GothamBold
		title.Parent = sign

		local price = Instance.new("TextLabel")
		price.Name = "Price"
		price.Size = UDim2.new(1, 0, 0.45, 0)
		price.Position = UDim2.fromScale(0, 0.55)
		price.BackgroundTransparency = 1
		price.Text = if station.cost > 0
			then string.format("%d ki  ·  rank %d", station.cost, station.tier)
			else "yours"
		price.TextScaled = true
		price.TextColor3 = Color3.fromRGB(198, 176, 120)
		price.Font = Enum.Font.Gotham
		price.Parent = sign

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "Buy"
		prompt.ActionText = if station.cost > 0 then "Build" else "Train here"
		prompt.ObjectText = station.name
		prompt.HoldDuration = 0.25
		prompt.MaxActivationDistance = 14
		prompt.RequiresLineOfSight = false
		prompt.Parent = pad

		built[station.id] = pad
	end
	return built
end

-- =============================================================== the altar

--[[
	The summon altar: the one thing in the middle.

	The loop's button is on the HUD, and it is also here, because a player who
	has not found the HUD yet is standing next to the thing the game is about.
]]
local function altar(root: Instance): BasePart
	--[[
		Raised, tiered and lit.

		The first build put a neon slab at floor height, and from a
		third-person camera it read as a red patch of ground rather than as
		the thing the game is about. A courtyard needs one object taller than
		a player standing in it, or the eye has nowhere to go.
	]]
	place(root, "AltarBase", Vector3.new(18, 1.6, 18),
		ORIGIN + Vector3.new(0, 0.8, 0), STONE, "Marble")
	place(root, "AltarStep", Vector3.new(13, 1.6, 13),
		ORIGIN + Vector3.new(0, 2.4, 0), STONE, "Marble")
	local base = place(root, "Altar", Vector3.new(9, 4, 9),
		ORIGIN + Vector3.new(0, 5.2, 0), TIMBER, "WoodPlanks")
	--: A pillar that clears the wall line. The eye needs one thing taller than
	--: everything around it, and at seven studs inside a nine-stud wall this
	--: was not it.
	local core = place(root, "AltarTop", Vector3.new(3.4, 16, 3.4),
		ORIGIN + Vector3.new(0, 15, 0), ACCENT, "Neon")
	place(root, "AltarCap", Vector3.new(6.5, 1.4, 6.5),
		ORIGIN + Vector3.new(0, 23.4, 0), TIMBER, "WoodPlanks")

	--: One warm light in the middle of a stone courtyard. Without it the whole
	--: yard is lit by one sun at one angle and every surface is the same value.
	local glow = Instance.new("PointLight")
	glow.Name = "AltarGlow"
	--: Brightness 1.1, not 3.2.
	--:
	--: At 3.2 with a 46-stud range, plus six lanterns at 2.2, the courtyard's
	--: sand, walls and every fighter on it came out the same salmon. A warm
	--: light in a stone yard is an accent; at that strength it was the yard's
	--: colour, and rarity -- which is *read as colour* -- stopped reading.
	glow.Color = Color3.fromRGB(255, 168, 138)
	glow.Brightness = 1.1
	glow.Range = 30
	glow.Parent = core

	local sign = Instance.new("BillboardGui")
	sign.Name = "Sign"
	sign.Size = UDim2.fromOffset(260, 54)
	sign.StudsOffset = Vector3.new(0, 6, 0)
	sign.MaxDistance = 48
	sign.Parent = base

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "UNSEAL A SCROLL"
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(244, 226, 210)
	label.Font = Enum.Font.GothamBold
	label.Parent = sign

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Summon"
	prompt.ActionText = "Unseal"
	prompt.ObjectText = "Scroll Altar"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = base

	return base
end

-- =============================================================== the ledger

--[[
	The rank stone: what the dojo is called, and what the next rank costs.

	A tycoon's ladder is invisible unless something in the world states it. A
	number that only exists in a HUD corner is a number players do not plan
	against.
]]
local function rankStone(root: Instance): BasePart
	local half = COURT / 2
	local stone = place(root, "RankStone", Vector3.new(12, 10, 3),
		ORIGIN + Vector3.new(0, 5, half - 8), STONE, "Marble")

	local sign = Instance.new("BillboardGui")
	sign.Name = "Sign"
	sign.Size = UDim2.fromOffset(280, 76)
	sign.StudsOffset = Vector3.new(0, 7, 0)
	sign.MaxDistance = 48
	sign.Parent = stone

	local title = Instance.new("TextLabel")
	title.Name = "Rank"
	title.Size = UDim2.new(1, 0, 0.5, 0)
	title.BackgroundTransparency = 1
	title.Text = Content.ranks[1].name
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(240, 236, 230)
	title.Font = Enum.Font.GothamBold
	title.Parent = sign

	local next_ = Instance.new("TextLabel")
	next_.Name = "Next"
	next_.Size = UDim2.new(1, 0, 0.5, 0)
	next_.Position = UDim2.fromScale(0, 0.5)
	next_.BackgroundTransparency = 1
	next_.Text = string.format("next: %s  ·  %d ki",
		Content.ranks[2].name, Content.ranks[2].cost)
	next_.TextScaled = true
	next_.TextColor3 = Color3.fromRGB(198, 176, 120)
	next_.Font = Enum.Font.Gotham
	next_.Parent = sign

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Promote"
	prompt.ActionText = "Raise the dojo"
	prompt.ObjectText = "Rank Stone"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = stone

	return stone
end

-- =================================================================== build

export type Built = {
	root: Folder,
	pads: { [string]: BasePart },
	altar: BasePart,
	rankStone: BasePart,
	spawn: CFrame,
}

function Yard.build(): Built
	local root = Builders.ensureFolder(Workspace, "Yard") :: Folder

	courtyard(root)
	local built = pads(root)
	local summonAltar = altar(root)
	local stone = rankStone(root)

	--[[
		Dressed after the structure, not instead of it.

		The blockout stays: it is what the prompts sit on, what a player walks
		into, and what is standing when an asset does not arrive. The models go
		on top. Doing it the other way -- geometry conditional on a network
		call -- is how a game becomes an empty plot on a bad connection.
	]]
	Dress.surroundings(root, ORIGIN, COURT)
	Dress.clutter(root, ORIGIN, COURT)
	Dress.lanterns(root, ORIGIN, COURT)
	Dress.altar(root, ORIGIN + Vector3.new(0, 8.5, 0))

	--[[
		The spawn is at the gate, not on the altar.

		The first build put it at the middle and the player materialised inside
		the summon altar -- standing in the one object the courtyard is built
		around, with its glow through their head, unable to see the thing they
		were standing on.

		At the gate they arrive outside the yard looking in, which is the frame
		that says what this place is before a word of interface is read.
	]]
	--[[
		Outside the gate, so arriving is walking in.

		Two wrong answers came before this one, and each was found by standing
		in it rather than by reading the code:

		  * at the middle, the player materialised *inside* the summon altar;
		  * at `-COURT/2 + 26`, they landed on the first station pad -- eight
		    studs from it, with its prompt already on screen and the courtyard
		    behind their shoulder.

		Outside the entrance they arrive facing the torii, walk through it, and
		the yard opens up. That walk is the first thirty seconds of this game
		and it is the only part no interface can do.
	]]
	local spawnPart = place(root, "Spawn", Vector3.new(14, 1, 14),
		ORIGIN + Vector3.new(0, 0.6, -COURT / 2 - 30), STONE, "Cobblestone")
	--[[
		Oriented, not just positioned.

		A `SpawnLocation` faces wherever its CFrame points, and a part created
		with only a `Position` points down -Z by default. With the spawn moved
		outside the gate that meant the player arrived with their back to the
		dojo, looking at empty grass -- the arrival moment, aimed at nothing.

		Setting the CFrame to look at the courtyard is the whole fix, and it is
		invisible in every check except standing there.
	]]
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "DojoSpawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.lookAt(
		spawnPart.Position + Vector3.new(0, 1.2, 0),
		Vector3.new(ORIGIN.X, spawnPart.Position.Y + 1.2, ORIGIN.Z))
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Transparency = 1
	spawn.Parent = root

	return {
		root = root,
		pads = built,
		altar = summonAltar,
		rankStone = stone,
		spawn = CFrame.new(spawn.Position),
	}
end

--[[
	Put the fighters on the pads, so the collection exists in the world.

	The first playable build had a roster that existed as a number in a HUD
	corner and nowhere else: you summoned a Mountain Sage, the counter went
	from 3 to 4, and the yard looked exactly the same. A tycoon where what you
	collect never appears is a spreadsheet with a camera in it.

	Built as simple figures rather than as rigs on purpose. A rig costs a
	Humanoid, an animator and a physics body per fighter, and a yard with
	twenty of them is a frame-rate problem; a lit block with the fighter's
	rarity colour and its name over it reads at ten metres, which is the range
	this ever gets looked at from.
]]
local FIGHTER_HEIGHT = 5.4

function Yard.showFighters(built: Built, stationId: string, fighterIds: { string })
	local pad = built.pads[stationId]
	if pad == nil then
		return
	end
	local holder = pad:FindFirstChild("Trainees")
	if holder == nil then
		holder = Instance.new("Folder")
		holder.Name = "Trainees"
		holder.Parent = pad
	end
	holder:ClearAllChildren()

	local station = Content.station(stationId)
	local slots = station and station.slots or #fighterIds
	for index, fighterId in fighterIds do
		local fighter = Content.fighter(fighterId)
		if fighter == nil then
			continue
		end

		--[[
			In front of the post, spread across the pad.

			Placed at the pad's centre they stood *inside* the nine-stud post
			that marks it -- two figures with a timber column through them,
			which from any angle reads as one broken object rather than as two
			fighters training.

			The offset is toward the courtyard's middle, so a player walking the
			ring sees faces rather than backs.
		]]
		local spread = (index - (slots + 1) / 2) * (11 / math.max(slots, 1))
		local inward = (ORIGIN - pad.Position) * Vector3.new(1, 0, 1)
		local facing = if inward.Magnitude > 0.1 then inward.Unit else Vector3.new(0, 0, 1)
		local sideways = Vector3.new(-facing.Z, 0, facing.X)
		local at = pad.Position
			+ sideways * spread
			+ facing * 4.2
			+ Vector3.new(0, FIGHTER_HEIGHT / 2 + 1, 0)

		--[[
			A real armour stand if one arrives, the block if it does not.

			`InsertService:LoadAsset` is a network call. Making the trainee
			*conditional* on it would mean a yard that empties itself when
			Roblox has a bad minute, which is worse than a coloured block --
			the block at least says somebody is training there.
		]]
		local dressed = Dress.trainee(holder, at, fighterId, facing)

		local body = Instance.new("Part")
		body.Name = "Trainee" .. index
		body.Size = Vector3.new(1.8, FIGHTER_HEIGHT, 1.2)
		body.Position = at
		body.Anchored = true
		body.CanCollide = false
		body.Material = Enum.Material.SmoothPlastic
		body.Color = RARITY[fighter.rarity] or RARITY[1]
		--: Kept as a plinth under a dressed trainee, so a mythic still has the
		--: rarity colour at its feet, and as the whole figure when nothing
		--: landed.
		body.Size = if dressed then Vector3.new(3.2, 0.6, 3.2) else body.Size
		body.Position = if dressed then at - Vector3.new(0, FIGHTER_HEIGHT / 2, 0)
			else body.Position
		body.Parent = holder

		--: A head, because a featureless column is a bollard. Two parts is the
		--: cheapest thing that reads as somebody standing there.
		local head = if dressed then nil else Instance.new("Part")
		if head ~= nil then
		head.Name = "Head"
		head.Shape = Enum.PartType.Ball
		head.Size = Vector3.new(1.5, 1.5, 1.5)
		head.Position = at + Vector3.new(0, FIGHTER_HEIGHT / 2 + 0.7, 0)
		head.Anchored = true
		head.CanCollide = false
		head.Material = Enum.Material.SmoothPlastic
		head.Color = Color3.fromRGB(232, 206, 178)
		head.Parent = holder
		end

		--: A rare trainee is worth seeing from across the yard.
		if fighter.rarity >= 3 then
			local aura = Instance.new("PointLight")
			aura.Color = body.Color
			aura.Brightness = 1.4 + fighter.rarity * 0.4
			aura.Range = 10 + fighter.rarity * 3
			aura.Parent = body
		end

		local tag = Instance.new("BillboardGui")
		tag.Size = UDim2.fromOffset(120, 20)
		tag.StudsOffset = Vector3.new(0, FIGHTER_HEIGHT / 2 + 2.2, 0)
		tag.MaxDistance = 34
		tag.Parent = body

		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = fighter.name
		label.TextScaled = true
		label.TextColor3 = body.Color
		label.Font = Enum.Font.GothamMedium
		label.Parent = tag
	end
end

--: Repaint a pad once its station is built, so the world shows the state
--: rather than the HUD having to describe it.
function Yard.markBuilt(built: Built, stationId: string)
	local pad = built.pads[stationId]
	if pad == nil then
		return
	end
	--: Warm stone, not the accent.
	--:
	--: Painting a built pad the full accent turned it into a saturated red
	--: square that reads as an error state rather than as progress. The accent
	--: is for the gate, the banners and the altar -- three things. A fourth
	--: makes it the yard's colour instead of its emphasis.
	pad.Color = Color3.fromRGB(196, 168, 128)
	pad.Material = Enum.Material.Sandstone
	local sign = pad:FindFirstChild("Sign")
	local price = sign and sign:FindFirstChild("Price")
	if price and price:IsA("TextLabel") then
		price.Text = "built"
	end
	local prompt = pad:FindFirstChild("Buy")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.ActionText = "Train here"
	end
end

--: Keep the rank stone honest. A sign that states last week's rank is worse
--: than no sign.
function Yard.updateRank(built: Built, rank: number)
	local sign = built.rankStone:FindFirstChild("Sign")
	if sign == nil then
		return
	end
	local title = sign:FindFirstChild("Rank")
	if title and title:IsA("TextLabel") then
		title.Text = Content.ranks[rank].name
	end
	local next_ = sign:FindFirstChild("Next")
	if next_ and next_:IsA("TextLabel") then
		local upcoming = Content.ranks[rank + 1]
		next_.Text = if upcoming
			then string.format("next: %s  ·  %d ki", upcoming.name, upcoming.cost)
			else "sovereign"
	end
end

return Yard
