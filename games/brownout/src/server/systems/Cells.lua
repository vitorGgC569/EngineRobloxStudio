--!strict
--[[
	Cells — the fuel out in the dark, and the act of carrying it home.

	The whole game is one decision made over and over: which ring do I run to.
	Ring one is close and pays badly, ring three is a long way out through
	unlit ground and pays for a third of the night. Everything in this file
	exists to make that decision legible and to make the client unable to cheat
	its outcome.

	Two design notes worth keeping.

	**A cell is visible from further than it is reachable.** Each one carries a
	neon wisp — a thin glowing column six studs tall. Without it the far rings
	are a fog wall you walk into hoping, and hunting for an unlit object in an
	unlit field is not tension, it is a chore. The wisp is what turns the dark
	into a map with landmarks on it.

	**The client never names the cell it wants.** `Grab` carries no id. The
	server takes the player's own character position, finds the nearest
	available cell within range, and picks that one. An id from the client is an
	id the client can change, and the exploit writes itself: send the id of the
	ring-three cell while standing on ring one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local World = Forge.World
local Net = Forge.Net
local Mark = Forge.Mark
local Boot = Forge.Core.Boot
local Audio = Forge.Audio

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Shift = require(script.Parent.Parent:WaitForChild("core"):WaitForChild("Shift"))

local Cells = {}

export type Cell = {
	ring: any,
	model: Model,
	core: BasePart,
	--: Where it sits when nobody has it. A dropped cell overwrites this, which
	--: is how a chain of players can relay one home across the dark.
	home: Vector3,
	--: The player carrying it, or nil.
	holder: Player?,
	--: Set while it is respawning, so the tick does not offer it to anybody.
	available: boolean,
}

local cells: { Cell } = {}
Cells.list = cells

-- ================================ building ==================================
local function colourOf(rgb: { number }): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

--[[
	One cell: a canister, a glowing core, and a wisp you can see from the pad.

	The canister is a baked store barrel rather than a box, for the same reason
	everything else here is: the moment one object in a scene is an untextured
	primitive, the eye finds it and the scene stops reading as a place.
]]
local function buildCell(ring: any, position: Vector3, container: Instance): Cell
	local colour = colourOf(ring.color)

	local model = Instance.new("Model")
	model.Name = string.format("Cell%d", ring.grade)
	--: An attribute rather than parsing the name on the client. A name is a
	--: label for a person reading the explorer; an attribute is a value, it
	--: replicates on its own, and it does not break when the name changes.
	model:SetAttribute("Grade", ring.grade)

	--: The core is the model's PrimaryPart and the thing that gets welded to a
	--: carrier, so everything else in the cell hangs off a part this code owns
	--: rather than off whatever the store model happened to call its root.
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(2.4, 2.4, 2.4)
	core.CFrame = CFrame.new(position + Vector3.new(0, 2.2, 0))
	core.Anchored = true
	core.CanCollide = false
	core.CastShadow = false
	core.Material = Enum.Material.Neon
	core.Color = colour
	core.Parent = model
	model.PrimaryPart = core

	local light = Instance.new("PointLight")
	light.Brightness = 2.2
	light.Range = 26
	light.Color = colour
	light.Shadows = false
	light.Parent = core

	--: The wisp. Long, thin, unlit-by-anything, and the reason the far rings
	--: are navigable at all.
	local wisp = Instance.new("Part")
	wisp.Name = "Wisp"
	wisp.Size = Vector3.new(0.5, 7, 0.5)
	wisp.CFrame = core.CFrame * CFrame.new(0, 4.4, 0)
	wisp.Anchored = true
	wisp.CanCollide = false
	wisp.CastShadow = false
	wisp.Material = Enum.Material.Neon
	wisp.Color = colour
	wisp.Transparency = 0.42
	wisp.Parent = model

	model.Parent = container
	Mark.exclude(core)
	Mark.exclude(wisp)

	--: The model's own pivot, set explicitly. `GetExtentsSize` and `PivotTo`
	--: both answer relative to it, and an inherited pivot is rotated often
	--: enough that trusting the default is how a carried cell ends up sideways.
	model.WorldPivot = core.CFrame

	return {
		ring = ring,
		model = model,
		core = core,
		home = position,
		holder = nil,
		available = true,
	}
end

--[[
	A point on a ring, jittered.

	Perfectly even spacing makes the field read as a machine and, worse, makes
	it optimal: a player learns the angle and stops looking. The jitter is
	seeded, so the layout is still reproducible.
]]
local function pointOnRing(ring: any, index: number, count: number, rand: Random): Vector3?
	local base = (index - 1) / count * math.pi * 2
	local angle = base + rand:NextNumber(-0.4, 0.4) * (math.pi * 2 / count)
	local radius = ring.radius + rand:NextNumber(-24, 24)
	local x, z = math.cos(angle) * radius, math.sin(angle) * radius
	return World.surface(x, z)
end

local respawnRand = Random.new(Config.seed + 4242)

local function buildField(container: Instance)
	local rand = Random.new(Config.seed + 99)
	for _, ring in Config.cells.rings do
		for index = 1, ring.count do
			local at = pointOnRing(ring, index, ring.count, rand)
			if at then
				table.insert(cells, buildCell(ring, at, container))
			end
		end
	end
	Debug.info(string.format("%d fuel cells across %d rings", #cells, #Config.cells.rings))
end

-- ================================ carrying ==================================
local function characterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--[[
	Put a cell in a player's hands.

	Welded rather than CFramed every tick. A server that repositions a carried
	object thirty times a second is thirty replication packets a second per
	carrier, and it arrives on the client one frame behind the character it is
	supposed to be attached to, which reads as the cell swimming. A weld makes
	it the character's problem, and the character is already network-owned by
	the client that is moving it.
]]
local function attach(cell: Cell, player: Player): boolean
	local root = characterRoot(player)
	if not root then
		return false
	end

	cell.holder = player
	cell.available = false

	--: Unanchored, massless, non-colliding. All three matter: a weld to an
	--: anchored part does nothing, mass on a character changes how it walks,
	--: and collision on a carried object catches on doorframes and the floor.
	for _, part in cell.model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.Massless = true
		end
	end

	cell.model:PivotTo(root.CFrame * CFrame.new(0, 1.6, -2.2))
	cell.model.Parent = player.Character

	local weld = Instance.new("WeldConstraint")
	weld.Name = "CarryWeld"
	weld.Part0 = root
	weld.Part1 = cell.core
	weld.Parent = cell.core

	--: The wisp is welded to the core rather than to the character, so the
	--: whole cell moves as one object instead of as two things that agree.
	for _, part in cell.model:GetDescendants() do
		if part:IsA("BasePart") and part ~= cell.core then
			local link = Instance.new("WeldConstraint")
			link.Part0 = cell.core
			link.Part1 = part
			link.Parent = part
		end
	end

	local state = Shift.crewOf(player)
	state.carrying = cell.ring
	state.carried = cell.model
	return true
end

--[[
	Take a cell out of a player's hands and stand it on the ground.

	`at` nil means "wherever they are". Used for a deliberate drop, for a player
	who dies holding one, and for a player who leaves — all three must return
	the cell to the world rather than delete it, or a busy server slowly runs
	out of fuel through nothing but disconnects.
]]
local function detach(cell: Cell, at: Vector3?)
	local player = cell.holder
	cell.holder = nil

	for _, part in cell.model:GetDescendants() do
		if part:IsA("WeldConstraint") then
			part:Destroy()
		end
	end

	local ground = at
	if ground then
		ground = World.surface(ground.X, ground.Z) or ground
	end
	cell.home = ground or cell.home

	cell.model.Parent = Workspace:FindFirstChild("Cells") or Workspace
	cell.model:PivotTo(CFrame.new(cell.home + Vector3.new(0, 2.2, 0)))

	for _, part in cell.model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.Massless = false
		end
	end
	cell.available = true

	if player then
		local state = Shift.crewOf(player)
		state.carrying = nil
		state.carried = nil
	end
end

Cells.detach = detach

--[[
	Consume a cell and put it back on its ring later.

	Respawn matters more than it looks. Without it the field empties and the
	night becomes arithmetically unwinnable; with a fast one nobody ever has a
	reason to leave ring one. The delay in Config is the dial between those.
]]
local function consume(cell: Cell)
	local player = cell.holder
	cell.holder = nil
	cell.available = false

	--: Unwelded before it is parented away. A WeldConstraint whose Part1 leaves
	--: the world is not an error, and it is still a live constraint pointing at
	--: a character that will respawn without it — cheap to clear, expensive to
	--: find later.
	for _, part in cell.model:GetDescendants() do
		if part:IsA("WeldConstraint") then
			part:Destroy()
		end
	end
	cell.model.Parent = nil

	if player then
		local state = Shift.crewOf(player)
		state.carrying = nil
		state.carried = nil
	end

	task.delay(Config.cells.respawnSeconds, function()
		--: A different point on the same ring, so the field reshuffles across a
		--: night instead of players memorising twenty-one fixed spots.
		local at = pointOnRing(cell.ring, respawnRand:NextInteger(1, cell.ring.count), cell.ring.count, respawnRand)
		cell.home = at or cell.home
		cell.model:PivotTo(CFrame.new(cell.home + Vector3.new(0, 2.2, 0)))
		for _, part in cell.model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
		cell.model.Parent = Workspace:FindFirstChild("Cells") or Workspace
		cell.available = true
	end)
end

Cells.consume = consume

--: The cell a player is holding, or nil. Linear over ~21 cells; a map keyed by
--: player would be a second copy of the same fact and a second thing to keep
--: in step.
function Cells.heldBy(player: Player): Cell?
	for _, cell in cells do
		if cell.holder == player then
			return cell
		end
	end
	return nil
end

local function nearestAvailable(position: Vector3, maxDistance: number): Cell?
	local best: Cell? = nil
	local bestDistance = maxDistance
	for _, cell in cells do
		if not cell.available or cell.holder then
			continue
		end
		local distance = (cell.core.Position - position).Magnitude
		if distance < bestDistance then
			best = cell
			bestDistance = distance
		end
	end
	return best
end

-- ============================== the wire ====================================
--[[
	Put the nearest available cell in a player's hands, or say why not.

	Exported because it is the whole verb of the game and the live suite has to
	be able to exercise it. The `Grab` handler below is a thin wrapper that adds
	the two toasts — which means the scenario runs the same code path the packet
	does rather than a parallel one written to be testable.
]]
function Cells.grabFor(player: Player): (boolean, string)
	if Cells.heldBy(player) then
		return false, "Hands full."
	end
	local root = characterRoot(player)
	if not root then
		return false, "No character."
	end
	local cell = nearestAvailable(root.Position, Config.cells.pickupRange)
	if not cell then
		return false, "Nothing in reach."
	end
	if not attach(cell, player) then
		return false, "Could not lift it."
	end
	--: Positional, so a teammate two hundred studs out hears you working.
	Audio.playAt("cue.lift", cell.core.Position)
	return true, "Lifted."
end

local function onGrab(player: Player)
	--: One pair of hands, one cell. An inventory would turn a run into a
	--: shopping trip and delete the risk curve the rings exist to create.
	local ok, reason = Cells.grabFor(player)
	if ok then
		Net.fire(player, "You", Shift.crewSnapshot(player))
	else
		Net.fire(player, "Notify", { text = reason, tone = "warn" })
	end
end

local function onDrop(player: Player)
	local cell = Cells.heldBy(player)
	if not cell then
		return
	end
	local root = characterRoot(player)
	detach(cell, root and root.Position or nil)
	Net.fire(player, "You", Shift.crewSnapshot(player))
end

function Cells.start()
	Net.on("Grab", onGrab)
	Net.on("Drop", onDrop)

	--[[
		A player who dies or leaves holding a cell drops it where they stood.

		Deleting it instead would be simpler and would slowly starve the server:
		twenty disconnects into a session there is no ring three left. Dropping
		it also makes dying out in the dark a story rather than a reset — the
		cell is still out there, and somebody has to go and get it.
	]]
	local function releaseFor(player: Player)
		local cell = Cells.heldBy(player)
		if cell then
			local root = characterRoot(player)
			detach(cell, root and root.Position or nil)
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		releaseFor(player)
		Shift.forgetCrew(player)
	end)

	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid") :: Humanoid
			humanoid.Died:Connect(function()
				releaseFor(player)
			end)
		end)
	end
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerAdded:Connect(watch)

	task.spawn(function()
		if not Boot.await("ground_ready", 120) then
			Debug.error("cells gave up waiting for ground; the field is empty")
			return
		end
		buildField(Workspace:FindFirstChild("Cells") or Workspace)
		Boot.signal("cells_ready")
	end)
end

return Cells
