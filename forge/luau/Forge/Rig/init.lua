--!strict
--[[
	Rig — characters authored in code.

	A creature's silhouette becomes a table of numbers. That matters for two
	reasons: an agent can create a new enemy without a modelling tool, and the
	difference between a rat and a golem becomes something you can tune rather
	than something you have to re-model.

		local model = Rig.build({
			name = "Grass Wolf",
			scale = 0.85,
			shape = "quadruped",
			body = Color3.fromRGB(112, 106, 96),
			accent = Color3.fromRGB(64, 60, 54),
			eyes = Color3.fromRGB(240, 200, 80),
			weapon = nil,
		})

	R6 by default: six joints, and `shape` changes the posture rather than the
	bone count -- a quadruped is an R6 rig with a pitched torso, which reads
	correctly and costs nothing.

	`rigType = "R15"` builds the fifteen-part skeleton instead, with elbows,
	knees, wrists and ankles. That exists because shoulders alone can only aim
	an arm, never fold one, and an archer's draw hand belongs at the cheek.
]]

local Workspace = game:GetService("Workspace")

local Rig = {}

local HALF = math.pi / 2

export type Spec = {
	name: string?,
	scale: number?,
	shape: string?, -- "biped" | "quadruped" | "hulk"
	bulky: boolean?,
	body: Color3?,
	accent: Color3?,
	eyes: Color3?,
	glow: boolean?,
	spikes: boolean?,
	material: Enum.Material?,
	weapon: string?, -- "sword" | "axe" | "greatsword" | "staff"
	collide: boolean?,
	detail: boolean?, -- false strips the silhouette parts; the joints are unchanged
	rigType: string?, -- "R6" (default) or "R15", which has elbows, knees and wrists
}

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material, parent: Instance): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = true
	p.Parent = parent
	return p
end

local function motor(name: string, p0: BasePart, p1: BasePart, c0: CFrame, c1: CFrame): Motor6D
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = p0
	m.Part1 = p1
	m.C0 = c0
	m.C1 = c1
	m.Parent = p0
	return m
end

local function weld(p0: BasePart, p1: BasePart, c0: CFrame): Weld
	local w = Instance.new("Weld")
	w.Part0 = p0
	w.Part1 = p1
	w.C0 = c0
	w.Parent = p1
	return w
end

