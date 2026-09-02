--!strict
--[[
	Caches — the containers in the buildings, and what comes out of them.

	`Loot` holds the tables; this builds the boxes, decides who may open one,
	and drops what comes out on the floor beside it.

	Why the drop lands on the ground
	--------------------------------

	A container that pushes straight into your inventory is a button. One that
	spills a rifle at your feet makes you stand still for a second in a room
	somebody else might be walking towards, and that second is the entire
	reason a building is dangerous. It is also how a player learns to leave
	loot behind when they hear something.

	Cooldown, not depletion
	-----------------------

	A cache that empties permanently makes the map worse over a session: by
	minute twenty the buildings are furniture. A respawn measured in minutes
	keeps them worth returning to and keeps a fight over one meaningful.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Arsenal = require(ReplicatedStorage.Shared.Arsenal)
local Guns = require(script.Parent.Guns)
local Loot = require(ReplicatedStorage.Shared.Loot)

local Rng = Forge.Core.Rng

local Caches = {}

local stream = Rng.stream("holdout.caches")
local containers: { [BasePart]: any } = {}
local drops: { [string]: any } = {}
local folder: Folder? = nil
local nextDrop = 0

Caches.REACH = 14

--: How long a spilled item waits before it is cleaned up. Long enough to walk
--: back for, short enough that a building does not become a carpet.
Caches.DROP_LIFE = 150

local LOOK = {
	crate = { size = Vector3.new(4.4, 3.2, 3), colour = Color3.fromRGB(104, 88, 62),
		material = Enum.Material.Wood, variant = "PlankFloor" },
	locker = { size = Vector3.new(3.2, 8, 2.4), colour = Color3.fromRGB(96, 104, 100),
		material = Enum.Material.Metal, variant = "RustPlate" },
	case = { size = Vector3.new(5.2, 2.6, 3.4), colour = Color3.fromRGB(64, 72, 78),
		material = Enum.Material.Metal, variant = "RustPlate" },
}

local KIND_COLOUR = {
	gun = Color3.fromRGB(226, 176, 82),
	ammo = Color3.fromRGB(158, 168, 184),
	heal = Color3.fromRGB(206, 96, 96),
	armour = Color3.fromRGB(120, 176, 214),
}

-- ================================ the boxes =================================
local function label(part: BasePart, text: string)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Tag"
	gui.Size = UDim2.fromOffset(150, 24)
	gui.StudsOffsetWorldSpace = Vector3.new(0, part.Size.Y / 2 + 1.6, 0)
	gui.AlwaysOnTop = false
	--: Fifty studs. A tag readable across the valley turns looting into a
	--: shopping list and removes every reason to enter a building.
	gui.MaxDistance = 50
	gui.Parent = part
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = text
	--: A fixed size, not scaled. A `BillboardGui` grows as you approach it, so
	--: `TextScaled` on one produces a name three feet tall when you are
	--: standing next to the box -- which is what the first build looked like.
	t.TextScaled = false
	t.TextSize = 15
	t.TextStrokeTransparency = 0.35
	t.TextColor3 = Color3.fromRGB(232, 230, 222)
	t.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
		Enum.FontWeight.Bold)
	t.Parent = gui
	return t
end

function Caches.place(kind: string, cf: CFrame, parent: Instance): BasePart?
	local spec = Loot.container(kind)
	local look = LOOK[kind]
	if not (spec and look) then
		return nil
	end
	local box = Instance.new("Part")
	box.Name = "Cache"
	box.Size = look.size
	box.CFrame = cf * CFrame.new(0, look.size.Y / 2, 0)
	box.Anchored = true
	box.Color = look.colour
	box.Material = look.material
	box.MaterialVariant = look.variant
	box.TopSurface = Enum.SurfaceType.Smooth
	box.BottomSurface = Enum.SurfaceType.Smooth
	box:SetAttribute("cache", kind)
	box.Parent = parent

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Open"
	prompt.ActionText = "Search"
	prompt.ObjectText = spec.label
	prompt.HoldDuration = 0.85
	prompt.MaxActivationDistance = Caches.REACH
	prompt.RequiresLineOfSight = false
	prompt.Parent = box

	containers[box] = { kind = kind, spec = spec, readyAt = 0, prompt = prompt,
		tag = label(box, spec.label) }
	return box
end

-- ================================ the spill =================================
local function spill(drop: any, at: Vector3, parent: Instance)
	nextDrop += 1
	local id = "d" .. nextDrop

	local yaw = stream:number(0, 6.28)
	local item = Instance.new("Part")
	item.Name = "Drop"
	item.Size = if drop.kind == "gun" then Vector3.new(3.4, 0.6, 1)
		else Vector3.new(1.6, 1.2, 1.2)
	item.CFrame = CFrame.new(at) * CFrame.Angles(0, yaw, 0)
	item.Anchored = true
	item.CanCollide = false
	item.Color = KIND_COLOUR[drop.kind] or Color3.fromRGB(180, 180, 180)
	item.Material = Enum.Material.Metal
	item:SetAttribute("drop", id)
	item.Parent = parent

	--[[
		A dropped gun is drawn as that gun.

		The part stays -- it carries the `drop` attribute and the prompt, and
		moving those onto a catalogue model would mean the interaction code
		having to care what shape the loot is. It just turns invisible and the
		real weapon sits where it was.

		Recognising an M24 on the floor from across a room is the whole reason
		to walk into a building, and a grey box cannot be recognised from
		anywhere.
	]]
	if drop.kind == "gun" then
		local model = Guns.lay(drop.id, at, yaw, parent)
		if model then
			item.Transparency = 1
			model.Parent = item
		end
	end

	local gun = if drop.kind == "gun" then Arsenal.get(drop.id) else nil
	local name = if gun then gun.name
		elseif drop.amount then string.format("%s x%d", drop.id, drop.amount)
		else drop.id
	label(item, name)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Take"
	prompt.ActionText = "Take"
	prompt.ObjectText = name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = item

	drops[id] = { drop = drop, part = item, at = os.clock() }
	task.delay(Caches.DROP_LIFE, function()
		if drops[id] then
			drops[id] = nil
			item:Destroy()
		end
	end)
	return id
end

--[[
	Open one, if it is yours to open.

	Every refusal has a reason, and the reasons are different on purpose: "too
	far" is a player misjudging reach, "still empty" is one who has to wait,
	and telling them apart is the difference between a bug report and a player
	learning the rules.
]]
function Caches.open(character: Model?, box: BasePart): (boolean, any)
	local record = containers[box]
	if not record then
		return false, "nothing to search"
	end
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return false, "no character"
	end
	if (root.Position - box.Position).Magnitude > Caches.REACH + 6 then
		return false, "too far"
	end
	local now = os.clock()
	if now < record.readyAt then
		return false, string.format("empty for another %ds",
			math.ceil(record.readyAt - now))
	end
	record.readyAt = now + record.spec.respawn

	local found = Loot.open(record.spec, function()
		return stream:number(0, 1)
	end)
	local ids = {}
	for index, drop in found do
		local angle = (index / #found) * math.pi * 2
		local at = box.Position + Vector3.new(
			math.sin(angle) * 3.4, -box.Size.Y / 2 + 0.6, math.cos(angle) * 3.4)
		table.insert(ids, spill(drop, at, box.Parent or Workspace))
	end

	--: The box goes quiet rather than vanishing, so a player can see it is
	--: theirs to come back to.
	record.prompt.Enabled = false
	record.tag.Text = record.spec.label .. " (empty)"
	task.delay(record.spec.respawn, function()
		if containers[box] then
			record.prompt.Enabled = true
			record.tag.Text = record.spec.label
		end
	end)
	return true, { found = found, drops = ids }
end

function Caches.take(character: Model?, id: string): (boolean, any)
	local record = drops[id]
	if not record then
		return false, "it is gone"
	end
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart"))
			or (root.Position - record.part.Position).Magnitude > 14 then
		return false, "too far"
	end
	drops[id] = nil
	record.part:Destroy()
	return true, record.drop
end

--[[
	Stock a building.

	One case, one locker and three crates, placed against the walls rather than
	in the middle. A cache in the centre of a room is a cache you can loot
	while watching every door; against a wall you have to turn your back on
	one.
]]
function Caches.stock(ruin: Model, parent: Instance): number
	local floor = ruin:FindFirstChild("Floor")
	if not (floor and floor:IsA("BasePart")) then
		return 0
	end
	local base = floor.CFrame
	local layout = {
		{ kind = "case", offset = Vector3.new(-12, 0.5, -10), yaw = 0.4 },
		{ kind = "locker", offset = Vector3.new(13, 0.5, -11), yaw = -0.3 },
		{ kind = "crate", offset = Vector3.new(-14, 0.5, 6), yaw = 1.1 },
		{ kind = "crate", offset = Vector3.new(11, 0.5, 8), yaw = -0.8 },
		{ kind = "crate", offset = Vector3.new(0, 0.5, -11), yaw = 0.1 },
	}
	local placed = 0
	for _, spot in layout do
		local cf = base * CFrame.new(spot.offset) * CFrame.Angles(0, spot.yaw, 0)
		if Caches.place(spot.kind, cf, parent) then
			placed += 1
		end
	end
	return placed
end

function Caches.build(world: Instance): number
	folder = Instance.new("Folder")
	folder.Name = "Caches"
	folder.Parent = world
	local total = 0
	for _, child in world:GetChildren() do
		if child:IsA("Model") and child.Name == "Ruin" then
			total += Caches.stock(child, folder :: Folder)
		end
	end
	return total
end

function Caches.cacheAt(part: BasePart): any?
	return containers[part]
end

function Caches.describe(): { [string]: any }
	local boxes, live = 0, 0
	for _ in containers do
		boxes += 1
	end
	for _ in drops do
		live += 1
	end
	return { caches = boxes, onFloor = live, tables = Loot.describe() }
end

return Caches
