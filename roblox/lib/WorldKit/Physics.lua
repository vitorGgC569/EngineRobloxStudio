--!strict
--- A world that moves: ropes, springs, joints, forces, and falling over.
---
--- `Interact` gave the world welds and hinges, which are rigid: a door turns, a
--- crate is stuck to a pallet. Nothing swung, stretched, pushed or collapsed.
--- `RopeConstraint`, `SpringConstraint`, `BallSocketConstraint`,
--- `PrismaticConstraint`, `VectorForce` and `AlignPosition` were all at zero,
--- and so was ragdoll -- which is what a body does when it stops being a
--- character and starts being an object.
---
--- **Attachments are the boring half, and the half that gets forgotten.** Every
--- constraint in Roblox joins two `Attachment`s, not two parts. Parenting a
--- constraint with a nil attachment raises nothing and does nothing; it simply
--- sits in the explorer looking installed. Everything here makes its own
--- attachments, positions them, and sets both ends before parenting.
---
--- **Anchored parts ignore all of this, silently.** The same trap as welding,
--- and it is worth stating twice because it is the first thing to check when a
--- machine does not move. A rope between two anchored parts is a decoration.
---
--- **Ragdoll is not "turn off the Humanoid".** A character is held together by
--- `Motor6D`s, and the Humanoid drives them. Disabling the Humanoid leaves the
--- Motor6Ds holding the body rigid in its last pose -- a statue that falls over
--- as one piece. A real ragdoll replaces each Motor6D with a BallSocket at the
--- same attachment points, which is fiddly enough that nobody does it twice.

local Players = game:GetService("Players")

local Physics = {}

export type Anchorage = {
	--- Where on each part the joint sits, in the part's own space. Defaults to
	--- the centre, which is right for ropes and wrong for hinges.
	offsetA: Vector3?,
	offsetB: Vector3?,
}

local function attach(part: BasePart, name: string, offset: Vector3?): Attachment
	local point = Instance.new("Attachment")
	point.Name = name
	point.Position = offset or Vector3.zero
	point.Parent = part
	return point
end

local function bothAnchored(a: BasePart, b: BasePart): boolean
	return a.Anchored and b.Anchored
end

local function refuseAnchored(a: BasePart, b: BasePart, what: string)
	if bothAnchored(a, b) then
		error(("%s and %s are both anchored, so a %s between them does nothing")
			:format(a.Name, b.Name, what), 0)
	end
end

--- A rope: a maximum distance, and slack until it is reached.
function Physics.rope(a: BasePart, b: BasePart, options: { [string]: any }?): RopeConstraint
	local opts = options or {}
	refuseAnchored(a, b, "rope")

	local rope = Instance.new("RopeConstraint")
	rope.Name = "RQERope"
	rope.Attachment0 = attach(a, "RQERope", opts.offsetA)
	rope.Attachment1 = attach(b, "RQERope", opts.offsetB)
	-- Default to the current separation: a rope shorter than the gap yanks the
	-- parts together the instant it is created, which reads as an explosion.
	rope.Length = tonumber(opts.length) or (a.Position - b.Position).Magnitude
	rope.Visible = opts.visible ~= false
	rope.Restitution = tonumber(opts.bounce) or 0
	rope.Parent = a
	return rope
end

--- A spring: pulls back towards a rest length.
function Physics.spring(a: BasePart, b: BasePart, options: { [string]: any }?): SpringConstraint
	local opts = options or {}
	refuseAnchored(a, b, "spring")

	local spring = Instance.new("SpringConstraint")
	spring.Name = "RQESpring"
	spring.Attachment0 = attach(a, "RQESpring", opts.offsetA)
	spring.Attachment1 = attach(b, "RQESpring", opts.offsetB)
	spring.FreeLength = tonumber(opts.restLength) or (a.Position - b.Position).Magnitude
	spring.Stiffness = tonumber(opts.stiffness) or 2000
	-- Undamped springs oscillate forever and look like a bug. There is no
	-- sensible zero here, so the default damps.
	spring.Damping = tonumber(opts.damping) or 200
	spring.Visible = opts.visible == true
	spring.Parent = a
	return spring