-- ================================ silhouette ================================
--[[
	Detail welded onto the six animated parts.

	The joints stay exactly as they were — six boxes, one Motor6D each — because
	that is what every clip in the engine is written against. What changes is
	what hangs off them.

	This matters more than it sounds. A character reads at a distance by its
	*outline*, not its faces: hands and feet give limbs a direction, a collar
	and pauldrons give the shoulders mass, a jaw turns a cube into a head. Six
	untapered boxes read as a placeholder no matter how good the animation on
	top of them is, which is why the enemies looked cheap while moving well.

	Everything here is welded to a limb, so it follows the animation for free
	and costs nothing per frame.
]]
local function decorate(model: Model, spec: Spec, parts: any, s: number, bulk: number)
	local shape = spec.shape or "biped"
	local body = spec.body or Color3.fromRGB(126, 126, 130)
	local accent = spec.accent or Color3.fromRGB(84, 84, 88)
	local material = spec.material or Enum.Material.SmoothPlastic
	local dark = accent:Lerp(Color3.new(0, 0, 0), 0.35)

	local torso, head = parts.torso, parts.head
	local limbEnd = -1 * s -- the far end of a 2-stud limb, in limb space

	-- Hands and feet. Two welds per limb, and suddenly an arm has a direction.
	for _, side in { { parts.rArm, 1 }, { parts.lArm, -1 } } do
		local arm = side[1] :: BasePart
		local hand = newPart("Hand", Vector3.new(0.78 * bulk, 0.7, 0.9 * bulk) * s, dark, material, arm)
		weld(arm, hand, CFrame.new(0, limbEnd - 0.15 * s, -0.05 * s))

		if shape == "hulk" then
			-- Knuckles. A brute's threat is entirely in its hands.
			for i = -1, 1 do
				local knuckle = newPart("Knuckle", Vector3.new(0.2, 0.22, 0.34) * s, accent, Enum.Material.Slate, arm)
				weld(arm, knuckle, CFrame.new(i * 0.24 * s, limbEnd - 0.3 * s, -0.5 * s))
			end
		elseif shape == "quadruped" then
			local claw = newPart("Claw", Vector3.new(0.5, 0.16, 0.7) * s, accent, Enum.Material.Slate, arm)
			weld(arm, claw, CFrame.new(0, limbEnd - 0.42 * s, -0.35 * s))
		end
	end

	for _, leg in { parts.rLeg, parts.lLeg } do
		local foot = newPart("Foot", Vector3.new(0.92 * bulk, 0.42, 1.5) * s, dark, material, leg)
		-- Forward of centre: a foot centred under the ankle makes a character
		-- look like it is standing on stilts.
		weld(leg, foot, CFrame.new(0, limbEnd - 0.2 * s, -0.28 * s))
	end

	-- Shoulders and collar: where the mass reads from.
	for _, side in { 1, -1 } do
		local pauldron = newPart("Pauldron",
			Vector3.new(0.82 * bulk, 0.62, 1.25 * bulk) * s, accent, material, torso)
		weld(torso, pauldron, CFrame.new(side * 0.95 * bulk * s, 0.78 * s, 0)
			* CFrame.Angles(0, 0, math.rad(-side * 12)))
	end

	local collar = newPart("Collar", Vector3.new(1.15 * bulk, 0.34, 0.95 * bulk) * s, dark, material, torso)
	weld(torso, collar, CFrame.new(0, 0.94 * s, 0))

	if shape == "hulk" then
		local plate = newPart("Chest", Vector3.new(1.72 * bulk, 1.25, 0.3) * s, accent, Enum.Material.Metal, torso)
		weld(torso, plate, CFrame.new(0, 0.16 * s, -(0.5 * bulk * s) - 0.12 * s))
		for _, side in { 1, -1 } do
			local horn = newPart("Horn", Vector3.new(0.2, 0.95, 0.2) * s, dark, Enum.Material.Slate, head)
			weld(head, horn, CFrame.new(side * 0.4 * s, 0.5 * s, 0.1 * s)
				* CFrame.Angles(math.rad(-24), 0, math.rad(side * 26)))
		end
	end

	-- A jaw. The single cheapest part in this whole function and the one that
	-- does the most: it is the difference between a cube and a face.
	local jawSize = shape == "quadruped"
		and Vector3.new(0.62, 0.44, 1.05) * s
		or Vector3.new(0.82, 0.32, 0.72) * s
	local jawAt = shape == "quadruped"
		and CFrame.new(0, -0.2 * s, -0.72 * s)
		or CFrame.new(0, -0.42 * s, -0.24 * s)
	local jaw = newPart("Jaw", jawSize, dark, material, head)
	weld(head, jaw, jawAt)

	if shape == "quadruped" then
		-- Spines down the back and a tail, both on the torso, both following
		-- the 62 degree pitch that makes this rig an animal in the first place.
		for i = 0, 3 do
			local spine = newPart("Spine", Vector3.new(0.14, 0.42 - i * 0.06, 0.5) * s, accent, Enum.Material.Slate, torso)
			weld(torso, spine, CFrame.new(0, 0.55 * s - i * 0.4 * s, (0.5 * bulk * s) + 0.06 * s))
		end
		local tail = newPart("Tail", Vector3.new(0.34, 1.1, 0.34) * s, body, material, torso)
		weld(torso, tail, CFrame.new(0, -1.35 * s, 0.1 * s) * CFrame.Angles(math.rad(24), 0, 0))
		local tip = newPart("TailTip", Vector3.new(0.2, 0.9, 0.2) * s, accent, material, torso)
		weld(torso, tip, CFrame.new(0, -2.05 * s, 0.42 * s) * CFrame.Angles(math.rad(46), 0, 0))

		for _, side in { 1, -1 } do
			local ear = newPart("Ear", Vector3.new(0.12, 0.5, 0.3) * s, accent, material, head)
			weld(head, ear, CFrame.new(side * 0.34 * s, 0.5 * s, 0.2 * s)
				* CFrame.Angles(math.rad(-14), 0, math.rad(side * 18)))
		end
	else
		-- Ribs. Reads as gaunt on a husk and as armour on a brute, from the
		-- same four parts.
		for i = 0, 2 do
			for _, side in { 1, -1 } do
				local rib = newPart("Rib", Vector3.new(0.24, 0.16, 0.9 * bulk) * s, dark, material, torso)
				weld(torso, rib, CFrame.new(side * 0.62 * bulk * s, 0.34 * s - i * 0.36 * s, -0.36 * bulk * s))
			end
		end
	end

	-- Brow. Gives the eyes somewhere to sit instead of floating on a face.
	if spec.eyes then
		local brow = newPart("Brow", Vector3.new(0.98, 0.18, 0.24) * s, dark, material, head)
		weld(head, brow, CFrame.new(0, 0.3 * s, -0.52 * s) * CFrame.Angles(math.rad(10), 0, 0))
	end
