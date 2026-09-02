--!strict
--[[
	holdout — the interface.

	Three things and no more, because a shooter's HUD earns its place by what
	it leaves out: where you are, what posture you are in, and what just
	happened to you.

	The minimap is drawn, not rendered
	-----------------------------------

	A `ViewportFrame` with a camera over the world is the obvious way and the
	wrong one: it costs a second render pass every frame to show a player
	shapes they already know. This draws the areas as circles and the player as
	a dot, from `Map` -- the same table the server tests positions against, so
	the drawing and the grid reference can never disagree.

	Coordinates are the point
	-------------------------

	`E4` is two characters a player can type, say out loud, or point at. That
	is the whole reason maps have grids, and it is what makes a minimap useful
	to somebody who is not looking at it.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
--[[
	Ask for the camera, never remember it.

	`Workspace.CurrentCamera` is replaced when a character spawns, so anything
	holding the one that existed at boot is holding an orphan: parented to it,
	a viewmodel is in the DataModel, positioned correctly, and rendered by
	nobody.
]]
local function eye(): Camera
	return Workspace.CurrentCamera :: Camera
end

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Map = require(Shared:WaitForChild("Map"))
local Posture = require(Shared:WaitForChild("Posture"))
local Wire = require(Shared:WaitForChild("Wire"))

--[[
	The contract is installed on both halves.

	`Net.define` builds a per-VM table of what exists and which way it points,
	so a client that has not run it answers `Net.on("located")` with "never
	defined" -- which is exactly what happened, and which reads on screen as a
	readout stuck on "Locating" with no error anywhere a player could see.
]]
Wire.install()

local UI = Forge.UI
local Net = Forge.Net
local T = UI.theme

local player = Players.LocalPlayer
local screen = UI.mount("Holdout", { displayOrder = 8, ignoreInset = false })

--: Cold, low and legible over a grey-green forest. A HUD tinted like the world
--: it sits on disappears into it, which is the most common way an atmospheric
--: game becomes an unreadable one.
local INK = Color3.fromRGB(226, 232, 230)
local DIM = Color3.fromRGB(150, 160, 158)
local MARK = Color3.fromRGB(228, 176, 72)
local PLATE = Color3.fromRGB(18, 22, 24)

local MAP_SIZE = 190
--: A circle of the world around the player rather than the whole valley. A
--: minimap that shows everything shows nothing: the useful information is what
--: is close enough to walk into.
local MINIMAP_REACH = 260

local function dot(parent: Instance, size: number, colour: Color3, z: number): Frame
	local f = Instance.new("Frame")
	f.Size = UDim2.fromOffset(size, size)
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = colour
	f.BorderSizePixel = 0
	f.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	f.Parent = parent
	return f
end

-- ================================= minimap ==================================
local minimap = UI.panel(screen, {
	name = "Minimap",
	size = UDim2.fromOffset(MAP_SIZE, MAP_SIZE),
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -T.space.lg, 0, T.space.lg + 34),
	color = PLATE, transparency = 0.28, radius = T.radius.sm,
	strokeColor = Color3.fromRGB(70, 80, 82),
})
minimap.ClipsDescendants = true

--: Grid lines, so the reference on the readout has something to correspond to.
--: They scroll with the player rather than being fixed, because the minimap is
--: a window on the world and not a picture of it.
local gridLines: { Frame } = {}
for _ = 1, math.floor(Map.EXTENT / Map.CELL) do
	for _, vertical in { true, false } do
		local line = Instance.new("Frame")
		line.Name = "Grid"
		line.BackgroundColor3 = Color3.fromRGB(90, 102, 104)
		line.BackgroundTransparency = 0.72
		line.BorderSizePixel = 0
		line.ZIndex = 2
		line.Size = if vertical then UDim2.new(0, 1, 1, 0) else UDim2.new(1, 0, 0, 1)
		line.Parent = minimap
		table.insert(gridLines, line)
	end
end

local areaBlobs: { any } = {}
local self = dot(minimap, 8, MARK, 6)
self.Position = UDim2.fromScale(0.5, 0.5)

--: A needle for facing. Knowing where you are is half of a minimap; knowing
--: which way you are pointing is the half people actually use.
local facing = Instance.new("Frame")
facing.Size = UDim2.fromOffset(2, 12)
facing.AnchorPoint = Vector2.new(0.5, 1)
facing.Position = UDim2.fromScale(0.5, 0.5)
facing.BackgroundColor3 = MARK
facing.BorderSizePixel = 0
facing.ZIndex = 5
facing.Parent = minimap

local atlas: any = nil
task.spawn(function()
	local ok, answer = pcall(function()
		return Net.request("atlas")
	end)
	if not ok or type(answer) ~= "table" then
		return
	end
	atlas = answer
	for _, area in answer.areas do
		local blob = dot(minimap, 12, Color3.fromRGB(120, 150, 148), 3)
		blob.BackgroundTransparency = 0.6
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromOffset(84, 12)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.BackgroundTransparency = 1
		label.Text = string.upper(area.label)
		label.TextSize = 9
		label.TextColor3 = DIM
		label.ZIndex = 4
		label.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
			Enum.FontWeight.Bold)
		label.Parent = blob
		table.insert(areaBlobs, { blob = blob, area = area })
	end
end)

