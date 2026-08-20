--!strict
--[[
	Editor.Gizmo — the 3D manipulators.

	                 Y
	                 ↑
	                 │
	            ─────●─────→ X
	                ╱
	               ╱
	              Z

	This is the difference between a tool and an admin panel. Nudging with arrow
	keys is fine for a final half-stud; placing a camp means grabbing a handle
	and dragging it, and no amount of keyboard shortcuts substitutes for that.

	Built on Roblox's own `Handles` and `ArcHandles`, which render real
	depth-sorted 3D manipulators and give back drag distances in world units —
	so this file is mostly about turning those into editor operations.

	Three modes, one keystroke apart:

	  move    W    axis arrows
	  rotate  E    orbit rings
	  scale   R    resize handles

	Multi-select is why the handles are adorned to a proxy part at the selection
	centre rather than to a placement's own model: dragging then moves the whole
	set together, and rotation happens about the group's middle.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Forge = require(script.Parent.Parent)
local Net = Forge.Net
local Trove = Forge.Core.Trove

local Gizmo = {}

local mode = "move"
local proxy: BasePart? = nil
local moveHandles: Handles? = nil
local scaleHandles: Handles? = nil
local rotateHandles: ArcHandles? = nil
local mounted = false
local dragOrigin = 0
local dragAngle = 0
local anchor: Vector3? = nil
-- Destroying the handles disconnects their events, but relying on that means
-- unmount order decides whether a stale drag can still fire. The trove makes it
-- explicit and independent of destruction order.
local trove = Trove.new()

Gizmo.config = {
	color = BrickColor.new("Deep orange"),
	rotateColor = BrickColor.new("Cyan"),
	scaleColor = BrickColor.new("Lime green"),
	transparency = 0.35,
	scaleStep = 0.1,
}

local function send(op: string, data: any?)
	Net.send("EditorOp", { op = op, data = data or {} })
end

-- ================================== proxy ===================================
--[[
	An invisible part the handles attach to.

	Adorning directly to a selected model breaks the moment two things are
	selected, and Roblox has no notion of a multi-adornee. A proxy at the centre
	of the selection is the standard answer and also gives rotation a sensible
	pivot for free.
]]
local function ensureProxy(): BasePart
	-- `if proxy and proxy.Parent` was wrong: hiding the gizmo unparents the
	-- proxy, and the next call then built a *new* part while the handles'
	-- Adornee still pointed at the orphaned one. The handles adorned nothing
	-- and rendered nothing, with no error anywhere. One part for the module's
	-- lifetime; visibility is the parent, not the identity.
	if proxy then
		return proxy
	end
	local part = Instance.new("Part")
	part.Name = "ForgeGizmoProxy"
	part.Size = Vector3.one * 2
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Locked = true
	part.Parent = Workspace
	proxy = part
	return part
end

-- ================================== modes ===================================
local function applyMode()
	if moveHandles then
		moveHandles.Visible = mode == "move"
	end
	if rotateHandles then
		rotateHandles.Visible = mode == "rotate"
	end
	if scaleHandles then
		scaleHandles.Visible = mode == "scale"
	end
end

function Gizmo.setMode(next_: string)
	if next_ ~= "move" and next_ ~= "rotate" and next_ ~= "scale" then
		return
	end
	mode = next_
	applyMode()
end

function Gizmo.mode(): string
	return mode
end

-- ================================= placement ================================
--[[
	Point the gizmo at a world position, or hide it.

	Called whenever the selection changes. `nil` means nothing is selected, and
	a gizmo floating over nothing is worse than no gizmo.
]]
function Gizmo.setTarget(position: Vector3?)
	anchor = position
	if not position then
		if proxy then
			proxy.Parent = nil
		end
		return
	end
	local part = ensureProxy()
	part.Parent = Workspace
	part.CFrame = CFrame.new(position)
	applyMode()
end

function Gizmo.refresh()
	if anchor and proxy then
		proxy.CFrame = CFrame.new(anchor)
	end
end

-- ================================== mount ===================================
--[[
	`parent` must be the PlayerGui itself, not a Frame inside a ScreenGui.

	`Handles` and `ArcHandles` are GuiBase3d adornments. Parented into a 2D GUI
	hierarchy they are accepted, never render, and never fire a drag — the
	feature looks wired from the code and does not exist in the world. Only
	querying the running session for the instances found it.
]]
function Gizmo.mount(parent: Instance)
	if mounted or not RunService:IsClient() then
		return
	end
	if parent:IsA("GuiObject") then
		local gui = parent:FindFirstAncestorWhichIsA("PlayerGui")
		if not gui then
			warn("[Gizmo] mount needs a PlayerGui; adornments do not render inside a Frame")
			return
		end
		parent = gui
	end
	mounted = true

	local part = ensureProxy()
	part.Parent = nil -- hidden until something is selected; same part throughout

	-- ---------------------------------------------------------------- move
	local move = Instance.new("Handles")
	move.Adornee = part
	move.Style = Enum.HandlesStyle.Movement
	move.Color3 = Gizmo.config.color.Color
	move.Transparency = Gizmo.config.transparency
	move.Visible = false
	move.Parent = parent
	moveHandles = move

	trove:connect(move.MouseButton1Down, function()
		dragOrigin = 0
	end)

	--[[
		`distance` is cumulative from where the drag began, not per-frame. Sending
		it straight through would move the selection by the total each frame and
		the piece would accelerate off the map; the delta is what the editor wants.
	]]
	trove:connect(move.MouseDrag, function(face, distance)
		local delta = distance - dragOrigin
		dragOrigin = distance
		if math.abs(delta) < 0.001 then
			return
		end
		local direction = Vector3.FromNormalId(face)
		send("nudge", { delta = { direction.X * delta, direction.Y * delta, direction.Z * delta } })
	end)

	trove:connect(move.MouseButton1Up, function()
		dragOrigin = 0
		send("ground_if_snapped")
	end)

	-- -------------------------------------------------------------- rotate
	local rotate = Instance.new("ArcHandles")
	rotate.Adornee = part
	rotate.Color3 = Gizmo.config.rotateColor.Color
	rotate.Transparency = Gizmo.config.transparency
	rotate.Visible = false
	rotate.Parent = parent
	rotateHandles = rotate

	trove:connect(rotate.MouseButton1Down, function()
		dragAngle = 0
	end)

	trove:connect(rotate.MouseDrag, function(axis, relativeAngle, _deltaRadius)
		local delta = relativeAngle - dragAngle
		dragAngle = relativeAngle
		if math.abs(delta) < 0.0005 then
			return
		end
		local name = axis == Enum.Axis.X and "x" or axis == Enum.Axis.Z and "z" or "y"
		send("rotate", { degrees = math.deg(delta), axis = name })
	end)

	trove:connect(rotate.MouseButton1Up, function()
		dragAngle = 0
	end)

	-- --------------------------------------------------------------- scale
	local scale = Instance.new("Handles")
	scale.Adornee = part
	scale.Style = Enum.HandlesStyle.Resize
	scale.Color3 = Gizmo.config.scaleColor.Color
	scale.Transparency = Gizmo.config.transparency
	scale.Visible = false
	scale.Parent = parent
	scaleHandles = scale

	trove:connect(scale.MouseButton1Down, function()
		dragOrigin = 0
	end)

	--[[
		Scale is uniform, whichever handle is dragged.

		Non-uniform scale on a Roblox model is not expressible through `ScaleTo`,
		and faking it by resizing parts breaks every weld inside. Offering an
		axis handle that silently scales uniformly is less honest than offering
		one behaviour that always does what it says.
	]]
	trove:connect(scale.MouseDrag, function(_face, distance)
		local delta = distance - dragOrigin
		dragOrigin = distance
		if math.abs(delta) < 0.05 then
			return
		end
		local factor = 1 + math.clamp(delta, -2, 2) * Gizmo.config.scaleStep
		send("scale", { factor = factor })
	end)

	trove:connect(scale.MouseButton1Up, function()
		dragOrigin = 0
	end)

	applyMode()
end

function Gizmo.unmount()
	trove:clean()
	for _, handle in { moveHandles, rotateHandles, scaleHandles } do
		if handle then
			handle:Destroy()
		end
	end
	moveHandles, rotateHandles, scaleHandles = nil, nil, nil
	if proxy then
		proxy:Destroy()
		proxy = nil
	end
	mounted = false
end

function Gizmo.describe(): { [string]: any }
	return {
		mounted = mounted,
		mode = mode,
		targeted = anchor ~= nil,
	}
end

return Gizmo