end

-- ================================== R15 =====================================
--[[
	A fifteen-part rig, built in code.

	`Rig.build` has always produced R6: six boxes, six joints, and a whole
	engine of animation written against them. That was fine until the joint map
	grew elbows and knees, at which point there was nowhere to see them —
	the pose previewer builds its subject with this module, so a preview of an
	elbow bend on an R6 rig shows an arm that does not bend.

	The joint names here are not invented. They were read off a live R15
	character through the bridge: Root, Waist, Neck, then Shoulder/Elbow/Wrist
	and Hip/Knee/Ankle on each side. Names that do not match a real character
	would make every clip in the engine silently miss.

	--- The joint convention -----------------------------------------------

	A Motor6D holds `p1.CFrame = p0.CFrame * C0 * C1:inverse()`. Every joint
	below puts C0 at the attachment point on the parent and C1 at the matching
	point on the child, with no baked rotation. That is what makes a rotation
	about X read as "bend forward" — the assumption `Anim.rigs.R15` is written
	against. R6's joints carry legacy quarter-turns and its map compensates;
	inheriting those here would have silently mirrored every clip.
]]
local function buildR15(spec: Spec): Model
	local s = spec.scale or 1
	local body = spec.body or Color3.fromRGB(126, 126, 130)
	local accent = spec.accent or Color3.fromRGB(84, 84, 88)
	local material = spec.material or Enum.Material.SmoothPlastic
	local bulk = (spec.bulky or spec.shape == "hulk") and 1.3 or 1

	local model = Instance.new("Model")
	model.Name = spec.name or "Rig"

	local function part(name: string, size: Vector3, colour: Color3): BasePart
		return newPart(name, size * s, colour, material, model)
	end

	-- Proportions of a standard R15, near enough that clips authored for one
	-- read correctly on the other.
	local rootSize = Vector3.new(2 * bulk, 2, 1 * bulk)
	local lowerTorsoSize = Vector3.new(2 * bulk, 0.8, 1 * bulk)
	local upperTorsoSize = Vector3.new(2 * bulk, 1.2, 1 * bulk)
	local headSize = Vector3.new(1.2, 1.2, 1.2)
	local upperArmSize = Vector3.new(0.8 * bulk, 1.4, 0.8 * bulk)
	local lowerArmSize = Vector3.new(0.7 * bulk, 1.2, 0.7 * bulk)
	local handSize = Vector3.new(0.7 * bulk, 0.6, 0.7 * bulk)
	local upperLegSize = Vector3.new(0.9 * bulk, 1.4, 0.9 * bulk)
	local lowerLegSize = Vector3.new(0.8 * bulk, 1.4, 0.8 * bulk)
	local footSize = Vector3.new(0.9 * bulk, 0.5, 1.2)

	local root = part("HumanoidRootPart", rootSize, body)
	root.Transparency = 1
	root.CanCollide = spec.collide ~= false
	model.PrimaryPart = root

	local lowerTorso = part("LowerTorso", lowerTorsoSize, body)
	local upperTorso = part("UpperTorso", upperTorsoSize, body)
	local head = part("Head", headSize, accent)

	local limbs = {}
	for _, side in { "Right", "Left" } do
		limbs[side] = {
			upperArm = part(side .. "UpperArm", upperArmSize, body),
			lowerArm = part(side .. "LowerArm", lowerArmSize, body),
			hand = part(side .. "Hand", handSize, accent),
			upperLeg = part(side .. "UpperLeg", upperLegSize, accent),
			lowerLeg = part(side .. "LowerLeg", lowerLegSize, accent),
			foot = part(side .. "Foot", footSize, accent),
		}
	end

	--[[
		Attach the top of `child` under the given point on `parent`.

		The Motor6D is re-parented to the *child*, which is where Roblox puts
		it on a real R15 character -- `RightUpperArm.RightShoulder`, not
		`UpperTorso.RightShoulder`. `Anim` searches by name and would have found
		them either way, but anything that walks a rig expecting the real
		layout would not, and a rig that is R15 in every respect except where
		its joints live is a trap for the next reader.
	]]
	local function joint(name: string, p0: BasePart, p1: BasePart, at: Vector3)
		local m = motor(name, p0, p1, CFrame.new(at * s), CFrame.new(0, p1.Size.Y / 2, 0))
		m.Parent = p1
		return m
	end

	joint("Root", root, lowerTorso, Vector3.new(0, -rootSize.Y / 2 + lowerTorsoSize.Y, 0))
	joint("Waist", lowerTorso, upperTorso, Vector3.new(0, lowerTorsoSize.Y / 2 + upperTorsoSize.Y, 0))
	joint("Neck", upperTorso, head, Vector3.new(0, upperTorsoSize.Y / 2 + headSize.Y, 0))

	for _, side in { "Right", "Left" } do
		local sign = side == "Right" and 1 or -1
		local L = limbs[side]

		joint(side .. "Shoulder", upperTorso, L.upperArm,
			Vector3.new(sign * (upperTorsoSize.X / 2 + upperArmSize.X / 2),
				upperTorsoSize.Y / 2 - 0.1 + upperArmSize.Y, 0))
		joint(side .. "Elbow", L.upperArm, L.lowerArm,
			Vector3.new(0, -upperArmSize.Y / 2 + lowerArmSize.Y, 0))
		joint(side .. "Wrist", L.lowerArm, L.hand,
			Vector3.new(0, -lowerArmSize.Y / 2 + handSize.Y, 0))

		joint(side .. "Hip", lowerTorso, L.upperLeg,
			Vector3.new(sign * upperLegSize.X / 2, -lowerTorsoSize.Y / 2 + upperLegSize.Y, 0))
		joint(side .. "Knee", L.upperLeg, L.lowerLeg,
			Vector3.new(0, -upperLegSize.Y / 2 + lowerLegSize.Y, 0))
		joint(side .. "Ankle", L.lowerLeg, L.foot,
			Vector3.new(0, -lowerLegSize.Y / 2 + footSize.Y, 0))
	end

	if spec.eyes then
		for _, sign in { -1, 1 } do
			local eye = newPart("Eye", Vector3.new(0.16, 0.16, 0.1) * s, spec.eyes, Enum.Material.Neon, head)
			weld(head, eye, CFrame.new(0.3 * s * sign, 0.12 * s, -0.62 * s))
		end
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	--[[
		Seat every part once.

		A Motor6D positions its child only when something moves; parts left
		stacked at the origin stay stacked, and the rig renders as a pile of
		boxes until the first animation frame. Walking the chain once here puts
		everything where the joints say it belongs.
	]]
	root.CFrame = CFrame.new()
	local ordered = {
		{ "Root", root, lowerTorso }, { "Waist", lowerTorso, upperTorso },
		{ "Neck", upperTorso, head },
	}
	for _, side in { "Right", "Left" } do
		local L = limbs[side]
		table.insert(ordered, { side .. "Shoulder", upperTorso, L.upperArm })
		table.insert(ordered, { side .. "Elbow", L.upperArm, L.lowerArm })
		table.insert(ordered, { side .. "Wrist", L.lowerArm, L.hand })
		table.insert(ordered, { side .. "Hip", lowerTorso, L.upperLeg })
		table.insert(ordered, { side .. "Knee", L.upperLeg, L.lowerLeg })
		table.insert(ordered, { side .. "Ankle", L.lowerLeg, L.foot })
	end
	for _, row in ordered do
		local name, parent, child = row[1], row[2] :: BasePart, row[3] :: BasePart
		local m = child:FindFirstChild(name) :: Motor6D?
		if m then
			child.CFrame = parent.CFrame * m.C0 * m.C1:Inverse()
		end
	end

	if spec.weapon then
		Rig.attachWeapon(model, spec.weapon, accent, s)
	end

	model:SetAttribute("ForgeRig", true)
	model:SetAttribute("RigScale", s)
	model:SetAttribute("RigShape", "biped")
	model:SetAttribute("RigType", "R15")
	return model
