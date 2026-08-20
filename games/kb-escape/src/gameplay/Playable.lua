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
--- Drivers owns autonomous time. Playable only presents the events it emits;
--- it never starts a second clock that can drift away from session state.
function Playable.build(Gameplay, Drivers)
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
for _, regionName in ipairs({ "staging", "build_west", "build_east", "arena" }) do
	local pivot = regionPivot(regionName)
	if pivot ~= nil then
		-- The spawn gets one nearby teaching site, not a barricade of three.
		-- Remaining plots keep their full capacity after the player understands
		-- the verb.  With the old order the highlighted first action was more
		-- than one hundred navigated studs away from the spawn.
		local offsets = if regionName == "staging" then { -1 } else { -1, 0, 1 }
		for _, index in ipairs(offsets) do
			table.insert(slots, pivot * CFrame.new(index * 14, 0, 0))
		end
	end
end
if #slots == 0 then
	table.insert(slots, CFrame.new(0, 0, 0))
end

-- A tower system may consume only a subset of the content catalogue. Building
-- a purchase pad for an enemy id creates a convincing tower in the world that
-- the authoritative store refuses to place. Filter by the system's definitions
-- so every offered purchase can become a real placement.
local buildCatalogue: { { [string]: any } } = {}
for _, entry in ipairs(Catalogue) do
	if systems.tower == nil or systems.tower.towers[tostring(entry.id)] ~= nil then
		table.insert(buildCatalogue, entry)
	end
end

local firstBuildSite: Part? = nil
local rewardSource: BasePart? = nil

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
	if index == 1 then
		firstBuildSite = plinth
	end

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
		local position = plinth.Position + Vector3.new(0, 1, 0)
		local placementPosition = { position.X, position.Y, position.Z }

		-- Spatial refusal happens before money moves. There is no yield between
		-- this check, the spend and `place`, so the authoritative transaction
		-- cannot emit a purchase for a placement the Tower store rejected.
		if systems.tower ~= nil then
			local allowed = systems.tower.canPlace(player, tostring(entry.id), placementPosition)
			if not allowed then
				systems.feedback:emit(player, "error", {
					reasonKey = "invalid", itemName = tostring(entry.name),
					position = plinth.Position,
				})
				WorldKit.Audio.playAt("denied", plinth)
				return
			end
		end

		-- Spent through the economy, never by editing a number here. Two paths
		-- that move currency is how a ledger stops reconciling.
		local paid = systems.economy:spend(player, "cash", price, "build:" .. tostring(entry.id))
		if not paid then
			-- Refusal has to be audible. A player who cannot afford a
			-- tower learns it from the sound, not from prompt text that
			-- changed for a second and a half while they looked away.
			WorldKit.Audio.playAt("denied", plinth)
			systems.feedback:emit(player, "error", {
				reasonKey = "insufficient_funds", itemName = tostring(entry.name),
				position = plinth.Position,
			})
			prompt.ObjectText = "Need " .. tostring(price) .. " cash"
			task.delay(1.5, function()
				prompt.ObjectText = tostring(price) .. " cash"
			end)
			return
		end
		player:SetAttribute("cash", systems.economy:balance(player, "cash"))

		if systems.tower ~= nil then
			local placement = systems.tower.place(
				player, tostring(entry.id), placementPosition)
			if placement == nil then
				-- Defensive rollback for an unexpected refusal. `canPlace` and
				-- `place` are adjacent and should agree; losing currency if they do
				-- not would turn an SDK disagreement into a player-facing theft.
				local balance = systems.economy:grant(
					player, "cash", price, "rollback:" .. tostring(entry.id))
				player:SetAttribute("cash", balance)
				systems.feedback:emit(player, "error", {
					reasonKey = "invalid", itemName = tostring(entry.name),
					position = plinth.Position,
				})
				return
			end
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

		plinth:SetAttribute("built", true)
		marker:Destroy()
		prompt:Destroy()
		systems.feedback:emit(player, "purchase", {
			itemName = tostring(entry.name), position = plinth.Position,
		})
		if systems.tower ~= nil then
			systems.feedback:emit(player, "build", {
				itemName = tostring(entry.name), position = position,
			})
		end

		-- This effect is recorded only after the spend, authoritative placement
		-- (when present), and world build all succeeded. A prompt trigger is an
		-- attempt; it is never evidence that a purchase happened.
		if systems.onboarding ~= nil then
			local receipt = systems.onboarding.observe(
				player, "purchase_committed",
				"build:" .. tostring(player.UserId) .. ":" .. tostring(index),
				{ itemId = tostring(entry.id) })
			if receipt.accepted and index == 1 then
				WorldKit.Guidance.clear(plinth, "first-purchase")
			end
		end
	end)
end