end

--- A ball socket: turns freely, optionally within a cone. Ragdoll joints.
function Physics.ballSocket(a: BasePart, b: BasePart,
	options: { [string]: any }?): BallSocketConstraint

	local opts = options or {}
	local socket = Instance.new("BallSocketConstraint")
	socket.Name = "RQESocket"
	socket.Attachment0 = opts.attachment0 or attach(a, "RQESocket", opts.offsetA)
	socket.Attachment1 = opts.attachment1 or attach(b, "RQESocket", opts.offsetB)
	socket.LimitsEnabled = opts.limits ~= false
	socket.UpperAngle = tonumber(opts.cone) or 45
	socket.TwistLimitsEnabled = opts.twistLimits == true
	socket.Parent = a
	return socket
end

--- A slider: moves along one axis and nothing else. Lifts, pistons, drawers.
function Physics.slider(a: BasePart, b: BasePart,
	options: { [string]: any }?): PrismaticConstraint

	local opts = options or {}
	refuseAnchored(a, b, "slider")

	local axis = opts.axis or Vector3.new(0, 1, 0)
	local first = attach(a, "RQESlider", opts.offsetA)
	local second = attach(b, "RQESlider", opts.offsetB)
	-- Both attachments must share an axis or the constraint refuses to solve
	-- and the parts jitter in place.
	first.Axis = axis
	second.Axis = axis

	local slider = Instance.new("PrismaticConstraint")
	slider.Name = "RQESlider"
	slider.Attachment0 = first
	slider.Attachment1 = second
	slider.LimitsEnabled = opts.limits ~= false
	slider.LowerLimit = tonumber(opts.lower) or 0
	slider.UpperLimit = tonumber(opts.upper) or 8
	if opts.motor then
		slider.ActuatorType = Enum.ActuatorType.Motor
		slider.MotorMaxForce = tonumber(opts.force) or 10000
		slider.Velocity = tonumber(opts.speed) or 2
	end
	slider.Parent = a
	return slider
end

--- A steady push. Wind, thrust, a conveyor that works on anything.
function Physics.push(part: BasePart, force: Vector3,
	options: { [string]: any }?): VectorForce

	local opts = options or {}
	if part.Anchored then
		error(part.Name .. " is anchored, so no force will move it", 0)
	end

	local vector = Instance.new("VectorForce")
	vector.Name = "RQEForce"
	vector.Attachment0 = attach(part, "RQEForce", opts.offset)
	vector.Force = force
	-- World, not the attachment's frame: a force relative to a tumbling part
	-- changes direction as it tumbles, which is almost never what was meant.
	vector.RelativeTo = if opts.relative == true
		then Enum.ActuatorRelativeTo.Attachment0
		else Enum.ActuatorRelativeTo.World
	vector.ApplyAtCenterOfMass = opts.atCentre ~= false
	vector.Parent = part
	return vector
end

--- Hold a part at a position without anchoring it: floating, hovering, magnets.
function Physics.hold(part: BasePart, position: Vector3,
	options: { [string]: any }?): AlignPosition

	local opts = options or {}
	if part.Anchored then
		error(part.Name .. " is anchored; it is already held, immovably", 0)
	end

	local target = Instance.new("Attachment")
	target.Name = "RQEHoldTarget"
	target.WorldPosition = position
	target.Parent = workspace.Terrain

	local align = Instance.new("AlignPosition")
	align.Name = "RQEHold"
	align.Attachment0 = attach(part, "RQEHold", opts.offset)
	align.Attachment1 = target
	align.MaxForce = tonumber(opts.force) or 20000
	align.Responsiveness = tonumber(opts.responsiveness) or 25
	align.Parent = part
	return align
end