end

function Rig.build(spec: Spec): Model
	-- R6 stays the default: every enemy, every clip and every joint sign in
	-- this engine was authored against it. R15 is opt-in until something has
	-- actually looked at one.
	if spec.rigType == "R15" then
		return buildR15(spec)
	end

	local s = spec.scale or 1
	local shape = spec.shape or "biped"
	local body = spec.body or Color3.fromRGB(126, 126, 130)
	local accent = spec.accent or Color3.fromRGB(84, 84, 88)
	local material = spec.material or Enum.Material.SmoothPlastic
	local bulk = (spec.bulky or shape == "hulk") and 1.35 or 1

	local model = Instance.new("Model")
	model.Name = spec.name or "Rig"

	local torsoSize = Vector3.new(2 * bulk, 2, 1 * bulk) * s

	local root = newPart("HumanoidRootPart", torsoSize, body, material, model)
	root.Transparency = 1
	root.CanCollide = spec.collide ~= false
	model.PrimaryPart = root

	local torso = newPart("Torso", torsoSize, body, material, model)
	local headScale = shape == "hulk" and 1.2 or 1
	local head = newPart("Head", Vector3.new(1.15, 1.15, 1.15) * s * headScale, accent, material, model)

	local limb = Vector3.new(1 * bulk, 2, 1 * bulk) * s
	local rArm = newPart("Right Arm", limb, body, material, model)
	local lArm = newPart("Left Arm", limb, body, material, model)
	local rLeg = newPart("Right Leg", limb, accent, material, model)
	local lLeg = newPart("Left Leg", limb, accent, material, model)

	-- The whole quadruped trick: pitch the torso and the same six joints read
	-- as an animal. Front limbs become forelegs, the neck reaches forward.
	local pitch = shape == "quadruped" and math.rad(62) or 0
	local neckForward = shape == "quadruped" and -0.4 * s or 0
	local neckHeight = (shape == "quadruped" and 0.85 or 1) * s

	motor("RootJoint", root, torso,
		CFrame.new(0, 0, 0) * CFrame.Angles(-HALF, 0, math.pi) * CFrame.Angles(0, 0, pitch),
		CFrame.new(0, 0, 0) * CFrame.Angles(-HALF, 0, math.pi))

	motor("Neck", torso, head,
		CFrame.new(0, neckHeight, neckForward) * CFrame.Angles(-HALF, 0, math.pi),
		CFrame.new(0, -0.5 * s, 0) * CFrame.Angles(-HALF, 0, math.pi))

	motor("Right Shoulder", torso, rArm,
		CFrame.new(1 * bulk * s, 0.5 * s, 0) * CFrame.Angles(0, HALF, 0),
		CFrame.new(-0.5 * bulk * s, 0.5 * s, 0) * CFrame.Angles(0, HALF, 0))
	motor("Left Shoulder", torso, lArm,
		CFrame.new(-1 * bulk * s, 0.5 * s, 0) * CFrame.Angles(0, -HALF, 0),
		CFrame.new(0.5 * bulk * s, 0.5 * s, 0) * CFrame.Angles(0, -HALF, 0))
	motor("Right Hip", torso, rLeg,
		CFrame.new(0.5 * bulk * s, -1 * s, 0) * CFrame.Angles(0, HALF, 0),
		CFrame.new(0.5 * bulk * s, 1 * s, 0) * CFrame.Angles(0, HALF, 0))
	motor("Left Hip", torso, lLeg,
		CFrame.new(-0.5 * bulk * s, -1 * s, 0) * CFrame.Angles(0, -HALF, 0),
		CFrame.new(-0.5 * bulk * s, 1 * s, 0) * CFrame.Angles(0, -HALF, 0))

	if spec.eyes then
		for _, side in { -1, 1 } do
			local eye = newPart("Eye", Vector3.new(0.16, 0.16, 0.1) * s, spec.eyes, Enum.Material.Neon, head)
			weld(head, eye, CFrame.new(0.28 * s * side, 0.12 * s, -0.6 * s))
		end
	end

	if spec.spikes then
		for i = 1, 4 do
			local spike = newPart("Spike", Vector3.new(0.22, 0.9, 0.22) * s, accent, Enum.Material.Slate, torso)
			weld(torso, spike, CFrame.new(0, 0.8 * s - (i - 1) * 0.45 * s, 0.5 * s) * CFrame.Angles(math.rad(28), 0, 0))
		end
	end

	if spec.glow then
		local seam = newPart("Seam", Vector3.new(torsoSize.X * 0.85, 0.16 * s, 0.12), accent, Enum.Material.Neon, torso)
		weld(torso, seam, CFrame.new(0, 0.1 * s, -torsoSize.Z / 2))
		local light = Instance.new("PointLight")
		light.Color = accent
		light.Range = 12 * s
		light.Brightness = 1.4
		light.Parent = torso
	end

	if spec.weapon then
		Rig.attachWeapon(model, spec.weapon, accent, s)
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R6
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model

	-- Place the parts once. From here the Motor6Ds own them.
	local origin = CFrame.new()
	root.CFrame = origin
	torso.CFrame = origin
	head.CFrame = origin * CFrame.new(0, 1.5 * s, 0)
	rArm.CFrame = origin * CFrame.new(1.5 * s, 0, 0)
	lArm.CFrame = origin * CFrame.new(-1.5 * s, 0, 0)
	rLeg.CFrame = origin * CFrame.new(0.5 * s, -2 * s, 0)
	lLeg.CFrame = origin * CFrame.new(-0.5 * s, -2 * s, 0)

	-- Detail last: it welds to parts whose final resting places are set above.
	if spec.detail ~= false then
		decorate(model, spec, {
			torso = torso, head = head,
			rArm = rArm, lArm = lArm, rLeg = rLeg, lLeg = lLeg,
		}, s, bulk)
	end

	model:SetAttribute("ForgeRig", true)
	model:SetAttribute("RigScale", s)
	model:SetAttribute("RigShape", shape)

	return model
