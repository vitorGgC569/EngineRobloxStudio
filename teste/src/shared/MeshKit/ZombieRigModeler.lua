--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ZombieCatalog = require(ReplicatedStorage.Shared.ZombieCatalog)

local ZombieRigModeler = {}

local function createLimb(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = false
	part.CanCollide = true
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

function ZombieRigModeler.build(zombieId: string, spawnCFrame: CFrame): Model
	local def = ZombieCatalog.get(zombieId) or ZombieCatalog.Zombies.walker
	local scale = def.bodyScale

	local rig = Instance.new("Model")
	rig.Name = "Zombie_" .. def.id

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = def.maxHealth
	humanoid.Health = def.maxHealth
	humanoid.WalkSpeed = def.walkSpeed
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.NameDisplayDistance = 60
	humanoid.HealthDisplayDistance = 60
	humanoid.Parent = rig

	-- HumanoidRootPart
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2 * scale.width, 2 * scale.height, 1 * scale.depth)
	root.CFrame = spawnCFrame * CFrame.new(0, 3 * scale.height, 0)
	root.Transparency = 1
	root.CanCollide = false
	root.Parent = rig
	rig.PrimaryPart = root

	-- Torso
	local torso = createLimb("Torso", Vector3.new(2 * scale.width, 2 * scale.height, 1 * scale.depth), root.CFrame, def.primaryColor, Enum.Material.Fabric, rig)
	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0 = root
	rootJoint.Part1 = torso
	rootJoint.C0 = CFrame.new(0, 0, 0)
	rootJoint.C1 = CFrame.new(0, 0, 0)
	rootJoint.Parent = root

	-- Head
	local head = createLimb("Head", Vector3.new(1.25 * scale.width, 1.25 * scale.height, 1.25 * scale.depth), root.CFrame * CFrame.new(0, 1.6 * scale.height, 0), def.primaryColor, Enum.Material.Slate, rig)
	local neck = Instance.new("Motor6D")
	neck.Name = "Neck"
	neck.Part0 = torso
	neck.Part1 = head
	neck.C0 = CFrame.new(0, 1 * scale.height, 0)
	neck.C1 = CFrame.new(0, -0.6 * scale.height, 0)
	neck.Parent = torso

	-- Glowing Eye Sockets
	local leftEye = Instance.new("Part")
	leftEye.Name = "LeftEye"
	leftEye.Size = Vector3.new(0.25 * scale.width, 0.25 * scale.height, 0.1)
	leftEye.CFrame = head.CFrame * CFrame.new(-0.35 * scale.width, 0.15 * scale.height, -0.65 * scale.depth)
	leftEye.Color = def.eyeGlowColor
	leftEye.Material = Enum.Material.Neon
	leftEye.CanCollide = false
	leftEye.Parent = rig

	local rightEye = Instance.new("Part")
	rightEye.Name = "RightEye"
	rightEye.Size = Vector3.new(0.25 * scale.width, 0.25 * scale.height, 0.1)
	rightEye.CFrame = head.CFrame * CFrame.new(0.35 * scale.width, 0.15 * scale.height, -0.65 * scale.depth)
	rightEye.Color = def.eyeGlowColor
	rightEye.Material = Enum.Material.Neon
	rightEye.CanCollide = false
	rightEye.Parent = rig

	local weldL = Instance.new("WeldConstraint")
	weldL.Part0 = head
	weldL.Part1 = leftEye
	weldL.Parent = head

	local weldR = Instance.new("WeldConstraint")
	weldR.Part0 = head
	weldR.Part1 = rightEye
	weldR.Parent = head

	-- Left Arm
	local leftArm = createLimb("LeftArm", Vector3.new(1 * scale.width, 2 * scale.height, 1 * scale.depth), root.CFrame * CFrame.new(-1.5 * scale.width, 0, 0), def.primaryColor, Enum.Material.Fabric, rig)
	local leftShoulder = Instance.new("Motor6D")
	leftShoulder.Name = "LeftShoulder"
	leftShoulder.Part0 = torso
	leftShoulder.Part1 = leftArm
	leftShoulder.C0 = CFrame.new(-1 * scale.width, 0.5 * scale.height, 0)
	leftShoulder.C1 = CFrame.new(0.5 * scale.width, 0.5 * scale.height, 0)
	leftShoulder.Parent = torso

	-- Right Arm
	local rightArm = createLimb("RightArm", Vector3.new(1 * scale.width, 2 * scale.height, 1 * scale.depth), root.CFrame * CFrame.new(1.5 * scale.width, 0, 0), def.primaryColor, Enum.Material.Fabric, rig)
	local rightShoulder = Instance.new("Motor6D")
	rightShoulder.Name = "RightShoulder"
	rightShoulder.Part0 = torso
	rightShoulder.Part1 = rightArm
	rightShoulder.C0 = CFrame.new(1 * scale.width, 0.5 * scale.height, 0)
	rightShoulder.C1 = CFrame.new(-0.5 * scale.width, 0.5 * scale.height, 0)
	rightShoulder.Parent = torso

	-- Left Leg
	local leftLeg = createLimb("LeftLeg", Vector3.new(1 * scale.width, 2 * scale.height, 1 * scale.depth), root.CFrame * CFrame.new(-0.5 * scale.width, -2 * scale.height, 0), Color3.fromRGB(35, 38, 42), Enum.Material.Fabric, rig)
	local leftHip = Instance.new("Motor6D")
	leftHip.Name = "LeftHip"
	leftHip.Part0 = torso
	leftHip.Part1 = leftLeg
	leftHip.C0 = CFrame.new(-0.5 * scale.width, -1 * scale.height, 0)
	leftHip.C1 = CFrame.new(0, 1 * scale.height, 0)
	leftHip.Parent = torso

	-- Right Leg
	local rightLeg = createLimb("RightLeg", Vector3.new(1 * scale.width, 2 * scale.height, 1 * scale.depth), root.CFrame * CFrame.new(0.5 * scale.width, -2 * scale.height, 0), Color3.fromRGB(35, 38, 42), Enum.Material.Fabric, rig)
	local rightHip = Instance.new("Motor6D")
	rightHip.Name = "RightHip"
	rightHip.Part0 = torso
	rightHip.Part1 = rightLeg
	rightHip.C0 = CFrame.new(0.5 * scale.width, -1 * scale.height, 0)
	rightHip.C1 = CFrame.new(0, 1 * scale.height, 0)
	rightHip.Parent = torso

	rig:SetAttribute("ZombieType", zombieId)
	rig:SetAttribute("MaxHealth", def.maxHealth)
	rig:SetAttribute("Damage", def.damage)
	rig:SetAttribute("AttackRate", def.attackRate)
	rig:SetAttribute("AttackRange", def.attackRange)
	rig:SetAttribute("DetectionRadius", def.detectionRadius)
	rig:SetAttribute("ScrapReward", def.scrapReward)
	rig:SetAttribute("XpReward", def.xpReward)

	return rig
end

return ZombieRigModeler