for index, at in ipairs(slots) do
	local entry = buildCatalogue[((index - 1) % math.max(#buildCatalogue, 1)) + 1]
	if entry ~= nil then
		pad(index, at, entry)
	end
end

-- Mark the first site even while inactive, so a black-box probe can distinguish
-- "the cue is off" from "this build exposed no observable target".
local initialSite = firstBuildSite
if initialSite ~= nil then
	WorldKit.Guidance.focus(tokens, initialSite, {
		id = "first-purchase", action = "Build your first defender",
		role = "accentGold", maxDistance = 70,
	})
	WorldKit.Guidance.clear(initialSite, "first-purchase")
end

-- Guidance follows the server-published onboarding target. Both authored
-- actions are world targets: the reliquary first, then the nearest foundation.
-- In a shared server a cue remains active while any player still needs it.
local function refreshGuidance()
	local wantsReward = false
	local wantsPurchase = false
	for _, player in ipairs(Players:GetPlayers()) do
		if player:GetAttribute("RQEOnboardingComplete") ~= true then
			local target = player:GetAttribute("RQEOnboardingTarget")
			wantsReward = wantsReward or target == "reward-source"
			wantsPurchase = wantsPurchase or target == "first-purchase"
		end
	end

	local function apply(site: BasePart?, id: string, action: string, wanted: boolean)
		if site == nil then
			return
		end
		local probe = WorldKit.Guidance.probe(stage, id)
		if wanted and not probe.active then
			WorldKit.Guidance.focus(tokens, site, {
				id = id, action = action, role = "accentGold", maxDistance = 90,
			})
		elseif not wanted and probe.active then
			WorldKit.Guidance.clear(site, id)
		end
	end

	apply(rewardSource, "reward-source", "Gather embers", wantsReward)
	apply(firstBuildSite, "first-purchase", "Build your first defender", wantsPurchase)
end

local guidanceBound: { [Player]: boolean } = {}
local function bindGuidancePlayer(player: Player)
	if guidanceBound[player] then
		return
	end
	guidanceBound[player] = true
	player:GetAttributeChangedSignal("RQEOnboardingTarget"):Connect(refreshGuidance)
	player:GetAttributeChangedSignal("RQEOnboardingComplete"):Connect(refreshGuidance)
	refreshGuidance()
end
Players.PlayerRemoving:Connect(function(player: Player)
	guidanceBound[player] = nil
	task.defer(refreshGuidance)
end)

-- The objective axis. Its focus is defended; the separate spawn-side
-- reliquary below owns the earn verb.
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

-- The defended objective is the authored bell when the selected setpiece owns
-- one.  Falling back is explicit and still produces a semantic anchor; a neon
-- debug cube no longer grows through the bell the brief asked for.
local authoredBell = world:FindFirstChild("Bell", true)
local core: BasePart
if authoredBell ~= nil and authoredBell:IsA("BasePart") then
	core = authoredBell
else
	local fallback = Instance.new("Part")
	fallback.Name = "BellObjectiveFallback"
	fallback.Anchored = true
	fallback.Size = Vector3.new(6, 8, 6)
	fallback.CFrame = objective * CFrame.new(0, 5, 0)
	fallback.Color = tokens:color("accentRare")
	fallback.Material = tokens:material("accentRare")
	fallback.Parent = stage
	core = fallback
end
core:SetAttribute("RQEDefendedObjective", "bell")

-- An authored, reachable first verb.  The previous tutorial granted its reward
-- on a timer and advanced itself while the player stood still.  This reliquary
-- is beside the spawn, pays enough for the highlighted foundation, and remains
-- useful afterwards on a bounded cadence.
local reliquaryAt = (regionPivot("staging") or CFrame.new(0, 0, 40))
	* CFrame.new(0, 0, -14)
local reliquary = Instance.new("Model")
reliquary.Name = "EmberReliquary"
reliquary.Parent = stage

local pedestal = Instance.new("Part")
pedestal.Name = "Pedestal"
pedestal.Anchored = true
pedestal.Size = Vector3.new(6, 3, 6)
pedestal.CFrame = reliquaryAt * CFrame.new(0, 1.5, 0)
pedestal.Color = tokens:color("stoneSecondary")
pedestal.Material = tokens:material("stoneSecondary")
pedestal.Parent = reliquary
rewardSource = pedestal

local bowl = Instance.new("Part")
bowl.Name = "Brazier"
bowl.Anchored = true
bowl.Shape = Enum.PartType.Cylinder
bowl.Size = Vector3.new(1.4, 5, 5)
bowl.CFrame = reliquaryAt * CFrame.new(0, 3.7, 0)
	* CFrame.Angles(0, 0, math.rad(90))
bowl.Color = tokens:color("metalDark")
bowl.Material = tokens:material("metalDark")
bowl.Parent = reliquary

local ember = Instance.new("Part")
ember.Name = "Ember"
ember.Anchored = true
ember.CanCollide = false
ember.Shape = Enum.PartType.Ball
ember.Size = Vector3.new(1.7, 1.7, 1.7)
ember.CFrame = reliquaryAt * CFrame.new(0, 5, 0)
ember.Color = tokens:color("accentGold")
ember.Material = Enum.Material.Neon
ember.Parent = reliquary
reliquary.PrimaryPart = pedestal

local emberLight = Instance.new("PointLight")
emberLight.Color = tokens:color("accentGold")
emberLight.Brightness = 1.6
emberLight.Range = 18
emberLight.Parent = ember

local collect = Instance.new("ProximityPrompt")
collect.ActionText = "Gather Embers"
collect.ObjectText = "Reliquary"
collect.HoldDuration = 0.35
collect.MaxActivationDistance = 14
collect.RequiresLineOfSight = false
collect.Parent = pedestal

WorldKit.Guidance.focus(tokens, pedestal, {
	id = "reward-source", action = "Gather embers",
	role = "accentGold", maxDistance = 90,
})
WorldKit.Guidance.clear(pedestal, "reward-source")

local lastGather: { [number]: number } = {}
collect.Triggered:Connect(function(player: Player)
	local now = os.clock()
	local previous = lastGather[player.UserId] or -math.huge
	if now - previous < 6 then
		systems.feedback:emit(player, "error", { reasonKey = "cooldown" })
		return
	end
	lastGather[player.UserId] = now
	local first = player:GetAttribute("RQEOnboardingTarget") == "reward-source"
	Gameplay.reward(player, if first then 120 else 25, "reliquary")
	WorldKit.Vfx.burst(tokens, ember, {
		fromRole = "accentGold", toRole = "neutralLight",
		rate = 0, lifetime = NumberRange.new(0.5, 1.0),
		speed = NumberRange.new(8, 14), size = 1.6,
	}, 24)
	refreshGuidance()
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
local random = Random.new(375103)

local enemyFolder = Instance.new("Folder")
enemyFolder.Name = "Enemies"
enemyFolder.Parent = stage

local function spawnEnemy(entry: { [string]: any }, wave: number)
	local stats = entry.stats or {}
	local health = math.max((stats.health or 1) * 20, 20)

	-- A figure, not a marker.
	--
	-- `WorldKit.Threat` builds a faceless hooded humanoid from token colours --
	-- mantle, cowl, no face, its own health bar. It existed, was tested, and had
	-- never reached a game: the enemy here was a red box with a ball on it.
	--
	-- In a horror game the thing coming down the lane *is* the product. A red
	-- marker approaching is a counter going up.
	local model = WorldKit.Threat.build(enemyFolder, tokens, {
		id = tostring(entry.id),
		cframe = threat * CFrame.new(random:NextNumber(-8, 8), 3.6, 0),
		displayName = tostring(entry.id),
		-- Both, because `maxHealth` defaults to 100 and a tier-3 pilgrim has
		-- more than that; passing only `health` fails its own validator.
		maxHealth = health,
		health = health,
		scale = 1 + math.min((stats.health or 1) * 0.05, 0.45),
		seed = wave * 131 + random:NextInteger(1, 9999),
		bodyRole = "ink",
		mantleRole = "slate",
		faceRole = "neutralLight",
		accentRole = "accentDanger",
		showHealth = true,
	})
	local body = model.PrimaryPart :: Part

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
			WorldKit.Threat.pivot(model,
				CFrame.lookAt(start:Lerp(finish, travelled / span), finish))

			-- Damage from whatever is placed, applied here and nowhere else. Two
			-- places subtracting health is how an enemy dies twice and pays out
			-- twice.
			if systems.tower ~= nil then
				local dps = 0
				for _, player in ipairs(Players:GetPlayers()) do
					dps += systems.tower.damage(player)
				end
				remaining -= dps * 0.1
				WorldKit.Threat.setHealth(model, remaining, health)
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
		model:Destroy()
	end)
end

-- Visual waves are projections of the authoritative Tower wave, not a second
-- simulation. Drivers owns when a wave begins; the same definition used by
-- `Tower.forecast` owns which enemy arrives, how many arrive and their spacing.
-- This is deliberately subscribed before `Drivers.start` in the boot script,
-- so the first event cannot be lost to module startup order.
local catalogueById: { [string]: { [string]: any } } = {}
for _, entry in ipairs(Catalogue) do
	catalogueById[tostring(entry.id)] = entry
end

Drivers.on(function(event: string, detail: { [string]: any })
	if event ~= "wave" or systems.tower == nil then
		return
	end

	local round = math.max(math.floor(tonumber(detail.round) or 0), 1)
	local waves = systems.tower.waves
	local definition = waves[math.min(round, #waves)]
	if definition == nil then
		return
	end

	for _, waveEntry in ipairs(definition.entries) do
		local entry = catalogueById[tostring(waveEntry.enemyId)]
		if entry == nil then
			warn(string.format("[Playable] wave %d names missing catalogue entry %s",
				round, tostring(waveEntry.enemyId)))
			continue
		end
		for _ = 1, waveEntry.count do
			spawnEnemy(entry, round)
			task.wait(waveEntry.interval or 0)
		end
	end
end)

-- Bind the two authored cues. Currency is deliberately not granted here: the
-- reliquary is the first playable verb and its committed reward is what moves
-- onboarding to the nearby foundation.
local joined: { [number]: boolean } = {}
local function onPlayer(player: Player)
	if joined[player.UserId] then
		return
	end
	joined[player.UserId] = true
	bindGuidancePlayer(player)
end
Players.PlayerAdded:Connect(onPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayer(player)
end

print(string.format("[kb-escape] playable: %d pads, 1 objective", #slots))
	return stage
end

return Playable