end

local WEAPON_SIZES: { [string]: Vector3 } = {
	sword = Vector3.new(0.22, 4.0, 0.6),
	axe = Vector3.new(0.26, 3.2, 0.5),
	greatsword = Vector3.new(0.34, 6.4, 0.95),
	staff = Vector3.new(0.28, 5.2, 0.28),
	dagger = Vector3.new(0.18, 2.0, 0.4),
}

--[[
	Put a weapon in a rig's hand.

	Kept as the short form used by `Rig.build`'s `weapon` field; it is
	`buildWeapon` plus `grip` and nothing else. It used to be a second,
	subtly different way to assemble a weapon, which is how enemies ended up
	holding blades at a believable angle and players holding them at none.
]]
function Rig.attachWeapon(model: Model, kind: string, color: Color3, scale: number): BasePart?
	local weapon = Rig.buildWeapon(kind, { color = color, scale = scale, name = "Weapon" })
	local held = Rig.grip(model, weapon, { parent = model })
	if not held then
		weapon:Destroy()
		return nil
	end
	return held.part
end

-- =================================== grip ===================================
--[[
	Putting something in a character's hand.

	One primitive for every case: a sword on a husk, a bow on a player, a crate
	carried in both arms, a lantern, a quest item. The engine does not care
	which — it welds a thing to a hand and gives you a handle to take it back.

	The two rig types keep their differences here rather than at every call
	site. An R6 arm is a two-stud box whose hand end is at its bottom; an R15
	`RightHand` is its own part and grips near its centre. Callers that had to
	know that got it wrong, which is why weapons used to sit correctly on
	enemies and nowhere near a player's hand.

		local held = Rig.grip(character, Rig.buildWeapon("longbow"))
		held:release()

	Anything gripped is made non-collidable and massless: a weapon that
	collides with the world drags its owner into geometry, and a heavy one
	changes how the character walks.
]]
local HAND_NAMES = {
	right = { "RightHand", "Right Arm" },
	left = { "LeftHand", "Left Arm" },
}