--- Turn a character into a body: replace every Motor6D with a ball socket.
---
--- The Humanoid keeps the parts rigid through its Motor6Ds, so switching it off
--- gives a statue that topples in one piece. Each Motor6D is swapped for a
--- BallSocket at the same two attachment points, which is what makes the limbs
--- fold.
---
--- Returns the number of joints converted, so a caller can tell a real ragdoll
--- from a character that had no Motor6Ds to begin with.
function Physics.ragdoll(model: Model): (number, { string })
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return 0, { "ragdoll needs a Model" }
	end

	local problems = {}
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		-- Stop it standing up again. Without this the Humanoid fights the
		-- constraints and the body twitches on the floor.
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		humanoid.PlatformStand = true
		pcall(function()
			humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		end)
	else
		table.insert(problems, model.Name .. " has no Humanoid; joints were still converted")
	end

	local converted = 0
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("Motor6D") and item.Part0 ~= nil and item.Part1 ~= nil then
			local socket = Instance.new("BallSocketConstraint")
			socket.Name = "RQERagdoll_" .. item.Name

			local first = Instance.new("Attachment")
			first.CFrame = item.C0
			first.Parent = item.Part0
			local second = Instance.new("Attachment")
			second.CFrame = item.C1
			second.Parent = item.Part1

			socket.Attachment0 = first
			socket.Attachment1 = second
			socket.LimitsEnabled = true
			socket.UpperAngle = 60
			socket.TwistLimitsEnabled = true
			socket.TwistLowerAngle = -45
			socket.TwistUpperAngle = 45
			socket.Parent = item.Part0

			item.Enabled = false
			converted += 1
		end
	end

	if converted == 0 then
		table.insert(problems,
			"no Motor6D joints found, so nothing can fold -- this model is loose "
			.. "parts rather than a rig, and Physics.rope or ballSocket is the "
			.. "way to make it collapse")
	end
	model:SetAttribute("Ragdolled", converted > 0)
	return converted, problems
end

--- What in this world can move, and what is quietly inert.
function Physics.report(root: Instance?): { [string]: any }
	local host = root or workspace
	local counts = {
		ropes = 0, springs = 0, sockets = 0, sliders = 0,
		forces = 0, holds = 0, motors = 0,
	}
	local inert = {}

	for _, item in ipairs(host:GetDescendants()) do
		if item:IsA("RopeConstraint") then counts.ropes += 1
		elseif item:IsA("SpringConstraint") then counts.springs += 1
		elseif item:IsA("BallSocketConstraint") then counts.sockets += 1
		elseif item:IsA("PrismaticConstraint") then counts.sliders += 1
		elseif item:IsA("VectorForce") then counts.forces += 1
		elseif item:IsA("AlignPosition") then counts.holds += 1
		elseif item:IsA("Motor6D") then counts.motors += 1
		end

		if item:IsA("Constraint") then
			-- Forces and velocities are one-ended by design: a push has
			-- somewhere to act, not two things to join. Reporting their missing
			-- `Attachment1` as a fault made the diagnostic cry wolf on every
			-- `Physics.push`, which is worse than not having it.
			local oneEnded = item:IsA("VectorForce") or item:IsA("Torque")
				or item:IsA("LinearVelocity") or item:IsA("AngularVelocity")
				or item:IsA("AlignOrientation") and item.Mode == Enum.OrientationAlignmentMode.OneAttachment

			-- The two failures that look identical to a working constraint.
			if item.Attachment0 == nil or (not oneEnded and item.Attachment1 == nil) then
				table.insert(inert, item:GetFullName() .. " has an unattached end")
			elseif not oneEnded and item.Attachment1 ~= nil then
				local a = item.Attachment0.Parent
				local b = item.Attachment1.Parent
				if a ~= nil and b ~= nil and a:IsA("BasePart") and b:IsA("BasePart")
					and a.Anchored and b.Anchored then
					table.insert(inert,
						item:GetFullName() .. " joins two anchored parts and cannot move")
				end
			end
		end
	end

	counts.constraints = counts.ropes + counts.springs + counts.sockets
		+ counts.sliders
	counts.inert = inert
	return counts
end

return Physics
