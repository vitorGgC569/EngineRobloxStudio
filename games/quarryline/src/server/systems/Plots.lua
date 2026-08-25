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
local Boot = Forge.Core.Boot

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local PlotAllocator = require(ReplicatedStorage.Forge.Tycoon.PlotAllocator)
local GridPlacement = require(ReplicatedStorage.Forge.Tycoon.GridPlacement)
local PlotPermissions = require(ReplicatedStorage.Forge.Social.PlotPermissions)

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

	local claim = Instance.new("Part")
	claim.Name = "Claim"
	claim.Size = Vector3.new(4, 8, 4)
	claim.CFrame = CFrame.new(origin + Vector3.new(0, 4.5, -size / 2 + 3))
	claim.Anchored = true
	claim.Color = Color3.fromRGB(210, 176, 96)
	claim.Material = Enum.Material.Neon
	claim.Parent = model

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
			cellSize = 4,
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
function Plots.place(player: Player, machineId: string, x: number, z: number, rotation: number?)
	: (boolean, string?)
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
	local at = grid:snap({ x = x, z = z })
	if not grid:fits(machineId, turn, at) then
		return false, "that does not fit there"
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
	return true
end

--[[
	The part that represents a machine.

	Deliberately plain geometry rather than a catalogue model. A tycoon reads
	by *silhouette and colour per role* — a player has to tell a drill from a
	depot across the plot at a glance — and four distinctly coloured boxes do
	that better than four detailed meshes that all look like machinery.
]]
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