function Rig.hand(character: Model, side: string?): BasePart?
	for _, name in HAND_NAMES[side or "right"] or HAND_NAMES.right do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

-- Where a held thing sits, per rig. R6 grips at the bottom of the arm box;
-- R15 grips inside the hand itself.
local function defaultGrip(hand: BasePart): CFrame
	if hand.Name == "Right Arm" or hand.Name == "Left Arm" then
		return CFrame.new(0, -hand.Size.Y / 2, -0.1)
	end
	return CFrame.new(0, -0.15, -0.1)
end

function Rig.grip(character: Model, thing: Instance, options: any?): any?
	local opts = options or {}
	local hand = Rig.hand(character, opts.hand)
	if not hand then
		warn(string.format("[Rig] '%s' has no %s hand to grip with", character.Name, opts.hand or "right"))
		return nil
	end

	local primary: BasePart? = nil
	if thing:IsA("BasePart") then
		primary = thing
	elseif thing:IsA("Model") then
		primary = thing.PrimaryPart or thing:FindFirstChildWhichIsA("BasePart", true)
	end
	if not primary then
		warn("[Rig] nothing to grip: no BasePart in " .. thing:GetFullName())
		return nil
	end

	for _, d in thing:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.Massless = true
		end
	end
	if thing:IsA("BasePart") then
		(thing :: BasePart).CanCollide = false
		;(thing :: BasePart).Massless = true
	end

	local offset = opts.offset or defaultGrip(hand)
	primary.CFrame = hand.CFrame * offset
	local w = weld(hand, primary, offset)
	w.Name = "Grip"
	thing.Parent = opts.parent or character

	local handle = {
		part = primary,
		hand = hand,
		weld = w,
		thing = thing,
	}

	--[[
		Give it back.

		`keep` drops the object into the world where the hand was, which is what
		putting something down means. Without it the object is destroyed, which
		is what a consumed item means. Both are wanted often enough that
		choosing for the caller would be wrong.
	]]
	function handle:release(keep: boolean?)
		if self.weld then
			self.weld:Destroy()
			self.weld = nil
		end
		if not keep then
			self.thing:Destroy()
			return
		end
		for _, d in self.thing:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = true
				d.Massless = false
			end
		end
		if self.thing:IsA("BasePart") then
			(self.thing :: BasePart).CanCollide = true
			;(self.thing :: BasePart).Massless = false
		end
		self.thing.Parent = Workspace
	end

	return handle
