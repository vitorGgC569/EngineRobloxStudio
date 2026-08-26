--!strict
--[[
	Machinery — machines that have moving parts, and are shaped like their job.

	What this replaces, and why the thing it replaces was defensible
	---------------------------------------------------------------

	`Plots.spawnMachine` built one coloured box per machine, and the comment
	above it made a real argument: a tycoon reads by silhouette and colour per
	role, and four distinct boxes tell a drill from a depot across the plot
	better than four detailed meshes that all look like machinery.

	That argument is still right. It was just answering a different question
	than the one the game had. A box tells you *which* machine it is; nothing
	tells you the machine is **working**. A tycoon is a genre you watch — the
	whole loop is standing in front of your line seeing ore move — and a line
	of static boxes with a number ticking above them is a spreadsheet with a
	skybox.

	So this keeps the silhouette rule and adds the only thing missing: parts
	that move. Each machine is still one clear shape per role, still one colour,
	and now has exactly one or two named children that the client animates.

	The split
	---------

	The server builds the geometry and names the moving parts by convention;
	the client animates them. Nothing here spins anything.

	That is not tidiness, it is bandwidth. A drill bit rotating at 4rad/s from
	the server is a CFrame replicated sixty times a second, per drill, to every
	player on the server -- for a detail nobody can see from another plot. Done
	on the client it costs one Heartbeat loop and replicates nothing, and it is
	*smoother*, because it never waits for a packet.

	The convention is the interface: a part named `Bit` spins, `Surface`
	scrolls, `RollerA`/`RollerB` roll, `Window` and `Beacon` pulse. Adding a
	machine means naming its parts, not editing the animator.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Material = Forge.Material
local Mark = Forge.Mark

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Content = require(Shared:WaitForChild("Content"))

local Machinery = {}

--: Read by the client animator to decide what a model does. An attribute
--: rather than the model name, because the name is the machine id and a
--: renamed machine should not stop moving.
Machinery.ROLE_ATTRIBUTE = "machineRole"

local function part(name: string, parent: Instance, size: Vector3, colour: Color3,
                   material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function darker(colour: Color3, amount: number): Color3
	return Color3.new(colour.R * amount, colour.G * amount, colour.B * amount)
end

-- ================================== drill ===================================
--[[
	Tall, with a bit that spins and throws dust.

	The bit is two stacked cylinders rather than a cone, because Roblox's
	built-in mesh types do not include one and a `FileMesh` would mean an asset
	id -- which is a dependency on somebody's upload for a shape that reads
	fine as a taper.
]]
local function buildDrill(model: Model, width: number, depth: number, colour: Color3)
	local base = part("Body", model, Vector3.new(width - 0.4, 1.6, depth - 0.4),
		darker(colour, 0.55), Enum.Material.DiamondPlate)
	base.CFrame = CFrame.new(0, 0.8, 0)
	model.PrimaryPart = base

	local mast = part("Mast", model, Vector3.new(1.4, 5.2, 1.4), colour, Enum.Material.Metal)
	mast.CFrame = CFrame.new(-width * 0.22, 4.2, 0)

	local head = part("Head", model, Vector3.new(width * 0.5, 1.2, depth * 0.5),
		colour, Enum.Material.Metal)
	head.CFrame = CFrame.new(width * 0.12, 5.4, 0)

	--: Named `Bit`, which is the whole contract with the animator.
	local bit = part("Bit", model, Vector3.new(1.5, 3.0, 1.5),
		darker(colour, 0.35), Enum.Material.Metal)
	bit.Shape = Enum.PartType.Cylinder
	-- Cylinders are born lying down; stand it up and keep that in the pivot so
	-- the client can spin it on its own Y without rediscovering this.
	bit.CFrame = CFrame.new(width * 0.12, 3.2, 0) * CFrame.Angles(0, 0, math.rad(90))
	bit.CanCollide = false

	local tip = part("Tip", model, Vector3.new(0.8, 1.2, 0.8),
		darker(colour, 0.25), Enum.Material.Metal)
	tip.Shape = Enum.PartType.Cylinder
	tip.CFrame = CFrame.new(width * 0.12, 1.6, 0) * CFrame.Angles(0, 0, math.rad(90))
	tip.CanCollide = false

	--[[
		Dust, emitted from the tip.

		Off by default and switched on by the animator only while the plot is
		actually producing. A drill throwing dust on a line that earns nothing
		is the game lying about itself, and a player who learns the animation
		means nothing stops reading it.
	]]
	local dust = Instance.new("ParticleEmitter")
	dust.Name = "Dust"
	dust.Rate = 14
	dust.Lifetime = NumberRange.new(0.5, 1.1)
	dust.Speed = NumberRange.new(2, 5)
	dust.SpreadAngle = Vector2.new(35, 35)
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(1, 1.6),
	})
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Color = ColorSequence.new(Color3.fromRGB(150, 138, 118))
	dust.Acceleration = Vector3.new(0, -6, 0)
	dust.Enabled = false
	dust.Parent = tip
end

-- ================================== belt ====================================
--[[
	Low and long, with a surface that scrolls and rollers that turn.

	The scroll is a `Texture` offset rather than moving parts along the belt:
	one property per frame instead of a dozen instances, and it never drifts
	out of sync with itself.
]]
local function buildBelt(model: Model, width: number, depth: number, colour: Color3)
	local frame = part("Body", model, Vector3.new(width - 0.4, 1.0, depth - 0.4),
		darker(colour, 0.5), Enum.Material.Metal)
	frame.CFrame = CFrame.new(0, 0.5, 0)
	model.PrimaryPart = frame

	local surface = part("Surface", model, Vector3.new(width - 1.0, 0.3, depth - 1.0),
		darker(colour, 0.28), Enum.Material.SmoothPlastic)
	surface.CFrame = CFrame.new(0, 1.15, 0)
	surface.CanCollide = false

	--[[
		The moving texture.

		`rbxasset://textures/...` is shipped inside the Roblox client rather
		than fetched from an account, so it cannot fail to load the way a
		harvested `rbxassetid://` does -- which is the whole reason every sound
		in the kits had to be blanked.
	]]
	local tread = Instance.new("Texture")
	tread.Name = "Tread"
	tread.Face = Enum.NormalId.Top
	--[[
		`textures/wall.png`, because it is one that exists.

		This pointed at `textures/SurfacesDefault/metal.png`, which does not --
		the path was written from memory and the belt's scrolling tread has been
		invisible ever since. Nothing showed it: a missing `Texture` is not an
		error, it simply draws nothing, and the belt still had its frame and its
		rollers so it never looked broken.

		`forge assets verify` found it on the first run that ever completed.
	]]
	tread.Texture = "rbxasset://textures/wall.png"
	tread.StudsPerTileU = 2
	tread.StudsPerTileV = 2
	tread.Transparency = 0.25
	tread.Parent = surface

	for index, offset in { -1, 1 } do
		local roller = part(index == 1 and "RollerA" or "RollerB", model,
			Vector3.new(0.9, 1.3, 1.3), darker(colour, 0.7), Enum.Material.Metal)
		roller.Shape = Enum.PartType.Cylinder
		roller.CFrame = CFrame.new(0, 1.0, offset * (depth * 0.5 - 0.9))
		roller.CanCollide = false
	end
end

-- ================================= smelter ==================================
--[[
	Bulky, with a window that breathes and a chimney that smokes.

	The window is the read: a smelter with a dark window is off, and a player
	can tell at fifty studs whether their line is stalled without opening a
	panel. That is the job an animation is actually for.
]]
local function buildSmelter(model: Model, width: number, depth: number, colour: Color3)
	local body = part("Body", model, Vector3.new(width - 0.4, 3.6, depth - 0.4),
		colour, Enum.Material.CorrodedMetal)
	body.CFrame = CFrame.new(0, 1.8, 0)
	model.PrimaryPart = body

	local window = part("Window", model, Vector3.new(width * 0.42, 1.2, 0.3),
		Color3.fromRGB(255, 150, 60), Enum.Material.Neon)
	window.CFrame = CFrame.new(0, 1.9, -(depth * 0.5) + 0.1)
	window.CanCollide = false

	local chimney = part("Chimney", model, Vector3.new(1.1, 3.4, 1.1),
		darker(colour, 0.6), Enum.Material.Metal)
	chimney.Shape = Enum.PartType.Cylinder
	chimney.CFrame = CFrame.new(width * 0.24, 5.2, depth * 0.2) * CFrame.Angles(0, 0, math.rad(90))
	chimney.CanCollide = false

	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "Smoke"
	smoke.Rate = 7
	smoke.Lifetime = NumberRange.new(1.8, 3.2)
	smoke.Speed = NumberRange.new(3, 6)
	smoke.SpreadAngle = Vector2.new(12, 12)
	smoke.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 4.5),
	})
	smoke.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	smoke.Color = ColorSequence.new(Color3.fromRGB(120, 118, 114))
	smoke.Acceleration = Vector3.new(0.6, 5, 0)
	smoke.Enabled = false
	smoke.Parent = chimney
