--!strict
-- Playable: the loop, standing in the world.
--
-- Systems that exist and a world nobody can act on is not a game. This is the
-- shortest honest path between them: something to press, a cost to pay, a thing
-- that appears, and a number that changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local WorldKit = require(ReplicatedStorage.WorldKit)
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local Catalogue = require(ReplicatedStorage.Shared.Catalogue)
local tokens = WorldKit.Tokens.define(TokenData)

-- The same style the world is built from, so a tower the player raises
-- belongs to the place rather than being dropped onto it.
local STYLE = {
	wall = "stonePrimary",
	trim = "stoneSecondary",
	roof = "structureSecondary",
	accent = "accentGold",
}

local Playable = {}

--- Build the loop into the world, driven by the systems already constructed.
function Playable.build(Gameplay)
local systems = Gameplay.systems()

-- Waited for, not assumed. Server Scripts have no guaranteed order, and this
-- one lost the race to the world builder every time -- refusing correctly, for
-- a world that appeared a frame later. Bounded, because waiting forever for
-- something that will never arrive is the same bug with no error message.
local world = nil
local deadline = os.clock() + 10
repeat
	-- By prefix, because the suffix is not ours to predict: a game with no
	-- designed layout gets `Blockout_<id>-synthetic` instead of `-world`,
	-- and the exact-name lookup here matched only the one game that had a
	-- real layout. Nineteen of twenty corpus briefs shipped with no pads,
	-- no objective and no prompts because of this line.
	for _, child in ipairs(workspace:GetChildren()) do
		if string.sub(child.Name, 1, 9) == "Blockout_" then
			world = child
			break
		end
	end
	world = world or workspace:FindFirstChild("World")
	if world == nil then
		task.wait(0.1)
	end
until world ~= nil or os.clock() > deadline

if world == nil then
	-- Refused rather than guessed. Building the loop into a world that is not
	-- there produces prompts floating at the origin, which reads as broken
	-- rather than as absent.
	error("[Playable] no world to build the loop into", 0)
end

local stage = Instance.new("Folder")
stage.Name = "Playable"
stage.Parent = world

--- Where a region actually is, so props stand on the layout rather than beside
--- it. Regions are Models when the blockout built them and Parts otherwise.
local function regionPivot(name: string): CFrame?
	for _, child in ipairs(world:GetChildren()) do
		if child.Name == "Region_" .. name or child.Name == name then
			if child:IsA("Model") then
				return child:GetPivot()
			elseif child:IsA("BasePart") then
				return child.CFrame
			end
		end
	end
	return nil
end

-- The buildable slots, drawn from the layout rather than from coordinates
-- chosen here: a plot the grammar moved takes its slots with it.
local slots: { CFrame } = {}
for _, regionName in ipairs({ "build_west", "build_east", "arena", "staging" }) do
	local pivot = regionPivot(regionName)
	if pivot ~= nil then
		for index = -1, 1 do
			table.insert(slots, pivot * CFrame.new(index * 14, 0, 0))
		end
	end
end
if #slots == 0 then
	table.insert(slots, CFrame.new(0, 0, 0))
end

