--!strict
--[[
	Ragdoll — a body that stops being animated and starts being physics.

	How it actually works
	---------------------

	A Roblox character is held together by `Motor6D` joints, which are motors:
	they *drive* the limbs to a pose every frame, and physics has no say. Turn
	them off and the limbs fall apart, because nothing else is holding them on.

	So a ragdoll is two moves, and both are needed:

	  1. Disable the motors, so nothing is forcing a pose.
	  2. Replace them with `BallSocketConstraint`s between the attachment pairs
	     the rig already carries, so the limbs stay attached and swing.

	Every character has those attachments already — R15 rigs ship with matching
	`*RigAttachment` pairs on each side of every joint, which is exactly what a
	constraint needs. The whole technique is finding the pairs by name.

		Ragdoll.enable(character)
		Ragdoll.disable(character)     -- back to animated, standing

	The Root pair is skipped, deliberately
	--------------------------------------

	`RootRigAttachment` joins the HumanoidRootPart to the torso, and that joint
	is what the Humanoid stands on. Ball-socketing it makes the character fall
	through its own physics: the root keeps trying to stand while the body
	hangs off it, and the result is a corpse that hovers and vibrates.

	The limits matter more than they look
	-------------------------------------

	A `BallSocketConstraint` with no limit lets a knee bend backwards through
	the thigh, and the body ends up in a knot that reads as a glitch rather
	than a death. `LimitsEnabled` with a cone is the difference between a
	ragdoll and a bag of parts.
]]

local Ragdoll = {}

--: How far a joint may swing, in degrees. Generous enough to look loose,
--: tight enough that limbs do not fold through each other.
Ragdoll.upperAngle = 89
Ragdoll.twistLower = -45
Ragdoll.twistUpper = 45

local active: { [Model]: { Motor6D } } = {}

-- ================================== enable ==================================
--[[
	Find the attachment pairs a rig already has.

	Matched by name: `LeftUpperArmRigAttachment` exists on both the torso and
	the arm, and the two of them are the joint. Anything without a partner is
	an attachment for something else — a tool grip, a trail, an accessory —
	and is left alone.
]]
local function pairsByName(character: Model): { [string]: { Attachment } }
	local found: { [string]: { Attachment } } = {}
	for _, descendant in character:GetDescendants() do
		if not descendant:IsA("Attachment") then
			continue
		end
		local name = descendant.Name
		if not string.find(name, "RigAttachment") then
			continue
		end
		-- The root joint is what the Humanoid stands on. Ball-socketing it
		-- produces a body that hovers and shakes instead of falling.
		if string.find(name, "Root") then
			continue
		end
		local list = found[name]
		if not list then
			list = {}
			found[name] = list
		end
		table.insert(list, descendant)
	end
	return found
end

--[[
	Go limp.

	Returns whether anything changed, so a caller can tell a fresh ragdoll from
	a repeat call — which matters when death fires twice, as it does.
]]
function Ragdoll.enable(character: Model, options: any?): boolean
	if active[character] then
		return false
	end
	local opts = options or {}

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		--[[
			`PlatformStand`, not `Sit` and not setting the state to Physics.

			It is the one state that stops the Humanoid trying to balance
			without also fighting the constraints. A Humanoid left in Running
			keeps applying the standing force to a body that is on the floor,
			and the corpse crawls.
		]]
		humanoid.PlatformStand = true
		if opts.stopAnimations ~= false then
			local animator = humanoid:FindFirstChildOfClass("Animator")
			if animator then
				for _, track in animator:GetPlayingAnimationTracks() do
					track:Stop(0)
				end
			end
		end
	end

	local disabled: { Motor6D } = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant.Name ~= "RootJoint" then
			descendant.Enabled = false
			table.insert(disabled, descendant)
		end
	end

	for _, pair in pairsByName(character) do
		if #pair ~= 2 then
			continue
		end
		local socket = Instance.new("BallSocketConstraint")
		socket.Name = "ForgeRagdollJoint"
		socket.Attachment0 = pair[1]
		socket.Attachment1 = pair[2]
		socket.LimitsEnabled = true
		socket.TwistLimitsEnabled = true
		socket.UpperAngle = opts.upperAngle or Ragdoll.upperAngle
		socket.TwistLowerAngle = opts.twistLower or Ragdoll.twistLower
		socket.TwistUpperAngle = opts.twistUpper or Ragdoll.twistUpper
		socket.Parent = pair[1].Parent
	end

	-- Limbs that cannot be walked through. A ragdoll whose arms pass through
	-- the floor is a ragdoll that sinks into it.
	if opts.collide ~= false then
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
				descendant.CanCollide = true
			end
		end
	end

	active[character] = disabled
	return true
end

-- ================================= disable ==================================
--[[
	Stand back up.

	The constraints go, the motors come back, and the Humanoid is told to
	stand. Order matters: re-enabling the motors while the sockets are still
	there means two things are holding each joint and they fight, which throws
	the character across the room.
]]
function Ragdoll.disable(character: Model): boolean
	local disabled = active[character]
	if not disabled then
		return false
	end

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BallSocketConstraint") and descendant.Name == "ForgeRagdollJoint" then
			descendant:Destroy()
		end
	end

	for _, motor in disabled do
		if motor.Parent then
			motor.Enabled = true
		end
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end

	active[character] = nil
	return true
end

function Ragdoll.isRagdolled(character: Model): boolean
	return active[character] ~= nil
end

-- ================================== impulse =================================
--[[
	Throw the body.

	The reason to ragdoll on death rather than just play a die animation: a
	corpse that flies away from the blast tells the player what killed them.
	Applied to the torso rather than the root, because the root is not part of
	the constraint chain and pushing it drags a limp body by the neck.
]]
function Ragdoll.impulse(character: Model, force: Vector3)
	local torso = character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart")
	if torso and torso:IsA("BasePart") then
		torso:ApplyImpulse(force * torso.AssemblyMass)
	end
end

--[[
	Go limp for a moment and get up again.

	The stagger, as distinct from the death. Returns immediately; the recovery
	rides a `task.delay`, and a character destroyed in between is checked for
	rather than assumed.
]]
function Ragdoll.stagger(character: Model, seconds: number, force: Vector3?)
	Ragdoll.enable(character)
	if force then
		Ragdoll.impulse(character, force)
	end
	task.delay(seconds, function()
		if character.Parent then
			Ragdoll.disable(character)
		end
	end)
end

function Ragdoll.describe(): { [string]: any }
	local count = 0
	for _ in active do
		count += 1
	end
	return {
		ragdolled = count,
		upperAngle = Ragdoll.upperAngle,
		twist = { Ragdoll.twistLower, Ragdoll.twistUpper },
	}
end

return Ragdoll
