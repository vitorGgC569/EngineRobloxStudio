--!strict
--[[
	IK — putting a hand or a foot where the world is, not where the clip said.

	Forward kinematics, which is everything this engine has done so far, works
	from the shoulder outwards: you choose angles and the hand ends up wherever
	that puts it. It is exact, cheap and completely blind to the world. A walk
	clip authored on flat ground puts a foot six inches into a slope, and a
	two-handed grip authored for one weapon misses the next one.

	Inverse kinematics runs the other way: you name the point the hand or foot
	must reach and it solves for the angles. Two bones and a hinge is the whole
	problem, and it has a closed-form answer — no iteration, no solver, no
	per-frame cost worth measuring.

		IK.footPlant(character, { maxDrop = 3 })     -- feet follow the ground
		IK.reach(character, "right", targetPosition) -- hand goes to a point

	--- Where this sits ------------------------------------------------------

	IK runs *after* the animator has posed the skeleton, as a correction. That
	order matters: the clip still decides what the body is doing, and this only
	adjusts the last two bones of a limb so the end lands correctly. Running it
	first, or instead, gives you a character that reaches things beautifully
	and has no performance.

	R15 only, and honestly so. An R6 rig has no elbow or knee, so there is no
	second bone to solve for and nothing here can help it.
]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local IK = {}

IK.config = {
	-- How fast a correction blends in. Instant looks like a glitch; this is
	-- fast enough to track a slope and slow enough to look like a body.
	smoothing = 12,
	-- Feet stop looking for ground beyond this, so a character walking off a
	-- cliff does not stretch a leg down to the sea.
	maxDrop = 4,
	footOffset = 0.5,
}

-- =============================== two bones ==================================
--[[
	Solve a two-bone chain.

	Given the length of the upper and lower bone and the straight-line distance
	to the target, the law of cosines gives both joint angles directly. Returns
	the shoulder-side and elbow-side angles in radians.

	The clamp is the important part. If the target is further than both bones
	can reach, the honest answer is "point straight at it and fall short" — the
	alternative is a NaN from `math.acos` of something greater than one, which
	propagates into a CFrame and makes the whole limb vanish.
]]
function IK.solveTwoBone(upper: number, lower: number, distance: number): (number, number)
	local reach = math.clamp(distance, math.abs(upper - lower) + 1e-3, upper + lower - 1e-3)

	local cosUpper = (upper * upper + reach * reach - lower * lower) / (2 * upper * reach)
	local cosElbow = (upper * upper + lower * lower - reach * reach) / (2 * upper * lower)

	local shoulder = math.acos(math.clamp(cosUpper, -1, 1))
	local elbow = math.pi - math.acos(math.clamp(cosElbow, -1, 1))
	return shoulder, elbow
end

-- ================================ helpers ===================================
local function findJoint(character: Model, name: string): (Motor6D | AnimationConstraint)?
	local found = character:FindFirstChild(name, true)
	if found and (found:IsA("Motor6D") or found:IsA("AnimationConstraint")) then
		return found :: any
	end
	return nil
end

local function jointTransform(joint: Motor6D | AnimationConstraint): CFrame
	if joint:IsA("Motor6D") then
		return joint.C0
	end
	return joint.Transform
end

local function setJointTransform(joint: Motor6D | AnimationConstraint, value: CFrame)
	if joint:IsA("Motor6D") then
		joint.C0 = value
	else
		joint.Transform = value
	end
end

local function partOf(character: Model, name: string): BasePart?
	local found = character:FindFirstChild(name)
	return found and found:IsA("BasePart") and found or nil
end

-- ================================ foot plant ================================
local planted: { [Model]: any } = {}
local plantConn: RBXScriptConnection? = nil

--[[
	Keep both feet on whatever is under them.

	One raycast per foot per frame, straight down from the hip. If the ground
	is higher than the clip expected, the knee bends to take up the difference;
	if it is lower, the leg extends until it runs out and then simply hangs,
	which is what a leg does over a ledge.

	This is the single cheapest thing that makes a character look like it is
	standing *on* terrain rather than intersecting it.
]]
local function stepFoot(character: Model, side: string, state: any, dt: number)
	local hipName = side .. "UpperLeg"
	local shinName = side .. "LowerLeg"
	local footName = side .. "Foot"

	local hip = partOf(character, hipName)
	local shin = partOf(character, shinName)
	local foot = partOf(character, footName)
	local kneeJoint = findJoint(character, side .. "Knee")
	local hipJoint = findJoint(character, side .. "Hip")
	if not (hip and shin and foot and kneeJoint and hipJoint) then
		return
	end

	local origin = hip.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local drop = IK.config.maxDrop
	local hit = Workspace:Raycast(origin, Vector3.new(0, -(hip.Size.Y + shin.Size.Y + drop), 0), params)

	local wanted = 0
	if hit then
		local restY = origin.Y - (hip.Size.Y + shin.Size.Y)
		local groundY = hit.Position.Y + IK.config.footOffset
		-- Only ever shorten the leg. Extending it to chase ground below the
		-- rest pose is what makes characters do the splits on stairs.
		wanted = math.max(0, groundY - restY)
	end

	state[side] = state[side] or 0
	local blend = 1 - math.exp(-IK.config.smoothing * dt)
	state[side] += (wanted - state[side]) * blend

	local lift = state[side]
	if lift < 0.01 then
		return
	end

	local upperLength = hip.Size.Y
	local lowerLength = shin.Size.Y
	local target = math.max(0.2, (upperLength + lowerLength) - lift)
	local hipAngle, kneeAngle = IK.solveTwoBone(upperLength, lowerLength, target)

	--[[
		Compose with the animation; do not replace it.

		The first version wrote `restPose * correction`, which discarded
		whatever the animator had just put in the joint. That is not a subtle
		bug: `Stepped` fires *after* `RenderStepped`, so this ran last every
		frame and the walk cycle was overwritten by a static IK pose. The
		character stood with its legs locked and slid across the floor — a
		freeze, reported as one, and caused by the correction being applied to
		the wrong thing.

		Reading the joint's current value first means the clip still decides
		what the legs are doing and this only adds the amount needed to reach
		the ground.
	]]
	setJointTransform(kneeJoint, jointTransform(kneeJoint) * CFrame.Angles(kneeAngle, 0, 0))
	setJointTransform(hipJoint, jointTransform(hipJoint) * CFrame.Angles(-hipAngle * 0.5, 0, 0))
end

function IK.footPlant(character: Model, options: any?): any
	local opts = options or {}
	local hipBase, kneeBase = {}, {}
	for _, side in { "Right", "Left" } do
		local hipJoint = findJoint(character, side .. "Hip")
		local kneeJoint = findJoint(character, side .. "Knee")
		if not (hipJoint and kneeJoint) then
			-- R6 has no knee. Saying so beats silently doing nothing.
			warn(string.format("[IK] '%s' has no %s knee; foot planting needs an R15 rig", character.Name, side))
			return nil
		end
		hipBase[side] = jointTransform(hipJoint)
		kneeBase[side] = jointTransform(kneeJoint)
	end

	-- Kept for `clearFootPlant` to put the legs back, not for the per-frame
	-- correction, which composes with whatever the animator wrote.
	local state = { hipBase = hipBase, kneeBase = kneeBase }
	planted[character] = state
	if opts.maxDrop then
		IK.config.maxDrop = opts.maxDrop
	end

	if not plantConn then
		plantConn = RunService.Stepped:Connect(function(_, dt)
			for model, modelState in planted do
				if not model.Parent then
					planted[model] = nil
					continue
				end
				stepFoot(model, "Right", modelState, dt)
				stepFoot(model, "Left", modelState, dt)
			end
			local any = false
			for _ in planted do
				any = true
				break
			end
			if not any and plantConn then
				plantConn:Disconnect()
				plantConn = nil
			end
		end)
	end
	return state
end

function IK.clearFootPlant(character: Model)
	local state = planted[character]
	if state then
		for _, side in { "Right", "Left" } do
			local hipJoint = findJoint(character, side .. "Hip")
			local kneeJoint = findJoint(character, side .. "Knee")
			if hipJoint and state.hipBase[side] then
				setJointTransform(hipJoint, state.hipBase[side])
			end
			if kneeJoint and state.kneeBase[side] then
				setJointTransform(kneeJoint, state.kneeBase[side])
			end
		end
	end
	planted[character] = nil
end

-- ================================== reach ===================================
--[[
	Put a hand on a point in the world.

	Used for the thing that has been visibly wrong in this project all day: a
	second hand that should be on the bow and is instead near it. With a
	solved elbow the hand goes *to* the grip rather than approximately toward
	it, and the same call works for a ladder rung, a door handle or a ledge.

	Returns whether the point was reachable. A caller that ignores that will
	happily animate a character straining at something two studs too far away.
]]
function IK.reach(character: Model, side: string, target: Vector3, options: any?): boolean
	local opts = options or {}
	local prefix = side:sub(1, 1):upper() .. side:sub(2):lower()
	if prefix ~= "Right" and prefix ~= "Left" then
		prefix = "Right"
	end

	local upperArm = partOf(character, prefix .. "UpperArm")
	local lowerArm = partOf(character, prefix .. "LowerArm")
	local shoulderJoint = findJoint(character, prefix .. "Shoulder")
	local elbowJoint = findJoint(character, prefix .. "Elbow")
	if not (upperArm and lowerArm and shoulderJoint and elbowJoint) then
		return false
	end

	local shoulderPos = upperArm.Position + Vector3.new(0, upperArm.Size.Y / 2, 0)
	local toTarget = target - shoulderPos
	local distance = toTarget.Magnitude

	local upperLength = upperArm.Size.Y
	local lowerLength = lowerArm.Size.Y
	local reachable = distance <= (upperLength + lowerLength)

	local shoulderAngle, elbowAngle = IK.solveTwoBone(upperLength, lowerLength, distance)

	-- Aim the whole arm at the target, then bend the elbow by the solved
	-- amount. Two rotations, in that order, is the entire algorithm.
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local reference = root and root.CFrame or CFrame.new(shoulderPos)
	local localDir = reference:VectorToObjectSpace(toTarget.Unit)

	local yaw = math.atan2(localDir.X, -localDir.Z)
	local pitch = math.asin(math.clamp(localDir.Y, -1, 1))

	local base = opts.base or CFrame.new()
	setJointTransform(shoulderJoint, base
		* CFrame.Angles(-(math.pi / 2) - pitch + shoulderAngle, 0, 0)
		* CFrame.Angles(0, yaw, 0))
	setJointTransform(elbowJoint, CFrame.Angles(elbowAngle, 0, 0))

	return reachable
end

--[[
	Hold a hand on a gripped object, every frame.

	The off hand of a two-handed weapon is the classic case: the weapon is
	welded to one hand and the other has to follow it wherever the animation
	takes it. Solved rather than authored, it stays correct for every clip and
	every weapon, including ones written later.
]]
function IK.holdWith(character: Model, side: string, attachment: BasePart, offset: Vector3?): RBXScriptConnection
	local delta = offset or Vector3.zero
	return RunService.Stepped:Connect(function()
		if not character.Parent or not attachment.Parent then
			return
		end
		IK.reach(character, side, (attachment.CFrame * CFrame.new(delta)).Position)
	end)
end

function IK.describe(): { [string]: any }
	local count = 0
	for _ in planted do
		count += 1
	end
	return {
		footPlanted = count,
		running = plantConn ~= nil,
		requires = "R15 (a two-bone limb needs an elbow and a knee)",
	}
end

return IK