end

-- =============================== weapon models ==============================
--[[
	Weapons built in code, as models with a `Grip` primary part.

	They exist because a shooting system whose weapons are invisible is a
	shooting system nobody believes. These are simple assemblies of boxes, and
	they are meant to be replaced by real meshes — but a blocky bow that is
	actually in the character's hand communicates more than a perfect mesh that
	is not there.
]]
function Rig.buildWeapon(kind: string, options: any?): Model
	local o = options or {}
	local scale = o.scale or 1
	local color = o.color or Color3.fromRGB(196, 202, 214)
	local accent = o.accent or color:Lerp(Color3.new(0, 0, 0), 0.45)

	local model = Instance.new("Model")
	model.Name = o.name or kind

	local grip = newPart("Grip", Vector3.new(0.26, 1.0, 0.3) * scale, accent, Enum.Material.Wood, model)
	model.PrimaryPart = grip

	if kind == "longbow" or kind == "bow" then
		-- Two limbs and a string. The string is what sells it: without a line
		-- between the tips this reads as a stick.
		for _, side in { 1, -1 } do
			local limb = newPart("Limb", Vector3.new(0.16, 2.1, 0.16) * scale, color, Enum.Material.Wood, model)
			weld(grip, limb, CFrame.new(0, side * 1.4 * scale, 0.18 * scale)
				* CFrame.Angles(math.rad(side * 14), 0, 0))
			local tip = newPart("Tip", Vector3.new(0.12, 0.4, 0.12) * scale, accent, Enum.Material.Wood, model)
			weld(grip, tip, CFrame.new(0, side * 2.5 * scale, 0.45 * scale))
		end
		local string_ = newPart("String", Vector3.new(0.04, 5.0, 0.04) * scale,
			Color3.fromRGB(226, 222, 208), Enum.Material.SmoothPlastic, model)
		weld(grip, string_, CFrame.new(0, 0, 0.52 * scale))
	elseif kind == "handcannon" then
		local body = newPart("Body", Vector3.new(0.42, 0.5, 1.5) * scale, color, Enum.Material.Metal, model)
		weld(grip, body, CFrame.new(0, 0.62 * scale, -0.45 * scale))
		local barrel = newPart("Barrel", Vector3.new(0.28, 0.28, 1.5) * scale, accent, Enum.Material.Metal, model)
		weld(grip, barrel, CFrame.new(0, 0.66 * scale, -1.5 * scale))
		local muzzle = newPart("Muzzle", Vector3.new(0.36, 0.36, 0.22) * scale, accent, Enum.Material.Metal, model)
		weld(grip, muzzle, CFrame.new(0, 0.66 * scale, -2.2 * scale))
		local sight = newPart("Sight", Vector3.new(0.08, 0.18, 0.1) * scale, accent, Enum.Material.Metal, model)
		weld(grip, sight, CFrame.new(0, 0.95 * scale, -0.9 * scale))
	else
		local size = (WEAPON_SIZES[kind] or WEAPON_SIZES.sword) * scale
		local material = kind == "staff" and Enum.Material.Wood or Enum.Material.Metal
		local blade = newPart("Blade", size, color, material, model)
		weld(grip, blade, CFrame.new(0, size.Y / 2 - 0.1 * scale, 0))

		if kind == "axe" then
			local headPart = newPart("AxeHead", Vector3.new(0.2, 1.1, 1.5) * scale, color, Enum.Material.Metal, model)
			weld(grip, headPart, CFrame.new(0, size.Y - 0.6 * scale, -0.5 * scale))
		elseif kind == "staff" then
			local orb = newPart("Orb", Vector3.new(0.7, 0.7, 0.7) * scale, color, Enum.Material.Neon, model)
			orb.Shape = Enum.PartType.Ball
			weld(grip, orb, CFrame.new(0, size.Y, 0))
			local light = Instance.new("PointLight")
			light.Color = color
			light.Range = 16
			light.Brightness = 2
			light.Parent = orb
		else
			-- A crossguard, so a sword is not a rectangle.
			local guard = newPart("Guard", Vector3.new(1.1, 0.18, 0.34) * scale, accent, Enum.Material.Metal, model)
			weld(grip, guard, CFrame.new(0, 0.55 * scale, 0))
		end
		Rig.addTrail(blade, color, size.Y)
	end

	model:SetAttribute("ForgeWeapon", kind)
	return model
end