-- ================================= readout ==================================
local readout = UI.panel(screen, {
	name = "Readout",
	size = UDim2.fromOffset(MAP_SIZE, 48),
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -T.space.lg, 0, T.space.lg + 40 + MAP_SIZE),
	color = PLATE, transparency = 0.28, radius = T.radius.sm,
	strokeColor = Color3.fromRGB(70, 80, 82),
})

local gridLabel = UI.label(readout, "\u{2014}", {
	size = T.text.lg, font = T.font.bold, color = MARK,
	frameSize = UDim2.new(0, 56, 0, 24), pos = UDim2.fromOffset(10, 5), z = 3,
})
gridLabel.TextXAlignment = Enum.TextXAlignment.Left

local areaLabel = UI.label(readout, "Locating", {
	size = T.text.sm, color = INK,
	frameSize = UDim2.new(1, -78, 0, 16), pos = UDim2.fromOffset(68, 7), z = 3,
})
areaLabel.TextXAlignment = Enum.TextXAlignment.Left

local coordLabel = UI.label(readout, "", {
	size = T.text.xs, color = DIM,
	frameSize = UDim2.new(1, -60, 0, 14), pos = UDim2.fromOffset(10, 29), z = 3,
})
coordLabel.TextXAlignment = Enum.TextXAlignment.Left

local compassLabel = UI.label(readout, "N", {
	size = T.text.md, font = T.font.bold, color = INK,
	frameSize = UDim2.new(0, 36, 0, 20), z = 3,
	anchor = Vector2.new(1, 0), pos = UDim2.new(1, -10, 0, 25),
})

Net.on("located", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	gridLabel.Text = tostring(payload.reference)
	areaLabel.Text = tostring(payload.area)
	coordLabel.Text = string.format("%d, %d, %d",
		payload.x or 0, payload.y or 0, payload.z or 0)
end)

-- ================================= posture ==================================
local postureLabel = UI.label(screen, "STANDING", {
	name = "Posture",
	size = T.text.xs, font = T.font.bold, color = DIM,
	frameSize = UDim2.new(0, 220, 0, 16),
	anchor = Vector2.new(0, 1), pos = UDim2.new(0, T.space.lg, 1, -T.space.lg),
})
postureLabel.TextXAlignment = Enum.TextXAlignment.Left

local currentPosture = "stand"
--: Filled in once the animation section below has been read; the
--: posture handler is declared above it and both need the other.
local restageBody: (() -> ())? = nil