end

-- ================================== depot ===================================
local function buildDepot(model: Model, width: number, depth: number, colour: Color3)
	local body = part("Body", model, Vector3.new(width - 0.4, 2.4, depth - 0.4),
		colour, Enum.Material.WoodPlanks)
	body.CFrame = CFrame.new(0, 1.2, 0)
	model.PrimaryPart = body

	local lid = part("Lid", model, Vector3.new(width - 0.2, 0.4, depth - 0.2),
		darker(colour, 0.7), Enum.Material.WoodPlanks)
	lid.CFrame = CFrame.new(0, 2.6, 0)
	lid.CanCollide = false

	--: Pulsed by the animator on every sale, so money leaving the plot has a
	--: place on screen where it visibly happens.
	local beacon = part("Beacon", model, Vector3.new(0.8, 0.8, 0.8),
		Color3.fromRGB(120, 230, 160), Enum.Material.Neon)
	beacon.Shape = Enum.PartType.Ball
	beacon.CFrame = CFrame.new(0, 3.2, 0)
	beacon.CanCollide = false
end

local BUILDERS: { [string]: (Model, number, number, Color3) -> () } = {
	source = buildDrill,
	carry = buildBelt,
	refine = buildSmelter,
	sell = buildDepot,
}

-- =================================== build ==================================
--[[
	One machine, positioned and marked.

	Returns nil for a role with no builder rather than inventing a shape, so a
	new role added to `Content` fails visibly here instead of appearing as an
	unexplained box on a plot.
]]
function Machinery.build(machineId: string, pivot: CFrame, rotation: number): Model?
	local machine = Content.machines[machineId]
	if not machine then
		return nil
	end
	local builder = BUILDERS[machine.role]
	if not builder then
		return nil
	end

	local width = machine.footprintX * 4
	local depth = machine.footprintZ * 4
	if rotation % 180 ~= 0 then
		width, depth = depth, width
	end

	local model = Instance.new("Model")
	model.Name = machineId
	builder(model, width, depth, machine.colour)

	-- Built at the origin and moved once, so every builder can write plain
	-- local coordinates and none of them has to know where the plot is.
	model:PivotTo(pivot * CFrame.Angles(0, math.rad(rotation), 0))
	model:SetAttribute(Machinery.ROLE_ATTRIBUTE, machine.role)
	model:SetAttribute("machineId", machineId)

	Material.renderFidelity(model, Enum.RenderFidelity.Automatic)
	Mark.root(model, "machine", machineId)
	return model
end

return Machinery