--- One buildable pad: a plinth, a prompt, and the cost the catalogue set.
local function pad(index: number, at: CFrame, entry: { [string]: any })
	local price = math.max(math.floor((entry.power or 10) * 5), 1)

	-- A prepared foundation, not a marker. A pad that looks like a debug plate
	-- reads as a debug plate however well it works, and "where can I build" is
	-- the first question a tower defense has to answer without words.
	local plinth = Instance.new("Part")
	plinth.Name = "Pad_" .. index
	plinth.Anchored = true
	plinth.Size = Vector3.new(11, 1.4, 11)
	plinth.CFrame = at * CFrame.new(0, 0.7, 0)
	plinth.Color = tokens:color("stoneSecondary")
	plinth.Material = Enum.Material.Cobblestone
	plinth.TopSurface = Enum.SurfaceType.Smooth
	plinth.Parent = stage

	local deck = Instance.new("Part")
	deck.Name = "Deck"
	deck.Anchored = true
	deck.Size = Vector3.new(8.5, 0.5, 8.5)
	deck.CFrame = plinth.CFrame * CFrame.new(0, 0.95, 0)
	deck.Color = tokens:color("stonePrimary")
	deck.Material = Enum.Material.Slate
	deck.Parent = plinth

	-- Corner posts: the cue that this is a site under construction rather than
	-- a painted square, and the outline that survives at distance.
	for _, corner in ipairs({
		Vector3.new(1, 0, 1), Vector3.new(-1, 0, 1),
		Vector3.new(1, 0, -1), Vector3.new(-1, 0, -1),
	}) do
		local post = Instance.new("Part")
		post.Name = "Post"
		post.Anchored = true
		post.Size = Vector3.new(1, 4, 1)
		post.CFrame = plinth.CFrame * CFrame.new(corner.X * 4.6, 2.6, corner.Z * 4.6)
		post.Color = tokens:color("woodSecondary")
		post.Material = Enum.Material.Wood
		post.Parent = plinth
	end

	-- Seated in a socket, not floating over the deck.
	--
	-- The version this replaces hung a 1.4-stud Neon ball 4.6 studs above the
	-- plinth with nothing holding it up, and under bloom it flared into a square
	-- of light -- which is what a debug marker looks like, and "pads e objetivo
	-- parecem debug" was the ninth item on the list of what was wrong with this
	-- scene. A light needs a fitting for the same reason a door needs a frame:
	-- the fitting is what says somebody built it.
	local socket = Instance.new("Part")
	socket.Name = "Socket"
	socket.Anchored = true
	socket.Shape = Enum.PartType.Cylinder
	socket.Size = Vector3.new(1.1, 2.2, 2.2)
	socket.CFrame = deck.CFrame * CFrame.new(0, 0.7, 0) * CFrame.Angles(0, 0, math.rad(90))
	socket.Color = tokens:color("metalDark")
	socket.Material = Enum.Material.Metal
	socket.Parent = plinth

	local marker = Instance.new("Part")
	marker.Name = "Marker"
	marker.Anchored = true
	marker.CanCollide = false
	marker.Shape = Enum.PartType.Ball
	-- Half the diameter it was. Bloom renders an emissive as a disc of its own
	-- size plus the flare, so how big a light source is is a composition
	-- decision before it is a lighting one.
	marker.Size = Vector3.new(0.7, 0.7, 0.7)
	marker.CFrame = deck.CFrame * CFrame.new(0, 1.0, 0)
	marker.Color = tokens:color("accentGold")
	marker.Material = Enum.Material.Neon
	marker.Parent = plinth

	-- A pennant on a mast. Cloth, no emissive: a pad has to read as a claimed
	-- site from across the plaza, and at that distance a silhouette against the
	-- sky carries further than a point of light does.
	local mast = Instance.new("Part")
	mast.Name = "Mast"
	mast.Anchored = true
	mast.Size = Vector3.new(0.35, 7, 0.35)
	mast.CFrame = plinth.CFrame * CFrame.new(-4.6, 8.1, -4.6)
	mast.Color = tokens:color("woodSecondary")
	mast.Material = Enum.Material.Wood
	mast.Parent = plinth

	local pennant = Instance.new("Part")
	pennant.Name = "Pennant"
	pennant.Anchored = true
	pennant.CanCollide = false
	pennant.Size = Vector3.new(2.6, 1.7, 0.12)
	pennant.CFrame = mast.CFrame * CFrame.new(1.4, 2.4, 0)
	pennant.Color = tokens:color("accentGold")
	pennant.Material = Enum.Material.Fabric
	pennant.Parent = plinth

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Build " .. tostring(entry.name)
	prompt.ObjectText = tostring(price) .. " cash"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = plinth

	prompt.Triggered:Connect(function(player: Player)
		if systems.economy == nil then
			return
		end
		-- Spent through the economy, never by editing a number here. Two paths
		-- that move currency is how a ledger stops reconciling.
		local paid = systems.economy:spend(player, "cash", price, "build:" .. tostring(entry.id))
		if not paid then
			-- Refusal has to be audible. A player who cannot afford a
			-- tower learns it from the sound, not from prompt text that
			-- changed for a second and a half while they looked away.
			WorldKit.Audio.playAt("denied", plinth)
			prompt.ObjectText = "Need " .. tostring(price) .. " cash"
			task.delay(1.5, function()
				prompt.ObjectText = tostring(price) .. " cash"
			end)
			return
		end

		-- Built from the same architecture the world is made of, so a tower the
		-- player raises belongs to the place rather than being dropped on it.
		-- A box with a cap on it was the clearest remaining debug object in the
		-- scene, and it was the one the player looks at most.
		WorldKit.Audio.playAt("purchase", plinth)
		local stats = entry.stats or {}
		local built = WorldKit.Architecture.tower(stage, tokens, {
			position = plinth.Position + Vector3.new(0, 1, 0),
			radius = 3.4,
			height = 10 + math.min((stats.attack or 1) * 1.5, 10),
			style = STYLE,
			beacon = false,
		})
		built.Name = tostring(entry.id)
		local tower = built.PrimaryPart or built:FindFirstChildWhichIsA("BasePart")

		-- A banner in the owner's colour: which towers are mine, readable at a
		-- glance and without a label.
		WorldKit.Props.banner(built, tokens, {
			position = plinth.Position + Vector3.new(4.2, 1, 0),
			scale = 0.6,
			seed = index,
		})

		if tower ~= nil then
			WorldKit.Vfx.burst(tokens, tower, {
				fromRole = "accentGold", toRole = "neutralLight",
				rate = 0, lifetime = NumberRange.new(0.4, 0.9),
				speed = NumberRange.new(6, 10), size = 1.2,
			}, 18)
		end

		if systems.tower ~= nil then
			systems.tower.place(player, tostring(entry.id),
				{ tower.Position.X, tower.Position.Y, tower.Position.Z })
		end

		plinth:SetAttribute("built", true)
		marker:Destroy()
		prompt:Destroy()
	end)
