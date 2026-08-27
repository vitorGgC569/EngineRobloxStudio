--!strict
--[[
	Plots — who owns which patch of ground, and what is standing on it.

	The three things a tycoon plot has to get right, and the order matters:

	  **Allocation.** Six plots, twelve players trying to join. Somebody has to
	  be told no, and the same somebody must not be given a plot that another
	  player is standing on. `Tycoon.PlotAllocator` owns that.

	  **Placement.** A machine occupies cells, not a point. Two drills that
	  overlap by one stud are a bug nobody sees until a conveyor runs through a
	  wall. `Tycoon.GridPlacement` owns that, and it answers `fits` before
	  anything is built.

	  **Permission.** A plot belongs to one player, and every build request
	  arrives from a client that may have been written by somebody else.
	  `Social.PlotPermissions` owns that, and it is checked on the server for
	  every single placement rather than trusted because the UI only offered
	  legal buttons.

	This system owns none of that logic. It owns the *geometry* — the ground,
	the marker, the machine models — and asks the three modules above whether
	each thing is allowed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Mark = Forge.Mark
local Material = Forge.Material
local Catalog = Forge.Catalog
local Prop = Catalog.Prop
local Rng = Forge.Core.Rng
local Boot = Forge.Core.Boot

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local PlotAllocator = require(ReplicatedStorage.Forge.Tycoon.PlotAllocator)
local GridPlacement = require(ReplicatedStorage.Forge.Tycoon.GridPlacement)
local PlotPermissions = require(ReplicatedStorage.Forge.Social.PlotPermissions)

--: A sibling in `systems`, so `script.Parent` -- not `script`, which is this
--: file, and not `Shared`, which is a different tree.
local Machinery = require(script.Parent.Machinery)

local Plots = {}

Plots.allocator = nil :: any
--[[
	Permissions, held as one instance for the whole map.

	`PlotPermissions` keys on a numeric UserId and a capability — Build, Buy or
	Sell — rather than a boolean "is owner". That distinction pays off the
	moment a player wants a friend who can build but not sell, which is the
	first thing anybody asks for in a tycoon with visitors.
]]
Plots.permissions = nil :: any
Plots.grids = {} :: { [string]: any }
Plots.models = {} :: { [string]: Model }
--: Every machine standing on every plot, keyed `plotId` then `placementId`.
Plots.built = {} :: { [string]: { [string]: any } }

local function plotId(index: number): string
	return string.format("plot%d", index)
end

-- ================================== building ================================
--[[
	Lay the ground.

	Anchored, one part per plot, spaced far enough apart that two neighbours do
	not read as one factory. The marker is a separate part rather than a
	SurfaceGui so an unowned plot is legible from across the map without
	anything having to render text at that distance.
]]
--[[
	Yard clutter around the edge of a plot.

	A plot is a slab, and a slab reads as a slab however big it is. This is what
	makes it read as somebody's yard instead: crates and barrels stacked at the
	back, a storage tank in a corner, pipe run along the rim.

	**Outside the buildable square, never inside it.** The grid is what the
	player places machines on, and a decorative crate sitting on a cell is
	either an obstruction or -- worse -- something they try to remove and
	cannot. Everything here sits past the floor edge, on the rim.

	**The front stays clear.** The road runs along -Z and that is the side a
	player walks in from; furnishing it would mean walking around your own
	scenery to reach your own plot.

	Deterministic from the plot index, so plot three looks like plot three every
	time the world is built and two players standing on neighbouring plots do
	not see the same arrangement twice.
]]
local function dressPlot(model: Model, index: number, origin: Vector3, size: number)
	local stream = Rng.stream("plot.dress." .. index)
	local edge = size * 0.5 + 4

	--: Back corners and the back edge. Weighted to the topics a working site
	--: would actually have lying about, not to what looks prettiest.
	--: Heights, not multipliers. These models were authored at wildly different
	--: scales -- a baked ore chunk is one stud and a storage tank is nineteen --
	--: so asking for a size is the only way to get a yard that looks composed.
	local spots = {
		{ x = -edge, z = -edge, topic = "storage tank", height = 14 },
		{ x = edge, z = -edge, topic = "generator", height = 6 },
		{ x = -edge * 0.35, z = -edge, topic = "crate", height = 5 },
		{ x = edge * 0.35, z = -edge, topic = "barrel", height = 4 },
		{ x = -edge, z = 0, topic = "pipe", height = 3 },
		{ x = edge, z = 0, topic = "crate", height = 4 },
		{ x = -edge, z = edge * 0.45, topic = "barrel", height = 4 },
		{ x = edge, z = edge * 0.45, topic = "ore", height = 4 },
	}

	local placed = 0
	for slot, spot in spots do
		--: A quarter of the slots stay empty, varying per plot. A perimeter
		--: with every position filled reads as a fence rather than as clutter.
		if stream:number(0, 1) < 0.25 then
			continue
		end

		local at = origin + Vector3.new(spot.x, 0, spot.z)
		local prop = Prop.place(spot.topic, index * 131 + slot * 17, at, {
			targetHeight = spot.height,
			--: Variation around the target rather than instead of it.
			scale = stream:number(0.85, 1.2),
			--: Solid, unlike the scattered scenery: these sit where a player
			--: walks and reading as furniture means stopping them.
			canCollide = true,
			parent = model,
		})
		if prop then
			placed += 1
		end
	end
	return placed
end

local function buildPlot(index: number, container: Instance): Model
	local size = Config.plots.size
	local origin = Config.plots.origin + Vector3.new((index - 1) * Config.plots.spacing, 0, 0)

	local model = Instance.new("Model")
	model.Name = plotId(index)

	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Size = Vector3.new(size, 1, size)
	floor.CFrame = CFrame.new(origin)
	floor.Anchored = true
	floor.Color = Color3.fromRGB(122, 116, 104)
	floor.Material = Enum.Material.Slate
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = model

	local rim = Instance.new("Part")
	rim.Name = "Rim"
	rim.Size = Vector3.new(size + 2, 0.6, size + 2)
	rim.CFrame = CFrame.new(origin - Vector3.new(0, 0.6, 0))
	rim.Anchored = true
	rim.Color = Color3.fromRGB(74, 70, 64)
	rim.Material = Enum.Material.Concrete
	rim.Parent = model

	--[[
		A post with a lamp, not a monolith.

		This was a four-by-eight-by-four neon slab, and in every screenshot of
		this game it is the brightest object on screen and occupies more of the
		frame than the entire factory it is labelling. A marker that outshines
		the thing it marks is not a marker.

		Slim post, small lamp on top, at the front corner rather than the
		middle of the walkway.
	]]
	local post = Instance.new("Part")
	post.Name = "ClaimPost"
	post.Size = Vector3.new(0.5, 4.5, 0.5)
	post.CFrame = CFrame.new(origin + Vector3.new(-size / 2 + 2.5, 2.75, -size / 2 + 2.5))
	post.Anchored = true
	post.CanCollide = false
	post.Color = Color3.fromRGB(64, 62, 58)
	post.Material = Enum.Material.Metal
	post.Parent = model

	local claim = Instance.new("Part")
	claim.Name = "Claim"
	claim.Shape = Enum.PartType.Ball
	claim.Size = Vector3.new(1.1, 1.1, 1.1)
	claim.CFrame = CFrame.new(origin + Vector3.new(-size / 2 + 2.5, 5.4, -size / 2 + 2.5))
	claim.Anchored = true
	--[[
		A sign, not a platform.

		Left collidable, the first screenshot of this game had the player
		standing on top of their own claim marker like a lamp post, because an
		eight-stud neon pillar next to a spawn is the tallest thing a character
		can walk into. Nothing about a marker wants to be stood on.
	]]
	claim.CanCollide = false
	claim.CanQuery = false
	claim.Color = Color3.fromRGB(210, 176, 96)
	claim.Material = Enum.Material.Neon
	claim.Parent = model

	dressPlot(model, index, origin, size)

	model.PrimaryPart = floor
	model.Parent = container
	return model
end

function Plots.start()
	local container = Workspace:FindFirstChild("Plots")
	if not container then
		local folder = Instance.new("Folder")
		folder.Name = "Plots"
		folder.Parent = Workspace
		container = folder
	end

	local ids = {}
	for index = 1, Config.plots.count do
		local id = plotId(index)
		table.insert(ids, id)
		Plots.models[id] = buildPlot(index, container)
		Plots.built[id] = {}

		--[[
			One grid per plot, in plot-local coordinates.

			Local rather than world, so a machine placed at (2, 3) means the
			same thing on every plot and a blueprint saved on one can be
			rebuilt on another. Converting to world happens once, at the
			moment a part is created.
		]]
		local half = Config.plots.size / 2
		Plots.grids[id] = GridPlacement.new({
			--: Seven, not four. A cell is the unit every machine is measured
			--: in, so it is the real lever on how big anything reads: at four,
			--: a two-by-two drill was eight studs and stood knee-high to the
			--: player who built it.
			cellSize = 7,
			bounds = { minX = -half, maxX = half, minZ = -half, maxZ = half },
			items = Content.gridItems(),
		})
	end

	Plots.allocator = PlotAllocator.new(ids)
	Plots.permissions = PlotPermissions.new()

	--[[
		Mount whatever authored content shipped with the place.

		A kit is `.rbxm` files rojo put into ReplicatedStorage — real models
		from a licensed project, in the place file. `Catalog` searches kits
		before it reaches for `InsertService`, which matters twice over: the
		pieces are better than anything generated here, and a local lookup
		cannot hang the way a network one does on an unpublished build.
	]]
	local kits = ReplicatedStorage:FindFirstChild("Kits")
	if kits then
		for _, kit in kits:GetChildren() do
			Catalog.mountKit(kit)
		end
		Debug.info(string.format("mounted %d kit(s), %d pieces",
			#kits:GetChildren(), #Catalog.kitPieces(400)))
	end

	--[[
		Mark the plots for the validator.

		The first plot is the landmark — it is what the camera is pointed at —
		and the floors are the regions play happens on. Without this the
		Quality Engine photographs the place and correctly reports that there
		is nothing to look at.
	]]
	Mark.landmark(Plots.models[plotId(1)], "quarry-plot")
	Mark.ringAnchors(Plots.models[plotId(1)], "quarry-plot", 6, Config.plots.size * 0.5)
	for _, id in ids do
		Mark.region(Plots.models[id].Floor, "workyard")
		Mark.root(Plots.models[id].Claim, "marker")
	end

	Debug.info(string.format("%d plots laid", Config.plots.count))
	Boot.signal("plots_ready")
end

-- ================================= allocation ===============================
--[[
	Give this player somewhere to build, or tell them why not.

	The permission is granted at the same moment as the plot, because the two
	are the same fact and holding them separately is how a plot ends up owned
	by one player and writable by another.
]]
function Plots.claim(player: Player): (string?, string?)
	local key = tostring(player.UserId)
	local existing = Plots.allocator:plotOf(key)
	if existing then
		return existing
	end

	local id = Plots.allocator:assign(key)
	if not id then
		return nil, "every plot is taken; a slot frees up when somebody leaves"
	end

	--[[
		Created on claim rather than at startup.

		`createPlot` refuses a duplicate, which is right: a plot has one owner
		at a time, and creating it again would be a second owner. `release`
		below transfers it away rather than deleting, so the record stays
		single.
	]]
	if Plots.permissions:transfer(id, player.UserId) == false then
		Plots.permissions:createPlot(id, player.UserId)
	end
	local claim = Plots.models[id]:FindFirstChild("Claim")
	if claim and claim:IsA("BasePart") then
		claim.Color = Color3.fromRGB(96, 200, 128)
	end
	return id
end

function Plots.release(player: Player)
	local key = tostring(player.UserId)
	local id = Plots.allocator:plotOf(key)
	if not id then
		return
	end

	Plots.allocator:release(key)
	-- Transferred to nobody rather than destroyed, so the next claimant finds
	-- a plot with a record instead of a missing one.
	Plots.permissions:transfer(id, 0)

	-- Everything they built goes with them. A plot handed to the next player
	-- with somebody else's factory on it is a plot they cannot use.
	Plots.clear(id)
	local claim = Plots.models[id]:FindFirstChild("Claim")
	if claim and claim:IsA("BasePart") then
		claim.Color = Color3.fromRGB(210, 176, 96)
	end
end

function Plots.plotOf(player: Player): string?
	return Plots.allocator:plotOf(tostring(player.UserId))
end

-- ================================== placing =================================
--[[
	Put a machine down, if everything says yes.

	Four checks, and every one of them has to be here rather than on the
	client: the plot exists, this player owns it, the grid has room, and the
	machine is real. A client that asks for a drill on somebody else's plot at
	coordinates outside the bounds gets four separate reasons why not.
]]
--: Returns the model as a third value: the caller needs to tell everyone
--: *where* the machine landed, and the grid decides that, not the request.
function Plots.place(player: Player, machineId: string, x: number, z: number, rotation: number?)
	: (boolean, string?, Model?)
	local key = tostring(player.UserId)
	local id = Plots.allocator:plotOf(key)
	if not id then
		return false, "you have no plot"
	end
	if not Plots.permissions:check(id, player.UserId, "Build") then
		return false, "that is not your plot"
	end

	local machine = Content.machines[machineId]
	if not machine then
		return false, string.format("there is no machine called '%s'", machineId)
	end

	local grid = Plots.grids[id]
	local turn = rotation or 0
	--[[
		Say which way it does not fit.

		`GridPlacement.fits` returns a reason -- `outside_plot`, `obstacle`,
		`occupied`, `unknown_item` -- and this threw it away for a sentence that
		covers all four. Three of them mean completely different things to the
		player: move it, the plot is full, or that machine does not exist.

		It also cost a debugging session. "that does not fit there" at three
		separate coordinates is indistinguishable from a broken grid, and the
		one word that would have separated them was being discarded one line
		from where it was produced.
	]]
	local at = grid:snap({ x = x, z = z })
	local ok, why = grid:fits(machineId, turn, at)
	if not ok then
		local said = {
			outside_plot = "that is past the edge of your plot",
			obstacle = "something is already built there",
			occupied = "that space is taken",
			unknown_item = string.format("there is no machine called '%s'", machineId),
		}
		return false, said[why] or string.format("that does not fit there (%s)", tostring(why))
	end

	local placementId = string.format("%s:%d:%d", machineId, at.x, at.z)
	if not grid:place(placementId, machineId, turn, at) then
		return false, "that space is taken"
	end

	local model = Plots.spawnMachine(id, machineId, at, turn)
	Plots.built[id][placementId] = {
		placementId = placementId,
		machineId = machineId,
		x = at.x, z = at.z, rotation = turn,
		model = model,
	}
	return true, nil, model
end

--[[
	The part that represents a machine.

	Deliberately plain geometry rather than a catalogue model. A tycoon reads
	by *silhouette and colour per role* — a player has to tell a drill from a
	depot across the plot at a glance — and four distinctly coloured boxes do
	that better than four detailed meshes that all look like machinery.
]]
--[[
	Tell the machines on a plot whether the line is actually earning.

	One attribute per machine, written only when it changes. The client reads
	it to decide whether the bit spins and the furnace glows -- which is the
	only thing that makes the animation *information* rather than decoration:
	a stalled line looks stalled, from across the map, without opening a panel.

	The change guard is not a micro-optimisation. Without it this writes an
	attribute to every machine on every plot every two seconds for ever, and
	attribute writes replicate.
]]
--[[
	A working line, free, the moment a plot is claimed.

	This is not generosity, it is the only way the game is playable at all.

	The payout rule is that a chain runs at its narrowest link, which is the one
	genuinely interesting constraint here -- it is what makes layout a decision
	instead of a shopping list. But it also means a partial line earns exactly
	nothing: a drill on its own produces zero, so a new player with an empty
	plot and no coins can never take a first step. The starting balance was
	zero and the four machines cost 1640 together. There was no first move.

	Two ways out. Relax the rule so a lone drill trickles -- which throws away
	the constraint. Or hand over one complete line and let the player extend it,
	which keeps the rule and means the factory is running, visibly, within a
	few seconds of arriving. A tycoon has to show you what it is before it asks
	you to invest in it.

	Positions are tried, not assumed: the grid refuses overlaps, and hardcoding
	four coordinates that happen to fit today is how this breaks the first time
	somebody edits a footprint.
]]
local STARTER_LINE = { "drill", "belt", "smelter", "depot" }

function Plots.grantStarterLine(plotId: string): number
	local grid = Plots.grids[plotId]
	if not grid then
		return 0
	end

	local half = Config.plots.size / 2
	local placed = 0

	for index, machineId in STARTER_LINE do
		local machine = Content.machines[machineId]
		if not machine then
			continue
		end

		--[[
			Scanned, not guessed.

			The first version picked four X positions by arithmetic and tried
			four Z offsets at each. It placed three machines and silently
			dropped the depot -- which, under the narrowest-link rule, means
			the "starter line" earned exactly zero and every machine on it sat
			still. A line that is three-quarters built is not a line.

			So this walks the plot and takes the first cell the grid accepts.
			It still prefers the chain order left to right, because the scan
			starts from the machine's ideal X and works outward, but it can
			never come up short while a free cell exists.
		]]
		local wantX = -half + 6 + (index - 1) * ((half * 2 - 12) / (#STARTER_LINE - 1))
		local put = false

		local candidates: { { x: number, z: number } } = {}
		for _, offsetZ in { -6, 2, -14, 10 } do
			table.insert(candidates, { x = wantX, z = offsetZ })
		end
		for step = 4, half * 2, 4 do
			for _, dx in { -step, step } do
				for _, dz in { -6, 2, -14, 10, 6, -2 } do
					table.insert(candidates, { x = wantX + dx, z = dz })
				end
			end
		end

		for _, want in candidates do
			local at = grid:snap(want)
			if grid:fits(machineId, 0, at) then
				local placementId = string.format("%s:%d:%d", machineId, at.x, at.z)
				if grid:place(placementId, machineId, 0, at) then
					local model = Plots.spawnMachine(plotId, machineId, at, 0)
					Plots.built[plotId][placementId] = {
						placementId = placementId,
						machineId = machineId,
						x = at.x, z = at.z, rotation = 0,
						model = model,
					}
					placed += 1
					put = true
					break
				end
			end
		end

		if not put then
			Debug.warn(string.format(
				"[Plots] starter %s found no room on %s", machineId, plotId))
		end
	end

	return placed
end

--[[
	The plot layout, as data a profile can hold.

	`Plots.built` is server memory: it dies with the server, and the profile
	only ever recorded `machinesBuilt`, a counter. So a returning player got
	their coins back and an empty plot -- and because the counter was already
	four, the starter line never came either. They were left with money, no
	factory, and no way to get one.

	Nothing caught it for the obvious reason: every session before this one ran
	in MEMORY-ONLY mode, where nothing is saved and so nothing can come back
	wrong. The defect was introduced the moment the profile started persisting
	and was invisible until then.
]]
function Plots.snapshot(plotId: string): { { [string]: any } }
	local out = {}
	for _, entry in Plots.built[plotId] or {} do
		table.insert(out, {
			machineId = entry.machineId,
			x = entry.x, z = entry.z, rotation = entry.rotation,
		})
	end
	return out
end

--[[
	Rebuild a saved layout onto a plot.

	Goes through the grid rather than straight to `spawnMachine`, so a layout
	saved before a footprint changed is rejected cell by cell instead of
	producing machines that overlap. A piece that no longer fits is dropped and
	counted; losing one machine is recoverable, a corrupt grid is not.
]]
function Plots.restore(plotId: string, layout: { any }): (number, number)
	local grid = Plots.grids[plotId]
	if not grid or not layout then
		return 0, 0
	end

	local placed, dropped = 0, 0
	for _, want in layout do
		local machineId = tostring(want.machineId)
		if not Content.machines[machineId] then
			dropped += 1
			continue
		end
		local turn = tonumber(want.rotation) or 0
		local at = grid:snap({ x = tonumber(want.x) or 0, z = tonumber(want.z) or 0 })
		if not grid:fits(machineId, turn, at) then
			dropped += 1
			continue
		end
		local placementId = string.format("%s:%d:%d", machineId, at.x, at.z)
		if not grid:place(placementId, machineId, turn, at) then
			dropped += 1
			continue
		end
		local model = Plots.spawnMachine(plotId, machineId, at, turn)
		Plots.built[plotId][placementId] = {
			placementId = placementId,
			machineId = machineId,
			x = at.x, z = at.z, rotation = turn,
			model = model,
		}
		placed += 1
	end

	if dropped > 0 then
		Debug.warn(string.format(
			"[Plots] %s: %d saved machines no longer fit and were dropped", plotId, dropped))
	end
	return placed, dropped
end

function Plots.setActive(plotId: string, working: boolean)
	local plot = Plots.models[plotId]
	local container = plot and plot:FindFirstChild("Machines")
	if not container then
		return
	end
	for _, model in container:GetChildren() do
		if model:GetAttribute("active") ~= working then
			model:SetAttribute("active", working)
		end
	end
end

function Plots.spawnMachine(id: string, machineId: string, at: any, rotation: number): Model
	local machine = Content.machines[machineId]
	local plot = Plots.models[id]
	local origin = plot.Floor.CFrame

	local model = Instance.new("Model")
	model.Name = machineId

	local width = machine.footprintX * 4
	local depth = machine.footprintZ * 4
	if rotation % 180 ~= 0 then
		width, depth = depth, width
	end

	--[[
		A real model if a kit has one, and a box if not.

		The fallback is not a consolation prize — it is what makes the game
		runnable before anybody has licensed a single asset, and it is why the
		economy could be built and tested at all. But a tycoon made of four
		coloured boxes reads as a prototype however correct the simulation is,
		and no test in this repository can tell you that.
	]]
	--[[
		Real machinery first, a kit model second, a box last.

		`Machinery` builds the shape this game actually wants: one silhouette
		per role, with the one or two named children the client animates. It
		comes before the kit lookup because a licensed horror map has no drill
		in it -- `Catalog.fromKit("drill")` searched two hundred and fifty-seven
		harvested pieces and matched nothing but a clothing belt from a fighting
		game, so every machine fell through to the box.
	]]
	local built = Machinery.build(machineId, origin * CFrame.new(at.x, 0.5, at.z), rotation)
	if built then
		built:SetAttribute("plotId", id)
		local container = plot:FindFirstChild("Machines")
		if not container then
			local folder = Instance.new("Folder")
			folder.Name = "Machines"
			folder.Parent = plot
			container = folder
		end
		built.Parent = container
		return built
	end

	local dressed = Catalog.fromKit(machine.model or machineId)
	if dressed then
		dressed.Name = "Body"
		for _, descendant in dressed:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = true
			end
		end
		if dressed:IsA("Model") then
			dressed:PivotTo(origin * CFrame.new(at.x, 1.5, at.z)
				* CFrame.Angles(0, math.rad(rotation), 0))
		elseif dressed:IsA("BasePart") then
			(dressed :: BasePart).Anchored = true;
			(dressed :: BasePart).CFrame = origin * CFrame.new(at.x, 1.5, at.z)
		end
		dressed.Parent = model
		if dressed:IsA("BasePart") then
			model.PrimaryPart = dressed :: BasePart
		end
	else
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Size = Vector3.new(width - 0.4, machine.role == "source" and 6 or 3, depth - 0.4)
		body.CFrame = origin * CFrame.new(at.x, body.Size.Y / 2 + 0.5, at.z)
		body.Anchored = true
		body.Color = machine.colour
		body.Material = Enum.Material.Metal
		body.Parent = model
		model.PrimaryPart = body
	end

	Material.renderFidelity(model, Enum.RenderFidelity.Automatic)
	Mark.root(model, "machine", machineId)

	local container = plot:FindFirstChild("Machines")
	if not container then
		local folder = Instance.new("Folder")
		folder.Name = "Machines"
		folder.Parent = plot
		container = folder
	end
	model.Parent = container
	return model
end

function Plots.clear(id: string)
	for placementId, built in Plots.built[id] do
		if built.model then
			built.model:Destroy()
		end
		Plots.grids[id]:release(placementId)
	end
	Plots.built[id] = {}
end

--: What is standing on a plot, by role. The shape the production line wants.
function Plots.byRole(id: string): { [string]: number }
	local counts: { [string]: number } = { source = 0, carry = 0, refine = 0, sell = 0 }
	for _, built in Plots.built[id] or {} do
		local machine = Content.machines[built.machineId]
		if machine then
			counts[machine.role] = (counts[machine.role] or 0) + 1
		end
	end
	return counts
end

function Plots.describe(): { [string]: any }
	local owned, machines = 0, 0
	for id in Plots.models do
		if Plots.allocator:ownerOf(id) then
			owned += 1
		end
		for _ in Plots.built[id] or {} do
			machines += 1
		end
	end
	return {
		plots = Config.plots.count,
		owned = owned,
		machines = machines,
	}
end

return Plots
