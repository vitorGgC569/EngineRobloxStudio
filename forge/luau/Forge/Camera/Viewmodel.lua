--!strict
--[[
	Viewmodel — the weapon in your hands, that never clips into a wall.

	The problem every first-person game hits
	----------------------------------------

	Weld a gun to the camera and walk up to a wall. The barrel goes through it.
	Everybody's first fix is to shorten the gun or push it back, which makes it
	look wrong from every angle to fix one. The second fix is to raycast and
	pull it in, which makes it lurch.

	The actual answer, and the one every shooter uses, is that the view weapon
	is **not in the world**. It is drawn afterwards, in its own pass, with its
	own near plane — so it cannot intersect world geometry because it was never
	tested against it.

	Roblox has no depth-range control, so the equivalent is a `ViewportFrame`
	laid over the screen with its own `Camera`. The gun lives in that frame's
	`WorldModel`, the frame's camera mirrors the real one, and the gun is drawn
	on top of a world it is not part of.

		local view = Viewmodel.mount(playerGui)
		Viewmodel.hold(view, weaponModel)
		Viewmodel.step(view, dt, moveSpeed, lookDelta)   -- bob and sway

	What you give up, and it is worth it
	------------------------------------

	A `ViewportFrame` lights its contents with `Ambient` only — no sun, no
	shadows, no `SurfaceAppearance` tint on textured meshes. So the gun is lit
	by one colour, and the way to make it belong to the room is to drive that
	colour from the room's light level rather than to leave it white.

	That is a real limitation and it is the price of a gun that behaves. Every
	first-person game on this platform pays it.
]]

local Viewmodel = {}

export type View = {
	gui: ScreenGui,
	frame: ViewportFrame,
	world: WorldModel,
	camera: Camera,
	held: Model?,
	bobPhase: number,
	sway: Vector2,
}

--[[
	How much narrower the gun's field of view is than the world's.

	Quake used 0.82 and it has been copied ever since, for a reason worth
	knowing: a gun rendered at the world's FOV looks distorted at the edges of
	a wide screen, because it is close to the camera where perspective is
	strongest. Narrowing its own projection keeps it looking like an object
	rather than a fisheye.
]]
Viewmodel.fieldOfViewRatio = 0.82

--: How far the gun swings when the view turns. A weapon nailed rigidly to the
--: camera reads as a decal on the screen; a little lag reads as weight.
Viewmodel.swayStuds = 0.6
Viewmodel.swayRecover = 8

--: Walk bob. Small — this is the effect most often overdone, and a gun that
--: bounces an inch reads as the player skipping.
Viewmodel.bobStuds = 0.05
Viewmodel.bobRate = 1.4

-- =================================== mount ==================================
function Viewmodel.mount(parent: Instance, options: any?): View
	local opts = options or {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "ForgeViewmodel"
	gui.IgnoreGuiInset = true
	-- Above the world and below every piece of interface. A gun drawn over
	-- the HUD covers the crosshair, which is the one thing that must never be
	-- covered.
	gui.DisplayOrder = tonumber(opts.displayOrder) or 4
	gui.ResetOnSpawn = false
	gui.Parent = parent

	local frame = Instance.new("ViewportFrame")
	frame.Name = "View"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	-- The light level rides here: viewport contents take no world lighting, so
	-- this tint is the only way the gun can be dark in a dark room.
	frame.ImageColor3 = Color3.new(1, 1, 1)
	frame.Parent = gui

	local world = Instance.new("WorldModel")
	world.Parent = frame

	local camera = Instance.new("Camera")
	camera.Parent = frame
	frame.CurrentCamera = camera

	return {
		gui = gui,
		frame = frame,
		world = world,
		camera = camera,
		held = nil,
		bobPhase = 0,
		sway = Vector2.zero,
	}
end

function Viewmodel.unmount(view: View)
	view.gui:Destroy()
end

-- =================================== holding ================================
--[[
	Put a model in the frame.

	Cloned rather than reparented, because the caller's model is usually the
	one in the world — the third-person weapon other players see — and moving
	it would take it off the character. Anchoring everything stops the physics
	engine from having opinions about a model that is not in the world.
]]
function Viewmodel.hold(view: View, model: Model): Model
	if view.held then
		view.held:Destroy()
	end

	local copy = model:Clone()
	for _, descendant in copy:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
	copy.Parent = view.world
	view.held = copy
	return copy
end

function Viewmodel.clear(view: View)
	if view.held then
		view.held:Destroy()
		view.held = nil
	end
end

-- ==================================== step ==================================
--[[
	Move the frame's camera to match the world's, plus bob and sway.

	Called every RenderStepped, after the real camera has been positioned. The
	order matters: reading the world camera before it has moved this frame
	produces a gun that trails the view by exactly one frame, which is
	invisible in a screenshot and unmistakable in motion.

	`lookDelta` is how far the view turned since the last frame. Sway
	accumulates it and decays back, so a fast turn throws the gun and it
	settles — the whole effect in two lines.
]]
function Viewmodel.step(view: View, worldCamera: Camera, dt: number,
	moveSpeed: number?, lookDelta: Vector2?)
	if lookDelta then
		view.sway = view.sway - lookDelta * Viewmodel.swayStuds
	end
	-- Exponential decay rather than a lerp against a constant, so the settle
	-- takes the same time at any frame rate.
	local recover = math.exp(-Viewmodel.swayRecover * dt)
	view.sway = view.sway * recover
	view.sway = Vector2.new(
		math.clamp(view.sway.X, -2, 2),
		math.clamp(view.sway.Y, -2, 2))

	local speed = moveSpeed or 0
	view.bobPhase += dt * Viewmodel.bobRate * math.min(speed, 24)
	--[[
		A figure of eight, not a bounce.

		The horizontal component runs at half the vertical one, which traces
		the path a hand actually takes when you walk. A single sine on Y is
		the version that reads as a pogo stick.
	]]
	local bobX = math.sin(view.bobPhase) * Viewmodel.bobStuds
	local bobY = math.abs(math.cos(view.bobPhase * 0.5)) * Viewmodel.bobStuds

	view.camera.FieldOfView = worldCamera.FieldOfView * Viewmodel.fieldOfViewRatio
	view.camera.CFrame = worldCamera.CFrame
		* CFrame.new(view.sway.X + bobX, view.sway.Y + bobY, 0)
end

--[[
	How brightly the gun is lit.

	The whole compensation for a viewport ignoring world lighting. Drive it
	from whatever the game already knows about the room — a light sample, the
	time of day, the biome — and the gun stops looking like a sticker.
]]
function Viewmodel.setLight(view: View, colour: Color3)
	view.frame.ImageColor3 = colour
end

function Viewmodel.describe(view: View): { [string]: any }
	return {
		holding = view.held and view.held.Name or nil,
		fieldOfView = view.camera.FieldOfView,
		sway = { view.sway.X, view.sway.Y },
		light = { view.frame.ImageColor3.R, view.frame.ImageColor3.G, view.frame.ImageColor3.B },
	}
end

return Viewmodel