end

for index, at in ipairs(slots) do
	local entry = Catalogue[((index - 1) % math.max(#Catalogue, 1)) + 1]
	if entry ~= nil then
		pad(index, at, entry)
	end
end

-- Something to earn, so the cost above is payable. The objective pays out on a
-- cadence: a loop whose first step is unaffordable is a loop nobody enters.
local objective = regionPivot("objective") or CFrame.new(0, 0, -60)

-- Readability, before mechanics. A player looking at one frame has to be able
-- to answer three questions without reading anything: what am I defending,
-- where does the threat come from, and which way does it travel. Text answers
-- none of them, because a player under pressure does not read.
--
-- Built from the same architecture and props as the world, so the answers are
-- part of the place rather than markers laid over it.
local threat = regionPivot("approach") or regionPivot("field")
	or (objective * CFrame.new(0, 0, 220))

-- 1. Where the threat comes from: a breached gate, flanked and lit in the
-- danger colour. A gap in a wall reads as an entrance from any angle.
local gate = Instance.new("Model")
gate.Name = "ThreatGate"
gate.Parent = stage
for _, side in ipairs({ -1, 1 }) do
	local pier = Instance.new("Part")
	pier.Name = "Pier"
	pier.Anchored = true
	pier.Size = Vector3.new(7, 26, 7)
	pier.CFrame = threat * CFrame.new(side * 13, 13, 0)
	pier.Color = tokens:color("stoneSecondary")
	pier.Material = Enum.Material.Cobblestone
	pier.Parent = gate

	local brazier = Instance.new("Part")
	brazier.Name = "Brazier"
	brazier.Anchored = true
	brazier.Shape = Enum.PartType.Ball
	brazier.Size = Vector3.new(2.6, 2.6, 2.6)
	brazier.CFrame = pier.CFrame * CFrame.new(0, 14.5, 0)
	brazier.Color = tokens:color("accentDanger")
	brazier.Material = Enum.Material.Neon
	brazier.Parent = gate

	local light = Instance.new("PointLight")
	light.Brightness = 1.2
	light.Range = 22
	light.Color = tokens:color("accentDanger")
	light.Parent = brazier

	WorldKit.Props.banner(gate, tokens, {
		position = pier.Position + Vector3.new(side * 5, -8, 0),
		accent = "accentDanger", scale = 0.9, seed = side + 40,
	})
end

local lintel = Instance.new("Part")
lintel.Name = "Lintel"
lintel.Anchored = true
lintel.Size = Vector3.new(33, 5, 8)
lintel.CFrame = threat * CFrame.new(0, 28, 0)
lintel.Color = tokens:color("stonePrimary")
lintel.Material = Enum.Material.Cobblestone
lintel.Parent = gate

-- 2. Which way it travels: a paved lane from the gate to the objective, in the
-- danger colour and edged so it reads as a route rather than as decoration.
local span = (objective.Position - threat.Position)
local distance = span.Magnitude
if distance > 8 then
	local middle = threat.Position:Lerp(objective.Position, 0.5)
	local along = CFrame.lookAt(middle, middle + span.Unit)

	local lane = Instance.new("Part")
	lane.Name = "ThreatLane"
	lane.Anchored = true
	lane.Size = Vector3.new(20, 0.6, distance)
	lane.CFrame = along * CFrame.new(0, 0.4, 0)
	lane.Color = tokens:color("pathAlt")
	lane.Material = Enum.Material.Slate
	lane.Parent = stage

	local edge = Instance.new("Part")
	edge.Name = "LaneEdge"
	edge.Anchored = true
	edge.Size = Vector3.new(24, 0.4, distance)
	edge.CFrame = along * CFrame.new(0, 0.2, 0)
	edge.Color = tokens:color("accentDanger")
	edge.Material = Enum.Material.SmoothPlastic
	edge.Parent = stage

	-- Chevrons pointing at what they threaten. Direction is the one thing a
	-- stripe on the ground cannot say by itself.
	local steps = math.max(math.floor(distance / 26), 1)
	for index = 1, steps do
		local chevron = Instance.new("Part")
		chevron.Name = "Chevron"
		chevron.Anchored = true
		chevron.CanCollide = false
		chevron.Size = Vector3.new(9, 0.3, 3)
		chevron.CFrame = along
			* CFrame.new(0, 0.8, distance / 2 - index * (distance / (steps + 1)))
			* CFrame.Angles(0, math.rad(45), 0)
		chevron.Color = tokens:color("accentDanger")
		chevron.Material = Enum.Material.Neon
		chevron.Transparency = 0.45
		chevron.Parent = stage
	end
end

local core = Instance.new("Part")
core.Name = "Core"
core.Anchored = true
core.Size = Vector3.new(6, 8, 6)
core.CFrame = objective * CFrame.new(0, 5, 0)
core.Color = tokens:color("accentRare")
core.Material = Enum.Material.Neon
core.Parent = stage

local collect = Instance.new("ProximityPrompt")
collect.ActionText = "Collect"
collect.ObjectText = "anime-card-farm"
collect.HoldDuration = 0.2
collect.MaxActivationDistance = 16
collect.RequiresLineOfSight = false
collect.Parent = core

collect.Triggered:Connect(function(player: Player)
	Gameplay.reward(player, 25, "objective")
	WorldKit.Vfx.burst(tokens, core, {
		fromRole = "accentRare", toRole = "neutralLight",
		rate = 0, lifetime = NumberRange.new(0.5, 1.0),
		speed = NumberRange.new(8, 14), size = 1.6,
	}, 24)
end)

--------------------------------------------------------------- enemies

-- Waves as things that walk, not as arithmetic.
--
-- `Tower.simulate` decided whether a wave is clearable and the drivers applied
-- the damage, and none of it existed in the world: a player watched a counter
-- change. The goal is explicit that the content catalogue has to appear and
-- have a function, and an enemy that is only a row in a table appears nowhere.
--
-- Built from the same catalogue the tower system consumes, so a game with
-- different content gets different enemies without this file knowing anything
-- about the genre.
-- Seeded from the game id, like every other placement: two runs of the same
-- game must put the same enemy in the same lane or a visual comparison between
-- them reports noise instead of change.
local random = Random.new(464527)

local enemyFolder = Instance.new("Folder")
enemyFolder.Name = "Enemies"
enemyFolder.Parent = stage

local function spawnEnemy(entry: { [string]: any }, wave: number)
	local stats = entry.stats or {}
	local health = math.max((stats.health or 1) * 20, 20)

	local body = Instance.new("Part")
	body.Name = tostring(entry.id)
	body.Anchored = true
	body.Size = Vector3.new(3.2, 5.2, 3.2)
	body.CFrame = threat * CFrame.new(random:NextNumber(-8, 8), 3.6, 0)
	body.Color = tokens:color("accentDanger")
	body.Material = Enum.Material.SmoothPlastic
	body.CanCollide = false
	body.Parent = enemyFolder

	-- A head and a banner-coloured crest: three masses, so it reads as a figure
	-- rather than as a marker at the distance a player watches the lane from.
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Anchored = true
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(2.2, 2.2, 2.2)
	head.CFrame = body.CFrame * CFrame.new(0, 3.4, 0)
	head.Color = tokens:color("metalDark")
	head.Material = Enum.Material.Metal
	head.CanCollide = false
	head.Parent = body

	local bar = Instance.new("Part")
	bar.Name = "Health"
	bar.Anchored = true
	bar.Size = Vector3.new(3.4, 0.5, 0.4)
	bar.CFrame = body.CFrame * CFrame.new(0, 5.2, 0)
	bar.Color = tokens:color("accentSuccess")
	bar.Material = Enum.Material.Neon
	bar.CanCollide = false
	bar.Parent = body

	-- Walks the lane the chevrons point along, so what the readability elements
	-- promise is what actually happens.
	task.spawn(function()
		local travelled = 0
		local remaining = health
		local start = body.Position
		local finish = objective.Position + Vector3.new(0, 3.6, 0)
		local span = (finish - start).Magnitude
		local speed = math.max((stats.speed or 1) * 3, 4)

		while travelled < span and remaining > 0 and body.Parent ~= nil do
			local step = speed * 0.1
			travelled += step
			body.CFrame = CFrame.lookAt(start:Lerp(finish, travelled / span), finish)
				* CFrame.new(0, 0, 0)

			-- Damage from whatever is placed, applied here and nowhere else. Two
			-- places subtracting health is how an enemy dies twice and pays out
			-- twice.
			if systems.tower ~= nil then
				local dps = 0
				for _, player in ipairs(Players:GetPlayers()) do
					dps += systems.tower.damage(player)
				end
				remaining -= dps * 0.1
				bar.Size = Vector3.new(3.4 * math.clamp(remaining / health, 0, 1), 0.5, 0.4)
				bar.Color = tokens:color(
					if remaining / health > 0.5 then "accentSuccess" else "accentDanger")
			end
			task.wait(0.1)
		end

		if remaining <= 0 then
			-- Killed: pay the bounty and say so. A reward with no feedback is a
			-- number that moves while the player is looking somewhere else.
			WorldKit.Vfx.burst(tokens, body, {
				fromRole = "accentGold", toRole = "neutralLight",
				rate = 0, lifetime = NumberRange.new(0.3, 0.7),
				speed = NumberRange.new(8, 16), size = 1.1,
			}, 14)
			for _, player in ipairs(Players:GetPlayers()) do
				Gameplay.reward(player, math.max(math.floor(entry.power or 1), 1), "kill")
			end
		else
			WorldKit.Vfx.burst(tokens, core, {
				fromRole = "accentDanger", toRole = "neutralLight",
				rate = 0, lifetime = NumberRange.new(0.4, 0.8),
				speed = NumberRange.new(6, 12), size = 1.4,
			}, 18)
		end
		task.wait(0.4)
		body:Destroy()
	end)
end

-- One trickle per wave, from the gate, forever. The session driver decides when
-- a wave counts; this is what a player sees while it does.
task.spawn(function()
	while true do
		local wave = math.max(tonumber(script:GetAttribute("wave")) or 1, 1)
		for index = 1, 4 do
			local entry = Catalogue[((wave * 4 + index) % math.max(#Catalogue, 1)) + 1]
			if entry ~= nil then
				spawnEnemy(entry, wave)
			end
			task.wait(1.6)
		end
		task.wait(6)
	end
end)

-- A starting balance, so the first prompt is reachable. A tutorial that opens
-- with an unaffordable purchase teaches the player that the game is broken.
Players.PlayerAdded:Connect(function(player: Player)
	task.wait(1)
	Gameplay.reward(player, 120, "onboarding")
end)

print(string.format("[anime-card-farm] playable: %d pads, 1 objective", #slots))
	return stage
end

return Playable