Net.on("postured", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	currentPosture = tostring(payload.posture)
	postureLabel.Text = string.upper(Posture.get(currentPosture).label)
	postureLabel.TextColor3 = if currentPosture == "stand" then DIM else MARK
	if restageBody then
		restageBody()
	end
end)

local function ask(to: string)
	pcall(function()
		Net.request("posture", { to = to })
	end)
end

--[[
	C steps down and up, X drops straight to prone. Both are toggles.

	Hold-to-crouch is the other convention and it is wrong for a game with
	prone in it: holding two keys to lie down while also moving and aiming is
	more fingers than a person has.
]]
ContextActionService:BindAction("Crouch", function(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	ask(if currentPosture == "stand" then "crouch" else "stand")
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.C)

ContextActionService:BindAction("Prone", function(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	ask(if currentPosture == "prone" then "crouch" else "prone")
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.X)

--: Sprint and aim are held. The client sends both without second-guessing
--: what the server will allow: the two disagreeing about the rules is worse
--: than one wasted remote.
--: Assigned by the animation section below.
local setAiming: ((boolean) -> ())? = nil

local function hold(name: string, key: Enum.KeyCode, remote: string)
	ContextActionService:BindAction(name, function(_, state)
		local on = state == Enum.UserInputState.Begin
		if on or state == Enum.UserInputState.End then
			pcall(function() Net.request(remote, { on = on }) end)
			--: Aiming swaps the upper-body clip. Held rather than toggled, so it
			--: follows the key instead of a state the client has to track.
			if remote == "aim" and setAiming then
				setAiming(on)
			end
		end
		return Enum.ContextActionResult.Pass
	end, false, key)
end
hold("Sprint", Enum.KeyCode.LeftShift, "sprint")
hold("Aim", Enum.KeyCode.LeftAlt, "aim")

-- ================================== view ====================================
--[[
	First person, because that is what this game is.

	A shooter played over the shoulder puts the crosshair on the character's own
	chest: the camera looks past the body, the reticle sits at the centre of the
	screen, and the two do not meet until about forty studs out. Every
	third-person shooter solves this by pushing the camera onto one shoulder,
	and the honest version of that for a game aiming at realism is to be inside
	the head instead.

	Third person stays on `V`, because seeing your own character is worth having
	and a game that takes the choice away is one somebody puts down. When it is
	on the camera moves to the right shoulder, so the reticle still points at
	open ground rather than at a spine.
]]
local firstPerson = true
local SHOULDER = 2.2

local function applyView()
	if firstPerson then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	else
		player.CameraMode = Enum.CameraMode.Classic
		player.CameraMinZoomDistance = 8
		player.CameraMaxZoomDistance = 12
	end
end
applyView()
player.CharacterAdded:Connect(function()
	task.defer(applyView)
end)

--[[
	Where the eye sits, every frame.

	Posture is the server's -- it decides speed, spread and hitbox -- but the
	camera is nobody's business but this client's, so the crouch drop and the
	shoulder are combined here rather than fought over through a replicated
	property.

	Roblox hides everything parented to the character while the camera is inside
	the head, and that includes the weapon welded to its hand. Clearing the
	transparency modifier each frame is what puts the gun back on screen:
	without it, first person is a game that tells you you are holding an M9 and
	never shows you one.
]]
--[[
	The weapon you can actually see, on the arm that is actually holding it.

	The first attempt at this was a second copy of the gun parented to the
	camera at a fixed offset -- the standard first-person viewmodel. It worked
	and it was wrong for this game: a weapon welded to the camera is a weapon
	nailed to the middle of the screen, unaffected by the arm swinging under it,
	which reads as a sticker rather than as something being carried.

	So there is one gun, welded to the hand where it belongs, and this makes it
	visible. Roblox hides everything parented to a character while the camera is
	inside its head, and `LocalTransparencyModifier` is the documented way to
	say "not this". It has to be written every frame because the camera writes
	it every frame too.
]]
local function showWeapon(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("Model") and string.match(child.Name, "^Gun_") then
			for _, part in child:GetDescendants() do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = 0
				end
			end
		end
	end
end

--[[
	Animation, from the engine that already had it.

	This file previously drove `AnimationConstraint.Transform` by hand, joint by
	joint, in `PreSimulation`, with a table of hand-tuned Euler angles. It
	worked -- the arms came up -- and it was a reimplementation of
	`Forge.Anim`, which has a clip format, masks so the legs keep walking while
	the arms aim, priorities, blending, and presets for `hold`, `aim`, `shoot`
	and `reload` already written by somebody who had thought about it longer.

	`Rig.stripDefaultAnimate` is the part that makes any of it stick: Roblox's
	own Animate script fights every pose put on a character, and removing it is
	the documented first step that none of the hand-rolled attempts did.
]]
local Anim = Forge.Anim
local Rig = Forge.Rig

Anim.registerAll(require(ReplicatedStorage.Forge.Anim.Presets))

--: Crouch and prone are not in the presets, because they are this game's.
--: Masked to the legs and torso so the arms keep holding the weapon.
local STANCE = { "rightLeg", "leftLeg", "rightShin", "leftShin", "torso" }
Anim.register("stance_crouch", {
	duration = 0.28, loop = true, hold = true, mask = STANCE, priority = 2,
	tracks = {
		rightLeg = { Anim.k(0, -38, 6, 0), Anim.k(0.28, -37, 6, 0) },
		leftLeg = { Anim.k(0, -38, -6, 0), Anim.k(0.28, -37, -6, 0) },
		rightShin = { Anim.k(0, 64, 0, 0), Anim.k(0.28, 63, 0, 0) },
		leftShin = { Anim.k(0, 64, 0, 0), Anim.k(0.28, 63, 0, 0) },
		torso = { Anim.k(0, 20, 0, 0), Anim.k(0.28, 20, 0, 0) },
	},
})
Anim.register("stance_prone", {
	duration = 0.34, loop = true, hold = true, mask = STANCE, priority = 2,
	tracks = {
		rightLeg = { Anim.k(0, -74, 8, 0), Anim.k(0.34, -73, 8, 0) },
		leftLeg = { Anim.k(0, -74, -8, 0), Anim.k(0.34, -73, -8, 0) },
		rightShin = { Anim.k(0, 96, 0, 0), Anim.k(0.34, 95, 0, 0) },
		leftShin = { Anim.k(0, 96, 0, 0), Anim.k(0.34, 95, 0, 0) },
		torso = { Anim.k(0, 48, 0, 0), Anim.k(0.34, 48, 0, 0) },
	},
})

local animator: any = nil

local function attachAnimator(character: Model)
	if not character:FindFirstChildOfClass("Humanoid") then
		return
	end
	Rig.stripDefaultAnimate(character)
	if animator then
		animator:destroy()
	end
	animator = Anim.new(character)
	Anim.bind(animator)
end

if player.Character then
	task.defer(attachAnimator, player.Character)
end
player.CharacterAdded:Connect(function(character)
	task.defer(attachAnimator, character)
end)

--: What the body is doing, recomputed whenever a reason to change it arrives.
--: Stance and weapon are separate clips on separate masks, so crouching while
--: aiming is both and not a third clip nobody wrote.
local aiming = false

local function restage()
	if not animator then
		return
	end
	for _, name in { "stance_crouch", "stance_prone" } do
		if animator:isPlaying(name) then
			animator:stop(name, false)
		end
	end
	if currentPosture == "crouch" then
		animator:play("stance_crouch")
	elseif currentPosture == "prone" then
		animator:play("stance_prone")
	end

	local armed = player:GetAttribute("gun") ~= nil
	for _, name in { "hold", "aim" } do
		if animator:isPlaying(name) then
			animator:stop(name, false)
		end
	end
	if armed then
		animator:play(if aiming then "aim" else "hold")
	end
end

player:GetAttributeChangedSignal("gun"):Connect(restage)
restageBody = restage
setAiming = function(on: boolean)
	aiming = on
	restage()
end

RunService.RenderStepped:Connect(function()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (character and humanoid) then
		return
	end
	local drop = Posture.get(currentPosture).drop or 0
	humanoid.CameraOffset = Vector3.new(
		if firstPerson then 0 else SHOULDER, -drop, 0)

	showWeapon(character)
end)

-- =================================== gun ====================================
--[[
	The trigger, the crosshair and what a hit looks like.

	The client sends where it is looking and nothing else. Every tracer, every
	impact and every hitmarker below is drawn from what the *server* replied
	with -- so a shot the server refused draws nothing, which is the only
	honest way to render a shooter.
]]
local UserInputService = game:GetService("UserInputService")

local gunLabel = UI.label(screen, "", {
	name = "Gun", size = T.text.sm, font = T.font.bold, color = INK,
	frameSize = UDim2.new(0, 240, 0, 18),
	anchor = Vector2.new(0, 1), pos = UDim2.new(0, T.space.lg, 1, -T.space.lg - 20),
})
gunLabel.TextXAlignment = Enum.TextXAlignment.Left

local ammoLabel = UI.label(screen, "", {
	name = "Ammo", size = T.text.xl, font = T.font.bold, color = INK,
	frameSize = UDim2.new(0, 240, 0, 30),
	anchor = Vector2.new(0, 1), pos = UDim2.new(0, T.space.lg, 1, -T.space.lg - 40),
})
ammoLabel.TextXAlignment = Enum.TextXAlignment.Left

--[[
	A crosshair that opens with the spread.

	Four ticks around a gap rather than a dot, because the gap *is* the
	information: a player should be able to watch their accuracy get worse
	while they run without reading a number anywhere.
]]
local reticle = Instance.new("Frame")
reticle.Name = "Reticle"
reticle.Size = UDim2.fromOffset(46, 46)
reticle.AnchorPoint = Vector2.new(0.5, 0.5)
reticle.Position = UDim2.fromScale(0.5, 0.5)
reticle.BackgroundTransparency = 1
reticle.ZIndex = 20
reticle.Parent = screen

local ticks: { Frame } = {}
for index = 1, 4 do
	local tick = Instance.new("Frame")
	tick.BorderSizePixel = 0
	tick.BackgroundColor3 = INK
	tick.BackgroundTransparency = 0.15
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.ZIndex = 21
	tick.Size = if index <= 2 then UDim2.fromOffset(2, 7) else UDim2.fromOffset(7, 2)
	tick.Parent = reticle
	ticks[index] = tick
end

local hitmarker = Instance.new("Frame")
hitmarker.Name = "Hitmarker"
hitmarker.Size = UDim2.fromOffset(16, 16)
hitmarker.AnchorPoint = Vector2.new(0.5, 0.5)
hitmarker.Position = UDim2.fromScale(0.5, 0.5)
hitmarker.BackgroundTransparency = 1
hitmarker.ZIndex = 22
hitmarker.Parent = screen
for _, rotation in { 45, -45 } do
	local bar = Instance.new("Frame")
	bar.Size = UDim2.fromOffset(2, 16)
	bar.AnchorPoint = Vector2.new(0.5, 0.5)
	bar.Position = UDim2.fromScale(0.5, 0.5)
	bar.Rotation = rotation
	bar.BorderSizePixel = 0
	bar.BackgroundColor3 = Color3.fromRGB(255, 236, 220)
	bar.BackgroundTransparency = 1
	bar.ZIndex = 22
	bar.Parent = hitmarker
end

local gun: any = nil
local spreadNow = 2.5
local firing = false

Net.on("armed", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	gun = payload
	gunLabel.Text = string.upper(tostring(payload.name))
end)

local function refreshAmmo()
	local held = player:GetAttribute("ammo")
	local reserve = player:GetAttribute("reserve")
	if held == nil then
		ammoLabel.Text = ""
		return
	end
	ammoLabel.Text = string.format("%d / %s", held,
		if reserve and reserve < 1e6 then tostring(reserve) else "inf")
	ammoLabel.TextColor3 = if held == 0 then T.color.danger else INK
end
player:GetAttributeChangedSignal("ammo"):Connect(refreshAmmo)
player:GetAttributeChangedSignal("reserve"):Connect(refreshAmmo)
player:GetAttributeChangedSignal("gun"):Connect(function()
	local name = player:GetAttribute("gun")
	gunLabel.Text = if name then string.upper(tostring(name)) else ""
end)

--: A line from the muzzle to where the round stopped, for a tenth of a second.
--: Long enough to read the direction, short enough not to become a laser show.
local function tracer(from: Vector3, to: Vector3)
	local length = (to - from).Magnitude
	if length < 1 then
		return
	end
	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CastShadow = false
	beam.Size = Vector3.new(0.14, 0.14, length)
	beam.CFrame = CFrame.lookAt(from:Lerp(to, 0.5), to)
	beam.Color = Color3.fromRGB(255, 232, 176)
	beam.Material = Enum.Material.Neon
	beam.Transparency = 0.2
	beam.Parent = Workspace

	--: A ninth of a second was long enough for the code and far too short for a
	--: person -- "I don't see the shots" is what a tracer that blinks out inside
	--: one frame looks like from the other side. It now fades over a fifth of a
	--: second, which reads as a round leaving the barrel instead of a flicker.
	TweenService:Create(beam,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Transparency = 1 }):Play()
	task.delay(0.22, function()
		beam:Destroy()
	end)

	--: The flash at the muzzle -- the thing that actually tells a player the
	--: trigger did something, at the place they are looking.
	local flash = Instance.new("Part")
	flash.Anchored, flash.CanCollide, flash.CanQuery = true, false, false
	flash.CastShadow = false
	flash.Shape = Enum.PartType.Ball
	flash.Size = Vector3.new(0.55, 0.55, 0.55)
	flash.CFrame = CFrame.new(from)
	flash.Color = Color3.fromRGB(255, 214, 138)
	flash.Material = Enum.Material.Neon
	flash.Parent = Workspace
	task.delay(0.05, function()
		flash:Destroy()
	end)
end

local function impact(at: Vector3, onBody: boolean)
	local mark = Instance.new("Part")
	mark.Anchored = true
	mark.CanCollide = false
	mark.CanQuery = false
	mark.CastShadow = false
	mark.Size = Vector3.new(0.35, 0.35, 0.35)
	mark.CFrame = CFrame.new(at)
	mark.Color = if onBody then Color3.fromRGB(150, 40, 36)
		else Color3.fromRGB(210, 200, 186)
	mark.Material = Enum.Material.Neon
	mark.Transparency = 0.25
	mark.Parent = Workspace
	task.delay(0.5, function()
		mark:Destroy()
	end)
end

local function flashHitmarker()
	for _, bar in hitmarker:GetChildren() do
		if bar:IsA("Frame") then
			bar.BackgroundTransparency = 0
		end
	end
	task.delay(0.12, function()
		for _, bar in hitmarker:GetChildren() do
			if bar:IsA("Frame") then
				bar.BackgroundTransparency = 1
			end
		end
	end)
end

Net.on("shot", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	spreadNow = tonumber(payload.spread) or spreadNow
	--: The server says where the barrel was. Falling back to the head keeps a
	--: tracer on screen for anybody whose gun model failed to build, rather than
	--: silently drawing nothing.
	local head = player.Character and player.Character:FindFirstChild("Head")
	local from = if typeof(payload.from) == "Vector3" then payload.from
		elseif head and head:IsA("BasePart") then head.Position
		else nil
	local landed = false
	for _, hit in payload.hits or {} do
		if typeof(hit.at) == "Vector3" then
			if from then
				tracer(from, hit.at)
			end
			impact(hit.at, hit.zone ~= "world")
		end
		if hit.zone and hit.zone ~= "world" then
			landed = true
		end
	end
	if landed then
		flashHitmarker()
	end
	if animator then
		animator:play("shoot")
	end
end)

local function pullTrigger()
	local look = eye().CFrame.LookVector
	pcall(function()
		Net.request("fire", { x = look.X, y = look.Y, z = look.Z })
	end)
end

UserInputService.InputBegan:Connect(function(input, typing)
	if typing then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		firing = true
		pullTrigger()
	elseif input.KeyCode == Enum.KeyCode.V then
		firstPerson = not firstPerson
		applyView()
	elseif input.KeyCode == Enum.KeyCode.R then
		pcall(function()
			Net.request("reload")
		end)
		if animator then
			animator:play("reload")
		end
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		firing = false
	end
end)

--: Automatic fire is the client repeating the request; the server's cooldown
--: decides the rate. Asking faster than the gun can fire costs a refusal and
--: nothing else, which is cheaper than the client keeping its own timer and
--: the two disagreeing.
task.spawn(function()
	while true do
		task.wait(0.05)
		if firing and gun then
			pullTrigger()
		end
	end
end)

-- ================================== atlas ===================================
--[[
	The full map, on M.

	The same drawing at three times the size, with the grid labelled. A player
	who wants to say where something is opens this once, reads two characters
	and closes it -- which is the entire job.
]]
local ATLAS_SIZE = 540

local mapScreen = UI.panel(screen, {
	name = "Atlas",
	size = UDim2.fromOffset(ATLAS_SIZE, ATLAS_SIZE),
	anchor = Vector2.new(0.5, 0.5), pos = UDim2.fromScale(0.5, 0.5),
	color = PLATE, transparency = 0.06, radius = T.radius.md,
	strokeColor = Color3.fromRGB(88, 100, 102),
})
mapScreen.Visible = false
mapScreen.ZIndex = 40
mapScreen.ClipsDescendants = true

local mapSelf = dot(mapScreen, 12, MARK, 46)
local drawn = false

local function drawAtlas()
	local cells = math.floor(Map.EXTENT / Map.CELL)
	for index = 0, cells do
		for _, vertical in { true, false } do
			local line = Instance.new("Frame")
			line.BackgroundColor3 = Color3.fromRGB(96, 110, 112)
			line.BackgroundTransparency = 0.75
			line.BorderSizePixel = 0
			line.ZIndex = 42
			local t = index / cells
			line.Size = if vertical then UDim2.new(0, 1, 1, 0) else UDim2.new(1, 0, 0, 1)
			line.Position = if vertical then UDim2.fromScale(t, 0)
				else UDim2.fromScale(0, t)
			line.Parent = mapScreen
		end
	end

	--: Column letters across the top and row numbers down the side. A grid
	--: with no labels is a decoration.
	for column = 1, #Map.COLUMNS do
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromOffset(20, 14)
		label.Position = UDim2.fromScale((column - 0.5) / cells, 0)
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.BackgroundTransparency = 1
		label.Text = Map.COLUMNS[column]
		label.TextSize = 11
		label.TextColor3 = DIM
		label.ZIndex = 44
		label.Parent = mapScreen
	end
	for row = 1, cells do
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromOffset(16, 14)
		label.Position = UDim2.fromScale(0, (row - 0.5) / cells)
		label.AnchorPoint = Vector2.new(0, 0.5)
		label.BackgroundTransparency = 1
		label.Text = tostring(row)
		label.TextSize = 11
		label.TextColor3 = DIM
		label.ZIndex = 44
		label.Parent = mapScreen
	end

	for _, area in (atlas and atlas.areas or {}) do
		local size = math.max(20, area.radius * ATLAS_SIZE * 2)
		local blob = dot(mapScreen, size, Color3.fromRGB(120, 152, 150), 43)
		blob.BackgroundTransparency = 0.72
		blob.Position = UDim2.fromScale(area.x, area.z)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromOffset(150, 14)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.BackgroundTransparency = 1
		label.Text = area.label
		label.TextSize = 12
		label.TextColor3 = INK
		label.ZIndex = 45
		label.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
			Enum.FontWeight.Bold)
		label.Parent = blob
	end
end

ContextActionService:BindAction("Atlas", function(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not drawn and atlas then
		drawAtlas()
		drawn = true
	end
	mapScreen.Visible = not mapScreen.Visible
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.M)

-- ================================== ticking =================================
RunService.RenderStepped:Connect(function()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	local position = root.Position
	local look = root.CFrame.LookVector
	local bearing = Map.bearing(look)

	facing.Rotation = bearing
	compassLabel.Text = Map.compass(look)

	--: The world scrolls under a fixed dot, which is what everybody expects
	--: and what makes the dot mean "you" rather than "a thing on a picture".
	for _, entry in areaBlobs do
		local worldX = (entry.area.x - 0.5) * Map.EXTENT
		local worldZ = (entry.area.z - 0.5) * Map.EXTENT
		local dx = (worldX - position.X) / MINIMAP_REACH
		local dz = (worldZ - position.Z) / MINIMAP_REACH
		entry.blob.Position = UDim2.fromScale(0.5 + dx * 0.5, 0.5 + dz * 0.5)
		local size = math.max(16,
			entry.area.radius * Map.EXTENT / MINIMAP_REACH * MAP_SIZE)
		entry.blob.Size = UDim2.fromOffset(size, size)
		--: Hidden rather than clipped off the edge, so the map does not grow a
		--: ring of half-circles around its border.
		entry.blob.Visible = math.abs(dx) < 0.95 and math.abs(dz) < 0.95
	end

	local pixelsPerCell = Map.CELL / MINIMAP_REACH * MAP_SIZE / 2
	for index, line in gridLines do
		local vertical = index % 2 == 1
		local slot = math.floor((index - 1) / 2)
		local offset = if vertical
			then (position.X % Map.CELL) / Map.CELL
			else (position.Z % Map.CELL) / Map.CELL
		local at = (slot * pixelsPerCell - offset * pixelsPerCell) % MAP_SIZE
		line.Position = if vertical then UDim2.fromOffset(at, 0)
			else UDim2.fromOffset(0, at)
	end

	--: The reticle opens with the spread the server last reported, so what a
	--: player sees is the figure the shot was actually taken with.
	local gap = 5 + spreadNow * 5.5
	ticks[1].Position = UDim2.new(0.5, 0, 0.5, -gap)
	ticks[2].Position = UDim2.new(0.5, 0, 0.5, gap)
	ticks[3].Position = UDim2.new(0.5, -gap, 0.5, 0)
	ticks[4].Position = UDim2.new(0.5, gap, 0.5, 0)

	if mapScreen.Visible then
		local nx, nz = Map.normalised(position)
		mapSelf.Position = UDim2.fromScale(nx, nz)
		mapSelf.Rotation = bearing
	end
end)

-- ================================= feedback =================================
Net.on("notice", function(payload: any)
	if type(payload) ~= "table" or type(payload.text) ~= "string" then
		return
	end
	UI.toast(payload.text, {
		color = if payload.kind == "refused" then T.color.danger else INK,
	})
end)

Net.on("looted", function(payload: any)
	if type(payload) ~= "table" or type(payload.found) ~= "table" then
		return
	end
	for _, drop in payload.found do
		UI.toast(string.format("%s%s", tostring(drop.id),
			if drop.amount then " x" .. tostring(drop.amount) else ""),
			{ color = MARK })
	end
end)

return nil
