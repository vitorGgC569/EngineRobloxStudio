--!strict
--[[
	HeldRod — the thing in the player's hands.

	Until now a Tidebound fisher cast with an empty fist: the line left the
	shoulder, the bobber landed, and nothing connected the two. This module
	builds the missing half out of primitives -- a cork grip, a spinning
	reel, a three-segment tapered shaft -- and hangs it off the right hand
	with one Motor6D.

	None of it is gameplay. The server owns what a cast does; this file owns
	what it looks like, and it never sends a message.

	The model is rebuilt whenever the equipped rod changes, so the palette
	table below is the whole of a tier's look -- bamboo through tidecaller --
	and `attach` is the only place a model is born or dies. The RodMotor's
	C0 is the entire animation surface: poses are CFrames, transitions are
	tweens, and the fight is one RenderStepped loop that disconnects itself
	the moment the outcome arrives.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local state = require(script.Parent.Parent.state)

local HeldRod = {}

local player = Players.LocalPlayer

local MODEL_NAME = "HeldRod"
local MOTOR_NAME = "RodMotor"

-- ================================ palettes ==================================
--[[
	One row per rod, ascending quality. A palette is the whole of a tier's
	look; the geometry below is identical for all seven, because a carbon
	rod is a better rod, not a differently shaped one.

	A missing id falls back to bamboo: an unknown rod in a save file should
	read as the starting rod, not as nothing in the player's hands.
]]
type Palette = {
	shaft: Color3,
	shaftMaterial: Enum.Material,
	wrap: Color3,
	wrapMaterial: Enum.Material,
	handle: Color3,
	handleMaterial: Enum.Material,
	metal: Color3,
	metalMaterial: Enum.Material,
	accent: Color3,
	bead: Color3,
	beadNeon: boolean,
}

local PALETTES: { [string]: Palette } = {
	bamboo = {
		shaft = Color3.fromRGB(206, 170, 112),
		shaftMaterial = Enum.Material.SmoothPlastic,
		wrap = Color3.fromRGB(56, 88, 58),
		wrapMaterial = Enum.Material.SmoothPlastic,
		handle = Color3.fromRGB(214, 186, 148),
		handleMaterial = Enum.Material.Wood,
		metal = Color3.fromRGB(126, 118, 102),
		metalMaterial = Enum.Material.Metal,
		accent = Color3.fromRGB(96, 92, 84),
		bead = Color3.fromRGB(56, 88, 58),
		beadNeon = false,
	},
	fiberglass = {
		shaft = Color3.fromRGB(208, 224, 234),
		shaftMaterial = Enum.Material.SmoothPlastic,
		wrap = Color3.fromRGB(62, 104, 178),
		wrapMaterial = Enum.Material.SmoothPlastic,
		handle = Color3.fromRGB(58, 66, 82),
		handleMaterial = Enum.Material.SmoothPlastic,
		metal = Color3.fromRGB(178, 190, 202),
		metalMaterial = Enum.Material.Metal,
		accent = Color3.fromRGB(124, 156, 206),
		bead = Color3.fromRGB(62, 104, 178),
		beadNeon = false,
	},
	carbon = {
		shaft = Color3.fromRGB(38, 40, 44),
		shaftMaterial = Enum.Material.SmoothPlastic,
		wrap = Color3.fromRGB(168, 44, 48),
		wrapMaterial = Enum.Material.SmoothPlastic,
		handle = Color3.fromRGB(52, 52, 56),
		handleMaterial = Enum.Material.SmoothPlastic,
		metal = Color3.fromRGB(96, 100, 108),
		metalMaterial = Enum.Material.Metal,
		accent = Color3.fromRGB(168, 44, 48),
		bead = Color3.fromRGB(168, 44, 48),
		beadNeon = false,
	},
	titanium = {
		shaft = Color3.fromRGB(198, 204, 212),
		shaftMaterial = Enum.Material.SmoothPlastic,
		wrap = Color3.fromRGB(88, 128, 176),
		wrapMaterial = Enum.Material.SmoothPlastic,
		handle = Color3.fromRGB(64, 68, 74),
		handleMaterial = Enum.Material.SmoothPlastic,
		metal = Color3.fromRGB(160, 184, 214),
		metalMaterial = Enum.Material.Metal,
		accent = Color3.fromRGB(120, 156, 200),
		bead = Color3.fromRGB(88, 128, 176),
		beadNeon = false,
	},
	abyssal = {
		shaft = Color3.fromRGB(36, 24, 48),
		shaftMaterial = Enum.Material.SmoothPlastic,
		wrap = Color3.fromRGB(158, 96, 255),
		wrapMaterial = Enum.Material.Neon,
		handle = Color3.fromRGB(46, 36, 58),
		handleMaterial = Enum.Material.Slate,
		metal = Color3.fromRGB(64, 52, 84),
		metalMaterial = Enum.Material.Metal,
		accent = Color3.fromRGB(158, 96, 255),
		bead = Color3.fromRGB(176, 122, 255),
		beadNeon = true,
	},
	stormforged = {
		shaft = Color3.fromRGB(58, 64, 74),
		shaftMaterial = Enum.Material.Metal,
		wrap = Color3.fromRGB(84, 226, 238),
		wrapMaterial = Enum.Material.Neon,
		handle = Color3.fromRGB(44, 48, 56),
		handleMaterial = Enum.Material.Slate,
		metal = Color3.fromRGB(138, 150, 166),
		metalMaterial = Enum.Material.Metal,
		accent = Color3.fromRGB(84, 226, 238),
		bead = Color3.fromRGB(84, 226, 238),
		beadNeon = true,
	},
	tidecaller = {
		shaft = Color3.fromRGB(42, 138, 136),
		shaftMaterial = Enum.Material.SmoothPlastic,
		wrap = Color3.fromRGB(226, 186, 92),
		wrapMaterial = Enum.Material.Neon,
		handle = Color3.fromRGB(26, 68, 70),
		handleMaterial = Enum.Material.SmoothPlastic,
		metal = Color3.fromRGB(212, 178, 104),
		metalMaterial = Enum.Material.Metal,
		accent = Color3.fromRGB(226, 186, 92),
		bead = Color3.fromRGB(160, 255, 232),
		beadNeon = true,
	},
}

-- ================================ geometry ==================================
--: All of it in the rod's own frame: the handle centre is the origin, the
--: shaft runs up +Y, and the reel hangs on the -Z side -- the side the rest
--: pose turns toward the water. Numbers are studs.
local HANDLE_LENGTH = 0.72
local HANDLE_DIAMETER = 0.30
local SHAFT_BASE_Y = 0.80
local SHAFT_SEGMENTS: { { length: number, diameter: number } } = {
	{ length = 2.9, diameter = 0.22 },
	{ length = 2.4, diameter = 0.13 },
	{ length = 2.2, diameter = 0.07 },
}

--: A Cylinder part's circular faces are on +/-X, so a barrel aimed up the
--: rod needs a quarter turn; the reel discs get one aimed across it.
local CYLINDER_UP = CFrame.Angles(0, 0, math.rad(90))
local CYLINDER_OUT = CFrame.Angles(0, math.rad(90), 0)

local SHAFT_TOP_Y = SHAFT_BASE_Y
for _, segment in SHAFT_SEGMENTS do
	SHAFT_TOP_Y += segment.length
end
local TIP_LOCAL = Vector3.new(0, SHAFT_TOP_Y, 0)

-- ============================== part factory ================================
local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape or Enum.PartType.Block
	part.Size = size
	part.Color = color
	part.Material = material
	--: Every flag the engine reads is stamped here: a held thing that
	--: collides drags its owner into geometry, one that queries or touches
	--: spends the world's budget on nothing, and one that is not massless
	--: changes how the character walks. Anchored stays true until the joints
	--: exist.
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- ================================ the model =================================
local function buildRod(id: string, at: CFrame): (Model, Part, Attachment)
	local palette = PALETTES[id] or PALETTES.bamboo

	local model = Instance.new("Model")
	model.Name = MODEL_NAME

	local function solid(name: string, size: Vector3, color: Color3, material: Enum.Material, offset: CFrame, shape: Enum.PartType?): Part
		local part = newPart(name, size, color, material, shape)
		part.CFrame = at * offset
		part.Parent = model
		return part
	end

	local function cylinder(name: string, length: number, diameter: number, color: Color3, material: Enum.Material, offset: CFrame, rotation: CFrame?): Part
		return solid(name, Vector3.new(length, diameter, diameter), color, material, offset * (rotation or CYLINDER_UP), Enum.PartType.Cylinder)
	end

	--: Grip: butt cap, cork, and three wraps -- two below the hand and one
	--: above it, so the grip reads dressed from every angle.
	solid("ButtCap", Vector3.new(0.22, 0.22, 0.22), palette.metal, palette.metalMaterial, CFrame.new(0, -0.40, 0), Enum.PartType.Ball)
	local handle = cylinder("Handle", HANDLE_LENGTH, HANDLE_DIAMETER, palette.handle, palette.handleMaterial, CFrame.new(0, 0, 0))
	cylinder("Wrap1", 0.055, 0.33, palette.wrap, palette.wrapMaterial, CFrame.new(0, -0.26, 0))
	cylinder("Wrap2", 0.055, 0.33, palette.wrap, palette.wrapMaterial, CFrame.new(0, 0.18, 0))
	cylinder("Wrap3", 0.055, 0.33, palette.wrap, palette.wrapMaterial, CFrame.new(0, 0.33, 0))

	--: The seat bolts the reel on; the reel hangs below the rod -- body
	--: disc, spool, crank and knob, the four parts that make the silhouette
	--: read as a spinning reel from ten studs away.
	cylinder("ReelSeat", 0.44, 0.34, palette.metal, palette.metalMaterial, CFrame.new(0, 0.58, 0))
	cylinder("ReelBody", 0.22, 0.40, palette.metal, palette.metalMaterial, CFrame.new(0, 0.60, -0.24), CYLINDER_OUT)
	cylinder("Spool", 0.24, 0.30, palette.accent, palette.metalMaterial, CFrame.new(0, 0.60, -0.42), CYLINDER_OUT)
	solid("CrankArm", Vector3.new(0.42, 0.06, 0.06), palette.metal, palette.metalMaterial, CFrame.new(0.30, 0.66, -0.24) * CFrame.Angles(0, 0, math.rad(-30)))
	solid("CrankKnob", Vector3.new(0.12, 0.12, 0.12), palette.accent, palette.metalMaterial, CFrame.new(0.50, 0.54, -0.24), Enum.PartType.Ball)

	--: Shaft: three turned-down segments -- the diameters are the taper,
	--: from ~0.22 at the seat to ~0.07 where the last guide sits, ~7.5
	--: studs of rod over the grip.
	local y = SHAFT_BASE_Y
	for index, segment in SHAFT_SEGMENTS do
		cylinder("Shaft" .. tostring(index), segment.length, segment.diameter, palette.shaft, palette.shaftMaterial, CFrame.new(0, y + segment.length / 2, 0))
		y += segment.length
	end

	--: Guides: four slim bands that follow the taper, each a hair wider
	--: than the shaft it sits on.
	cylinder("Guide1", 0.06, 0.28, palette.metal, palette.metalMaterial, CFrame.new(0, 2.10, 0))
	cylinder("Guide2", 0.06, 0.19, palette.metal, palette.metalMaterial, CFrame.new(0, 4.00, 0))
	cylinder("Guide3", 0.06, 0.19, palette.metal, palette.metalMaterial, CFrame.new(0, 5.90, 0))
	cylinder("Guide4", 0.05, 0.13, palette.metal, palette.metalMaterial, CFrame.new(0, 7.70, 0))

	--: The tip bead: plain on the workhorse rods, Neon once a rod is meant
	--: to look like it glows.
	local beadSize = if palette.beadNeon then 0.11 else 0.08
	local beadMaterial = if palette.beadNeon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	local bead = solid("TipBead", Vector3.new(beadSize, beadSize, beadSize), palette.bead, beadMaterial, CFrame.new(0, SHAFT_TOP_Y + 0.04, 0), Enum.PartType.Ball)

	local tip = Instance.new("Attachment")
	tip.Name = "RodTip"
	tip.Parent = bead

	--: Every part welds to the handle, which is the only thing the motor
	--: holds: one joint to animate, and the rest of the rod follows it.
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= handle then
			local join = Instance.new("WeldConstraint")
			join.Part0 = handle
			join.Part1 = part
			join.Parent = part
		end
	end
	model.PrimaryPart = handle

	return model, handle, tip
end

-- ================================= poses ====================================
--: Poses are deltas on a base C0 that is anchored to the root, not the hand.
--: A stock R15 idle parks the hand with +Y along the limb: pointing a rod's
--: shaft (+Y there) produced the leaning-crossed look the playtest caught.
--: The base instead frames the rod off the root's LookVector -- forward and
--: 52 degrees up, at the hand's height -- so every pose below only adjusts
--: that stance, and the guide reads the same no matter how the rig parked.
local REST_DELTA = CFrame.new()
local WINDUP_DELTA = CFrame.Angles(math.rad(26), math.rad(-8), math.rad(12))
local FIGHT_DELTA = CFrame.Angles(math.rad(-16), math.rad(-2), math.rad(4))
local LANDED_DELTA = CFrame.Angles(math.rad(20), math.rad(4), math.rad(-6))
local DROPPED_DELTA = CFrame.Angles(math.rad(-46), math.rad(-10), math.rad(12))

--: How far the waiting rod may lean toward the bobber: a fisher watches
--: the float, they do not aim the rod at it.
local MAX_AIM = math.rad(14)

local TWEEN = {
	windup = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	aim = TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
	fight = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	win = TweenInfo.new(0.32, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out),
	loss = TweenInfo.new(0.42, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	rest = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
}

-- ================================ lifecycle =================================
local model: Model? = nil
local handPart: BasePart? = nil
local motor: Motor6D? = nil
local tipAttachment: Attachment? = nil
local currentRodId: string? = nil

local poseTween: Tween? = nil
local tweenGeneration = 0
local tugConn: RBXScriptConnection? = nil
local tugStart = 0
local mode = "rest"
local started = false

local function handOf(character: Model): BasePart?
	for _, name in { "RightHand", "Right Arm" } do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

local function equippedId(): string
	local rod = state.rod()
	return (rod and rod.id) or "bamboo"
end

local function isAttached(): boolean
	local hand = handPart
	local joint = motor
	return hand ~= nil and hand.Parent ~= nil and joint ~= nil and joint.Parent ~= nil
end

local function stopTug()
	if tugConn then
		tugConn:Disconnect()
		tugConn = nil
	end
end

--[[
	Move the joint to a pose, jumpcut-free.

	Every transition in this file is a tween on the same property, so any
	new move has to cancel the one in flight -- and a cancelled tween fires
	`Completed` like a finished one, which is why each carries a generation
	number. Only the most recent tween may run its completion callback.
]]
local function playTween(target: CFrame, info: TweenInfo, onDone: (() -> ())?)
	tweenGeneration += 1
	local generation = tweenGeneration
	if poseTween then
		poseTween:Cancel()
		poseTween = nil
	end
	local joint = motor
	if not joint or not joint.Parent then
		return
	end
	local tween = TweenService:Create(joint, info, { C0 = target })
	poseTween = tween
	tween:Play()
	if onDone then
		tween.Completed:Once(function()
			if generation == tweenGeneration then
				onDone()
			end
		end)
	end
end

--: Tear the model down without leaving anything to fire into: the loop
--: stops, the in-flight tween is retired by generation, and the joints die
--: with the parts they hold.
local function destroyRod()
	stopTug()
	tweenGeneration += 1
	if poseTween then
		poseTween:Cancel()
		poseTween = nil
	end
	if motor then
		motor:Destroy()
	end
	if model then
		model:Destroy()
	end
	motor = nil
	model = nil
	handPart = nil
	tipAttachment = nil
	mode = "rest"
end

--: One RenderStepped loop, owned by the fight and torn down with it. The
--: heave is the fish pulling, the tremble is the line, the sway is the rod
--: rolling against both -- all three written onto C0, which only the tween
--: that put the rod in the fight stance ever touches otherwise.
local function startTug()
	stopTug()
	tugStart = os.clock()
	tugConn = RunService.RenderStepped:Connect(function()
		local joint = motor
		if mode ~= "fight" or not joint or not joint.Parent then
			stopTug()
			return
		end
		local t = os.clock() - tugStart
		local heave = math.sin(t * 4.6) * 0.12
		local tremble = math.sin(t * 11.3 + 1.7) * 0.04
		local sway = math.sin(t * 3.1) * 0.06
		joint.C0 = FIGHT * CFrame.Angles(heave + tremble, 0, sway)
	end)
end

-- ================================== the API =================================
--[[
	The cast's beats, in the order CastController plays them:

		windup -> aimAt -> fight -> finish -> idle

	Each is safe with no character or no rod: the pose functions return
	early, and everything a caller can forget to stop -- the tug loop, the
	tween in flight -- is stopped by the next beat anyway.
]]

function HeldRod.windup()
	if not isAttached() then
		return
	end
	mode = "windup"
	stopTug()
	playTween(WINDUP, TWEEN.windup, function()
		--: No CastState arrived -- the cast was refused somewhere past the
		--: click -- so the rod relaxes instead of holding a cocked pose.
		if mode == "windup" then
			mode = "rest"
			playTween(REST, TWEEN.rest)
		end
	end)
end

--[[
	Lean the waiting rod toward where the bobber actually sits.

	The rod is not a pointer: the tip is rotated toward the target only up
	to MAX_AIM, and only once per cast -- a rod that tracked the float
	every frame would read as a gun turret. The rotation is composed in
	hand space, because that is the space C0 lives in.
]]
function HeldRod.aimAt(position: Vector3)
	local hand = handPart
	if not isAttached() or not hand then
		return
	end
	--: The shaft is the rod's +Y; where that axis points in the world
	--: under the rest pose is the direction being leaned.
	local toWorld = hand.CFrame * REST
	local tipWorld = toWorld * TIP_LOCAL
	local toTarget = position - tipWorld
	if toTarget.Magnitude < 1e-3 then
		return
	end
	local wanted = toTarget.Unit
	local current = toWorld.Rotation * Vector3.yAxis
	local lean = math.min(math.acos(math.clamp(current:Dot(wanted), -1, 1)), MAX_AIM)
	if lean < 1e-3 then
		return
	end
	local axis = current:Cross(wanted)
	if axis.Magnitude < 1e-4 then
		return
	end
	local swung = CFrame.fromAxisAngle(axis.Unit, lean) * current
	local up = hand.CFrame:VectorToObjectSpace(swung)
	local baseUp = REST.Rotation * Vector3.yAxis
	local localAxis = baseUp:Cross(up)
	if localAxis.Magnitude < 1e-4 then
		return
	end
	local delta = CFrame.fromAxisAngle(localAxis.Unit, math.acos(math.clamp(baseUp:Dot(up), -1, 1)))
	local target = CFrame.new(REST.Position) * delta * REST.Rotation
	mode = "aim"
	stopTug()
	playTween(target, TWEEN.aim)
end

function HeldRod.fight()
	if not isAttached() then
		return
	end
	mode = "fight"
	stopTug()
	--: Into the stance first, then hand the joint to the tug loop -- two
	--: writers on one C0 would fight the way the fish does.
	playTween(FIGHT, TWEEN.fight, function()
		if mode == "fight" and isAttached() then
			startTug()
		end
	end)
end

function HeldRod.finish(won: boolean)
	if not isAttached() then
		return
	end
	mode = "finish"
	stopTug()
	if won then
		playTween(LANDED, TWEEN.win)
	else
		playTween(DROPPED, TWEEN.loss)
	end
end

--: The one pose call that also has to work with nothing attached: the cast
--: is over, and a rod that no longer exists has nowhere to return to.
function HeldRod.idle()
	mode = "rest"
	stopTug()
	playTween(REST, TWEEN.rest)
end

--[[
	Wait out the spawn race, once per body.

	`CharacterAdded` fires the moment the model is parented, and this game's
	rigs assemble their hand a beat after that: measured live, the very first
	attach found a character with no `RightHand` yet, gave up silently, and
	the rod only appeared when some later profile sync happened to retry.
	The fisher stood empty-handed through the whole first minute of the
	session. Waiting for the hand is the fix; the guard keeps one wait per
	body, and the callback only builds for the character that is still the
	player's when the hand lands.
]]
local pendingBody: Model? = nil

local function attachWhenHandArrives(body: Model)
	if pendingBody == body then
		return
	end
	pendingBody = body
	task.spawn(function()
		local arrived = body:WaitForChild("RightHand", 15) or body:WaitForChild("Right Arm", 1)
		pendingBody = nil
		if arrived and player.Character == body then
			HeldRod.attach(body)
		end
	end)
end

--[[
	Hang the equipped rod on a character's right hand, replacing whatever
	was there. Called on spawn, on CharacterAdded, and whenever the profile
	reports a different rod; a character whose rig has not assembled a hand
	yet gets a wait rather than a give-up -- there is no later spawn to fall
	back on.
]]
function HeldRod.attach(character: Model?)
	local body = character or player.Character
	if not body then
		return
	end
	local hand = handOf(body)
	if not hand then
		attachWhenHandArrives(body)
		return
	end

	destroyRod()

	local id = equippedId()
	local rod, handle, tip = buildRod(id, hand.CFrame * REST)

	local joint = Instance.new("Motor6D")
	joint.Name = MOTOR_NAME
	joint.Part0 = hand
	joint.Part1 = handle
	joint.C0 = REST
	joint.C1 = CFrame.new()
	joint.Parent = hand

	rod.Parent = body

	--[[
		Release the anchors last.

		The parts were built, welded and parked at exactly where the motor
		wants them while still anchored -- so when they are let go there is
		no impulse for the solver to answer. An unanchored part welded
		several studs onto a moving hand is a throw, and it throws the
		character with it; Rig.grip paid for that lesson already.
	]]
	for _, part in rod:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end

	model = rod
	handPart = hand
	motor = joint
	tipAttachment = tip
	currentRodId = id
end

--: The fishing line's origin: the tip attachment while a rod is alive,
--: otherwise nil so callers fall back. The attachment belongs to the rod;
--: nothing outside `destroyRod` may destroy it.
function HeldRod.tip(): Attachment?
	local attachment = tipAttachment
	if attachment and attachment.Parent then
		return attachment
	end
	return nil
end

--[[
	Wire the rod to the two events that rebuild it: the character arriving
	and the profile changing the equipped rod. Idempotent, because the
	client bootstrap is not the only caller this may ever have.
]]
function HeldRod.start()
	if started then
		return
	end
	started = true

	if player.Character then
		HeldRod.attach(player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		HeldRod.attach(character)
	end)
	state.changed:Connect(function()
		if equippedId() == currentRodId then
			return
		end
		local body = player.Character
		if body then
			HeldRod.attach(body)
		end
	end)
end

return HeldRod