-- A trail that starts disabled. Anim markers switch it on for the swing window,
-- which is what makes a strike read as a strike instead of a teleporting arm.
function Rig.addTrail(part: BasePart, color: Color3, length: number): Trail
	local a0 = Instance.new("Attachment")
	a0.Name = "TrailTop"
	a0.Position = Vector3.new(0, length / 2, 0)
	a0.Parent = part

	local a1 = Instance.new("Attachment")
	a1.Name = "TrailBottom"
	a1.Position = Vector3.new(0, -length / 2, 0)
	a1.Parent = part

	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.22
	trail.MinLength = 0.1
	trail.LightEmission = 0.6
	trail.Enabled = false
	trail.Color = ColorSequence.new(color)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Parent = part
	return trail
end

--[[
	Roblox ships an `Animate` LocalScript inside every player character, and it
	writes the same Motor6D C0 values procedural animation writes. Left in
	place, the two fight and the result looks like stuttering.

	Call this once per character before binding an Animator. It is separate
	from Anim on purpose: it is a fact about Roblox, not about animation.
]]
--[[
	Hand a character's joints over to Forge.

	Roblox drives a character through two things, and stopping only the first
	is not enough:

	  * the `Animate` script, which decides *which* animation to play;
	  * the Humanoid's `Animator`, which evaluates animations and writes the
	    joints.

	This used to destroy the script and merely stop the playing tracks. On a
	Motor6D rig that was survivable: Roblox and Forge write different
	properties. On Roblox's current R15 player rig the joints are
	`AnimationConstraint`, both systems write the same `Transform`, and the
	Animator resets it to rest every single frame. The result was a player
	standing perfectly still while every clip in the engine played correctly
	into a value that was overwritten microseconds later.

	Measured: with the Animator present, 30 of 30 samples read identity. With
	it removed, 30 of 30 carried the pose. No render priority is late enough to
	win that fight -- the Animator has to go.

	The trade-off is real and worth stating: a character stripped this way
	cannot play Roblox `AnimationTrack`s any more. For a game animating
	procedurally that is the point. For one that wants both, do not call this.
]]
function Rig.stripDefaultAnimate(character: Model)
	local animate = character:FindFirstChild("Animate")
	if animate then
		animate:Destroy()
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
		animator:Destroy()
	end
end

function Rig.tint(model: Model, color: Color3, skip: { [string]: boolean }?)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not (skip and skip[d.Name]) then
			d.Color = color
		end
	end
end

-- Structural facts about one rig, for a caller that has one in hand.
function Rig.describeModel(model: Model): { [string]: any }
	local joints, parts = {}, {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			table.insert(joints, d.Name)
		elseif d:IsA("BasePart") then
			table.insert(parts, d.Name)
		end
	end
	table.sort(joints)
	table.sort(parts)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return {
		name = model.Name,
		joints = joints,
		partCount = #parts,
		hasHumanoid = humanoid ~= nil,
		rigType = humanoid and humanoid.RigType.Name or nil,
		scale = model:GetAttribute("RigScale"),
		shape = model:GetAttribute("RigShape"),
		primaryPart = model.PrimaryPart and model.PrimaryPart.Name or nil,
	}
end

--[[
	Module-level description, called with no arguments by Debug.snapshot.

	The first version of this file only had `Rig.describe(model)`, so the
	snapshot invoked it with nil and every reading came back as
	"attempt to index nil with 'GetDescendants'". The seam caught it on the
	first real read, which is exactly what the seam is for.
]]
function Rig.describe(): { [string]: any }
	local built, byShape = 0, {}
	for _, descendant in workspace:GetDescendants() do
		if descendant:IsA("Model") and descendant:GetAttribute("ForgeRig") then
			built += 1
			local shape = descendant:GetAttribute("RigShape") or "unknown"
			byShape[shape] = (byShape[shape] or 0) + 1
		end
	end
	return { rigsInWorld = built, byShape = byShape }
end


--[[
	Siblings, resolved on the first thing that asks for one.

	This family holds modules beside this file, and until now the only way to
	reach them was to require the instance directly — so `Forge.Rig.Ragdoll`
	was nil while `require(ReplicatedStorage.Forge.Rig.Ragdoll)` worked. Two
	conventions in one engine, and the inconsistency is the defect: the first
	game written against `Forge.Core.Boot` died on `attempt to index nil`.

	Lazy rather than eager, matching `Forge` itself. Touching one family must
	not drag in every module it contains — several of them build tables and
	open connections at load, and paying for all of that to read one constant
	is how a require graph becomes a frame budget.
]]
return setmetatable(Rig, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
