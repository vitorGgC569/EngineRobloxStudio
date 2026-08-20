--!strict
--[[
	Anim — layered procedural animation with markers.

	Why not AnimationTrack and rbxassetid
	-------------------------------------
	Authored animation needs the Animation Editor and an upload, which means a
	human in a GUI for every timing change. That is fine for a studio and fatal
	for an agent: the one thing that most needs iteration becomes the one thing
	that cannot be iterated.

	Here a clip is *data*. It works on R6 and R15, it needs no asset, and — the
	part that actually matters — it carries its own MARKERS. The frame a sword
	becomes dangerous lives in the same table as the pose that swings it. Move
	the pose, the hit window moves with it. That is what makes combat timing
	tunable without touching combat logic.

	This does not replace authored animation. When you have a real animator,
	keep the clip names and the marker names and swap the pose source; every
	system that listened for "hit" still works.

	Track convention (degrees)
	--------------------------
	  swing   forward/back — the primary axis of a limb
	  spread  outward, away from the body
	  twist   rotation about the limb's own axis, or torso yaw

	Usage
	-----
		local anim = Anim.new(character)
		anim:setLocomotion(Anim.profiles.grounded)
		anim:onMarker(function(clip, marker) ... end)

		local playback = anim:play("attack_1", { speed = 1.2 })
		Anim.bind(anim)   -- drives it on the right loop for this context
]]

local RunService = game:GetService("RunService")

local Ease = require(script.Parent.Core.Ease)

local Anim = {}

-- ===================== joint mapping, per rig type ==========================
-- axis: 1 = X, 2 = Y, 3 = Z of the joint's own C0 frame. sign flips mirrored limbs.
-- Add an entry here to support a custom skeleton; nothing else needs to change.

Anim.rigs = {
	R6 = {
		rightArm = { name = "Right Shoulder", swing = { 3, 1 }, spread = { 1, 1 }, twist = { 2, 1 } },
		leftArm = { name = "Left Shoulder", swing = { 3, -1 }, spread = { 1, -1 }, twist = { 2, -1 } },
		rightLeg = { name = "Right Hip", swing = { 3, 1 }, spread = { 1, 1 }, twist = { 2, 1 } },
		leftLeg = { name = "Left Hip", swing = { 3, -1 }, spread = { 1, -1 }, twist = { 2, -1 } },
		torso = { name = "RootJoint", swing = { 1, -1 }, spread = { 2, 1 }, twist = { 3, 1 } },
		head = { name = "Neck", swing = { 1, -1 }, spread = { 2, 1 }, twist = { 3, 1 } },
	},
	R15 = {
		rightArm = { name = "RightShoulder", swing = { 1, 1 }, spread = { 3, -1 }, twist = { 2, 1 } },
		leftArm = { name = "LeftShoulder", swing = { 1, 1 }, spread = { 3, 1 }, twist = { 2, -1 } },
		rightLeg = { name = "RightHip", swing = { 1, 1 }, spread = { 3, -1 }, twist = { 2, 1 } },
		leftLeg = { name = "LeftHip", swing = { 1, 1 }, spread = { 3, 1 }, twist = { 2, -1 } },
		torso = { name = "Waist", swing = { 1, 1 }, spread = { 3, 1 }, twist = { 2, 1 } },
		head = { name = "Neck", swing = { 1, 1 }, spread = { 3, 1 }, twist = { 2, 1 } },

		--[[
			The limbs below the first joint.

			R15 has fifteen joints and this engine drove six of them. That gap
			had a visible cost: asked for an archer holding a bow with both
			hands, the best a shoulder-only rig can do is point the whole arm
			in roughly the right direction, and the draw hand ends up out in
			space instead of at the string. There is no elbow to bend, so it
			cannot be posed — only aimed.

			Names were read off a live character rather than remembered, which
			is how the rest of this file's mistakes were made.

			R6 has no equivalent joints at all. Nothing special handles that:
			an animator only builds entries for joints it actually finds, so a
			clip with forearm tracks plays its shoulder tracks on an R6 rig and
			silently drops the rest.
		]]
		rightForearm = { name = "RightElbow", swing = { 1, 1 }, spread = { 3, -1 }, twist = { 2, 1 } },
		leftForearm = { name = "LeftElbow", swing = { 1, 1 }, spread = { 3, 1 }, twist = { 2, -1 } },
		rightShin = { name = "RightKnee", swing = { 1, 1 }, spread = { 3, -1 }, twist = { 2, 1 } },
		leftShin = { name = "LeftKnee", swing = { 1, 1 }, spread = { 3, 1 }, twist = { 2, -1 } },
		rightHand = { name = "RightWrist", swing = { 1, 1 }, spread = { 3, -1 }, twist = { 2, 1 } },
		leftHand = { name = "LeftWrist", swing = { 1, 1 }, spread = { 3, 1 }, twist = { 2, -1 } },
		rightFoot = { name = "RightAnkle", swing = { 1, 1 }, spread = { 3, -1 }, twist = { 2, 1 } },
		leftFoot = { name = "LeftAnkle", swing = { 1, 1 }, spread = { 3, 1 }, twist = { 2, -1 } },
	},
}

--[[
	Joint groups, used as clip masks.

	Every clip written before the lower limbs existed keeps working unchanged:
	a mask names joints, a clip only moves the joints it has tracks for, and a
	joint with no track holds at zero — which is the straight arm and straight
	leg those clips were authored against.
]]
Anim.JOINTS = {
	"rightArm", "leftArm", "rightLeg", "leftLeg", "torso", "head",
	"rightForearm", "leftForearm", "rightShin", "leftShin",
	"rightHand", "leftHand", "rightFoot", "leftFoot",
}
Anim.UPPER = {
	"rightArm", "leftArm", "torso", "head",
	"rightForearm", "leftForearm", "rightHand", "leftHand",
}
Anim.LOWER = { "rightLeg", "leftLeg", "rightShin", "leftShin", "rightFoot", "leftFoot" }
Anim.ARMS = { "rightArm", "leftArm", "rightForearm", "leftForearm", "rightHand", "leftHand" }

-- The six every rig has, R6 included. Clips masked to this play identically
-- everywhere, which is what an enemy shared between rig types needs.
Anim.CORE = { "rightArm", "leftArm", "rightLeg", "leftLeg", "torso", "head" }

-- ============================ clip authoring ================================
-- k(t, swing, spread, twist) — one keyframe on one joint's track.
function Anim.k(t: number, swing: number, spread: number?, twist: number?)
	return { t = t, swing = swing, spread = spread or 0, twist = twist or 0 }
end

local clips: { [string]: any } = {}
Anim.clips = clips

--[[
	Anim.register("attack_1", {
		duration = 0.52,
		mask = Anim.UPPER,      -- joints this clip owns; the rest keep walking
		priority = 2,           -- >= priority cancels lower clips
		loop = false, hold = false,
		ease = "smooth",
		tracks = { rightArm = { Anim.k(0, -20, 10), Anim.k(0.18, -150, 24) } },
		markers = { { t = 0.26, name = "hit" } },
	})
]]
function Anim.register(name: string, clip: any)
	assert(type(clip) == "table", "[Anim] clip must be a table")
	assert(type(clip.duration) == "number" and clip.duration > 0, string.format("[Anim] clip '%s' needs a positive duration", name))
	clip.name = name
	clip.tracks = clip.tracks or {}
	clip.markers = clip.markers or {}
	clip.mask = clip.mask or Anim.JOINTS
	clip.priority = clip.priority or 1

	for _, marker in clip.markers do
		if marker.t > clip.duration then
			warn(string.format("[Anim] clip '%s': marker '%s' at %.2fs is past the end (%.2fs) and will never fire", name, tostring(marker.name), marker.t, clip.duration))
		end
	end

	clips[name] = clip
	return clip
end

function Anim.registerAll(table_: { [string]: any })
	for name, clip in table_ do
		Anim.register(name, clip)
	end
end

-- ========================== locomotion profiles =============================
-- Walking is not a clip. It is a function of velocity, which is why it never
-- desyncs from the character's actual speed the way a fixed-length walk cycle
-- does. Profiles are data so a heavy golem and a darting rat differ by numbers.

Anim.profiles = {
	grounded = {
		idleRate = 1.4,
		idleAmount = 2.2,
		cadence = 6.2,
		cadenceScale = 1 / 8,
		cadenceRange = { 0.8, 2.6 },
		armAmplitude = 0.72,
		legAmplitude = 1.0,
		amplitudeScale = 2.6,
		amplitudeRange = { 14, 52 },
		lean = 0.55,
		leanMax = 16,
		airborne = {
			arms = { swing = -70, spread = 26 },
			legs = { swing = { -22, 16 }, spread = 6 },
			torso = -6,
		},
	},
	heavy = {
		idleRate = 0.9,
		idleAmount = 1.4,
		cadence = 4.0,
		cadenceScale = 1 / 10,
		cadenceRange = { 0.6, 1.6 },
		armAmplitude = 0.45,
		legAmplitude = 0.8,
		amplitudeScale = 1.8,
		amplitudeRange = { 10, 34 },
		lean = 0.3,
		leanMax = 8,
		airborne = {
			arms = { swing = -40, spread = 18 },
			legs = { swing = { -14, 10 }, spread = 4 },
			torso = -4,
		},
	},
	skittering = {
		idleRate = 3.0,
		idleAmount = 3.4,
		cadence = 11.0,
		cadenceScale = 1 / 5,
		cadenceRange = { 1.2, 3.4 },
		armAmplitude = 0.9,
		legAmplitude = 1.15,
		amplitudeScale = 3.4,
		amplitudeRange = { 18, 64 },
		lean = 0.8,
		leanMax = 22,
		airborne = {
			arms = { swing = -80, spread = 34 },
			legs = { swing = { -30, 22 }, spread = 8 },
			torso = -10,
		},
	},
}

-- ================================ runtime ===================================
local Animator = {}
Animator.__index = Animator

local function sampleTrack(track, t: number, ease: (number) -> number)
	local n = #track
	if n == 0 then
		return 0, 0, 0
	end
	if t <= track[1].t then
		local f = track[1]
		return f.swing, f.spread, f.twist
	end
	for i = 1, n - 1 do
		local a, b = track[i], track[i + 1]
		if t <= b.t then
			local span = b.t - a.t
			local alpha = span > 0 and ease((t - a.t) / span) or 1
			return a.swing + (b.swing - a.swing) * alpha,
				a.spread + (b.spread - a.spread) * alpha,
				a.twist + (b.twist - a.twist) * alpha
		end
	end
	local last = track[n]
	return last.swing, last.spread, last.twist
end

function Anim.new(character: Model): any
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rigType = (humanoid and humanoid.RigType == Enum.HumanoidRigType.R15) and "R15" or "R6"
	local map = Anim.rigs[rigType]

	local self = setmetatable({
		character = character,
		humanoid = humanoid,
		root = character:FindFirstChild("HumanoidRootPart"),
		rigType = rigType,
		joints = {},
		playing = {},
		applied = {},
		additive = {},
		profile = Anim.profiles.grounded,
		locomotion = true,
		-- On by default: a clip with no `rootMotion` curve costs nothing, and a
		-- clip that has one almost certainly means it.
		rootMotion = true,
		enabled = true,
		smoothing = 22,
		phase = 0,
		_markerHandlers = {},
	}, Animator)

	--[[
		Two joint systems, one animator.

		Rigs built in code use `Motor6D`, animated by writing `C0`. Roblox's
		current player characters do not: their joints are `AnimationConstraint`,
		animated by writing `Transform`. Same names, same skeleton, different
		class and a different property.

		This mattered more than it sounds. Forge looked for Motor6D only, found
		none on a real player, and silently animated nothing — every clip in the
		engine was a no-op on the one character a person actually controls,
		while the code-built NPCs beside them moved correctly. A stiff player
		sliding across the floor was the only symptom.
	]]
	local byName: { [string]: Instance } = {}
	for _, d in character:GetDescendants() do
		if (d:IsA("Motor6D") or d:IsA("AnimationConstraint")) and byName[d.Name] == nil then
			byName[d.Name] = d
		end
	end

	local kinds = { Motor6D = 0, AnimationConstraint = 0 }
	for key, def in map do
		local joint = byName[def.name]
		if joint then
			local isMotor = joint:IsA("Motor6D")
			--[[
				Both kinds animate as an offset *from a rest pose*, and both
				rest poses have to be captured here.

				Writing a bare rotation into an AnimationConstraint's Transform
				throws the rest pose away, and the limb detaches: arms floating
				beside the body instead of hanging from the shoulder. The rig
				looks broken rather than badly animated, which is a much more
				alarming symptom for a one-word cause.
			]]
			local base = isMotor
				and (joint :: Motor6D).C0
				or (joint :: AnimationConstraint).Transform
			self.joints[key] = {
				motor = joint,
				base = base,
				kind = isMotor and "Motor6D" or "AnimationConstraint",
				def = def,
			}
			self.applied[key] = { swing = 0, spread = 0, twist = 0 }
			kinds[isMotor and "Motor6D" or "AnimationConstraint"] += 1
		end
	end
	self.jointKinds = kinds

	if next(self.joints) == nil then
		warn(string.format(
			"[Anim] '%s' has no recognised joints; is it a %s rig?",
			character.Name, rigType
		))
	end

	return self
end

function Animator:setProfile(profile: any)
	self.profile = profile or Anim.profiles.grounded
end

function Animator:setLocomotion(enabled: boolean)
	self.locomotion = enabled
end

-- (clipName, markerName, playback)
function Animator:onMarker(fn: (string, string, any) -> ())
	table.insert(self._markerHandlers, fn)
	return function()
		local i = table.find(self._markerHandlers, fn)
		if i then
			table.remove(self._markerHandlers, i)
		end
	end
end

function Animator:play(clipName: string, options: any?): any
	local clip = clips[clipName]
	if not clip then
		warn(string.format("[Anim] no clip named '%s'", tostring(clipName)))
		return nil
	end
	local opts = options or {}

	--[[
		Layers, and what cancels what.

		Until now a clip cancelled every playing clip of equal or lower
		priority, which is correct for one stream of full-body motion and wrong
		for everything else: playing a reload cancelled the sprint, and a flinch
		cancelled the aim. Every game works around that by not layering, which
		is why this engine's characters do one thing at a time.

		A layer is a named stream. Clips only cancel others *on their own
		layer*, so `base` can carry locomotion while `upper` carries a reload
		and `additive` carries a flinch, all at once. The mask still decides
		which joints each one writes, so two layers that overlap resolve by
		priority exactly as before.

		Unnamed clips land on `base`, so every existing call keeps its old
		behaviour.
	]]
	local layer = opts.layer or clip.layer or "base"
	for name, pb in self.playing do
		if pb.layer == layer and (clips[name].priority or 1) <= (clip.priority or 1) then
			pb.fading = true
		end
	end

	local playback = {
		clip = clip,
		name = clipName,
		layer = layer,
		-- Weight the whole clip can be scaled by, independent of blending.
		-- A half-weight flinch is a flinch that does not interrupt aiming.
		gain = opts.weight or 1,
		t = 0,
		speed = opts.speed or 1,
		weight = 0,
		blendIn = opts.blendIn or 0.08,
		blendOut = opts.blendOut or 0.14,
		fired = {},
		fading = false,
		onMarker = opts.onMarker,
		ease = Ease.get(opts.ease or clip.ease),
	}
	self.playing[clipName] = playback
	return playback
end

function Animator:stop(clipName: string, immediate: boolean?)
	local pb = self.playing[clipName]
	if not pb then
		return
	end
	if immediate then
		self.playing[clipName] = nil
	else
		pb.fading = true
	end
end

function Animator:stopAll(immediate: boolean?)
	for name, pb in self.playing do
		if immediate then
			self.playing[name] = nil
		else
			pb.fading = true
		end
	end
end

function Animator:isPlaying(clipName: string): boolean
	local pb = self.playing[clipName]
	return pb ~= nil and not pb.fading
end

-- Additive offsets ride on top of everything: recoil, look-at, hit reaction.
-- Set them from a Spring and you get physical secondary motion for free.
-- ================================ root motion ===============================
--[[
	Movement that comes from the animation instead of from the controller.

	A dodge that plays a roll while the controller applies an impulse is two
	systems guessing at the same distance, and they disagree: the roll ends
	early, or the body slides past the end of it. Root motion makes the clip
	the authority — the animation says how far the body travels and the
	controller does nothing.

	A clip declares it as a curve of offsets in the character's own space:

		dodge = {
			duration = 0.45,
			rootMotion = { k(0, 0, 0, 0), k(0.3, 0, 0, -14), k(0.45, 0, 0, -16) },
			tracks = { ... },
		}

	Applied as a delta each frame rather than an absolute position, so it
	composes with whatever else is moving the character and never teleports it
	back to where the clip thought it started.
]]
function Animator:setRootMotion(enabled: boolean)
	self.rootMotion = enabled
end

function Animator:_rootMotion(dt: number)
	if self.rootMotion == false or not self.root or not self.root.Parent then
		return
	end
	local root = self.root :: BasePart

	for _, pb in self.playing do
		local curve = pb.clip.rootMotion
		if not curve or pb.fading then
			continue
		end

		local t = math.min(pb.t, pb.clip.duration)
		local previous = pb.rootAt or 0
		if t <= previous then
			continue
		end

		-- `sampleTrack` returns a keyframe's three channels as three numbers.
		-- For a track masquerading as root motion they are read as a
		-- translation rather than as swing, spread and twist.
		local nx, ny, nz = sampleTrack(curve, t, pb.ease)
		local px, py, pz = sampleTrack(curve, previous, pb.ease)
		pb.rootAt = t

		local delta = Vector3.new(nx - px, ny - py, nz - pz)
		if delta.Magnitude > 1e-4 then
			-- In the character's own space: a roll goes backwards relative to
			-- where the character faces, not relative to the world.
			root.CFrame = root.CFrame * CFrame.new(delta * (pb.gain or 1))
		end
	end
end

function Animator:setAdditive(joint: string, swing: number?, spread: number?, twist: number?)
	self.additive[joint] = { swing = swing or 0, spread = spread or 0, twist = twist or 0 }
end

function Animator:clearAdditive()
	table.clear(self.additive)
end

function Animator:_fireMarker(pb, markerName: string)
	if pb.onMarker then
		task.spawn(pb.onMarker, markerName, pb)
	end
	for _, fn in self._markerHandlers do
		task.spawn(fn, pb.name, markerName, pb)
	end
end

function Animator:_locomotion(dt: number, target)
	local hum = self.humanoid
	local root = self.root
	if not (hum and root and root.Parent) then
		return
	end
	local p = self.profile

	local vel = (root :: BasePart).AssemblyLinearVelocity
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local state = hum:GetState()
	local airborne = state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping

	if airborne then
		local a = p.airborne
		target.rightArm = { swing = a.arms.swing, spread = a.arms.spread, twist = 0 }
		target.leftArm = { swing = a.arms.swing, spread = -a.arms.spread, twist = 0 }
		target.rightLeg = { swing = a.legs.swing[1], spread = a.legs.spread, twist = 0 }
		target.leftLeg = { swing = a.legs.swing[2], spread = -a.legs.spread, twist = 0 }
		target.torso = { swing = a.torso, spread = 0, twist = 0 }
		return
	end

	if speed < 0.6 then
		-- Idle is never still. A perfectly static character reads as broken,
		-- and this costs one sine.
		self.phase += dt * p.idleRate
		local b = math.sin(self.phase) * p.idleAmount
		target.rightArm = { swing = b * 0.5 - 3, spread = 5 + b * 0.3, twist = 0 }
		target.leftArm = { swing = -b * 0.5 - 3, spread = -5 - b * 0.3, twist = 0 }
		target.rightLeg = { swing = 0, spread = 1, twist = 0 }
		target.leftLeg = { swing = 0, spread = -1, twist = 0 }
		target.torso = { swing = b * 0.4, spread = 0, twist = 0 }
		target.head = { swing = -b * 0.5, spread = 0, twist = math.sin(self.phase * 0.4) * 4 }
		return
	end

	local cadence = math.clamp(speed * p.cadenceScale, p.cadenceRange[1], p.cadenceRange[2])
	self.phase += dt * cadence * p.cadence
	local s = math.sin(self.phase)
	local amp = math.clamp(speed * p.amplitudeScale, p.amplitudeRange[1], p.amplitudeRange[2])
	local lean = math.clamp(speed * p.lean, 0, p.leanMax)

	target.rightArm = { swing = -s * amp * p.armAmplitude, spread = 6, twist = 0 }
	target.leftArm = { swing = s * amp * p.armAmplitude, spread = -6, twist = 0 }
	target.rightLeg = { swing = s * amp * p.legAmplitude, spread = 1, twist = 0 }
	target.leftLeg = { swing = -s * amp * p.legAmplitude, spread = -1, twist = 0 }
	target.torso = { swing = lean * 0.35, spread = 0, twist = -s * amp * 0.12 }
	target.head = { swing = -lean * 0.25, spread = 0, twist = 0 }
end

function Animator:update(dt: number)
	if not self.enabled or not self.character.Parent then
		return
	end

	local target = {}
	for _, key in Anim.JOINTS do
		target[key] = { swing = 0, spread = 0, twist = 0 }
	end

	if self.locomotion then
		self:_locomotion(dt, target)
	end

	-- lowest priority first, so a higher clip writes last and wins
	local order = {}
	for name in self.playing do
		table.insert(order, name)
	end
	table.sort(order, function(a, b)
		return (clips[a].priority or 1) < (clips[b].priority or 1)
	end)

	for _, name in order do
		local pb = self.playing[name]
		if not pb then
			continue
		end
		local clip = pb.clip
		local prevT = pb.t
		pb.t += dt * pb.speed

		for _, mk in clip.markers do
			if not pb.fired[mk.name] and prevT < mk.t and pb.t >= mk.t then
				pb.fired[mk.name] = true
				self:_fireMarker(pb, mk.name)
			end
		end

		if pb.t >= clip.duration then
			if clip.loop then
				pb.t = pb.t % clip.duration
				table.clear(pb.fired)
			elseif clip.hold then
				pb.t = clip.duration
			else
				pb.fading = true
			end
		end

		if pb.fading then
			pb.weight -= dt / pb.blendOut
			if pb.weight <= 0 then
				self.playing[name] = nil
				continue
			end
		else
			pb.weight = math.min(1, pb.weight + dt / pb.blendIn)
		end

		local w = math.clamp(pb.weight, 0, 1) * (pb.gain or 1)
		local t = math.min(pb.t, clip.duration)
		for _, key in clip.mask do
			local track = clip.tracks[key]
			if track then
				local sw, sp, tw = sampleTrack(track, t, pb.ease)
				local cur = target[key]
				cur.swing += (sw - cur.swing) * w
				cur.spread += (sp - cur.spread) * w
				cur.twist += (tw - cur.twist) * w
			end
		end
	end

	self:_rootMotion(dt)

	for key, add in self.additive do
		local cur = target[key]
		if cur then
			cur.swing += add.swing
			cur.spread += add.spread
			cur.twist += add.twist
		end
	end

	-- Smoothed write. Without this, the frame a clip is cancelled shows a pop.
	local blend = 1 - math.exp(-self.smoothing * dt)
	for key, joint in self.joints do
		local want = target[key]
		if not want then
			continue
		end
		local cur = self.applied[key]
		cur.swing += (want.swing - cur.swing) * blend
		cur.spread += (want.spread - cur.spread) * blend
		cur.twist += (want.twist - cur.twist) * blend

		local def = joint.def
		local axes = { 0, 0, 0 }
		axes[def.swing[1]] += math.rad(cur.swing) * def.swing[2]
		axes[def.spread[1]] += math.rad(cur.spread) * def.spread[2]
		axes[def.twist[1]] += math.rad(cur.twist) * def.twist[2]

		local rotation = CFrame.Angles(axes[1], axes[2], axes[3])
		if joint.kind == "Motor6D" then
			(joint.motor :: Motor6D).C0 = joint.base * rotation
		else
			(joint.motor :: AnimationConstraint).Transform = joint.base * rotation
		end
	end
end

function Animator:reset()
	for _, joint in self.joints do
		if joint.kind == "Motor6D" then
			(joint.motor :: Motor6D).C0 = joint.base
		else
			(joint.motor :: AnimationConstraint).Transform = joint.base
		end
	end
	for _, v in self.applied do
		v.swing, v.spread, v.twist = 0, 0, 0
	end
end

function Animator:destroy()
	self.enabled = false
	if self._conn then
		self._conn:Disconnect()
	end
	table.clear(self.playing)
	table.clear(self._markerHandlers)
end

-- What the validation half reads to prove a character is animating at all.
function Animator:describe(): { [string]: any }
	local active = {}
	for name, pb in self.playing do
		active[name] = { t = pb.t, weight = pb.weight, fading = pb.fading }
	end
	local jointNames = {}
	for key in self.joints do
		table.insert(jointNames, key)
	end
	table.sort(jointNames)
	return {
		rig = self.rigType,
		joints = jointNames,
		-- Which joint system this character actually uses. Worth reporting:
		-- an animator with zero of both is a character that cannot move, and
		-- that failure is otherwise completely silent.
		jointKinds = self.jointKinds,
		playing = active,
		layers = (function()
			local seen: { [string]: number } = {}
			for _, pb in self.playing do
				local layer = pb.layer or "base"
				seen[layer] = (seen[layer] or 0) + 1
			end
			return seen
		end)(),
		locomotion = self.locomotion,
		rootMotion = self.rootMotion,
		phase = self.phase,
	}
end

-- Binds the animator to the right loop for the current context and keeps the
-- connection on the animator so :destroy() releases it.
--[[
	Drive an animator on the right loop for its context.

	RenderStepped on a client so the pose is computed for the frame being
	drawn; Heartbeat on the server, where there is no frame to be early for.

	This is only safe because `Rig.stripDefaultAnimate` has removed Roblox's
	own animator first. While that is still present it rewrites the same joints
	every frame and no render priority is late enough to beat it -- that was
	measured, not assumed.
]]
function Anim.bind(animator: any, phase: string?): RBXScriptConnection
	local signal
	if phase == "heartbeat" or RunService:IsServer() then
		signal = RunService.Heartbeat
	else
		signal = RunService.RenderStepped
	end
	local conn = signal:Connect(function(dt)
		animator:update(math.min(dt, 0.1))
	end)
	animator._conn = conn
	return conn
end

-- Weapon trails are the most common thing markers drive, so it ships here.
function Anim.setTrail(character: Model, enabled: boolean, partName: string?)
	local holder = character:FindFirstChild(partName or "Weapon")
	if not holder then
		return
	end
	for _, d in holder:GetDescendants() do
		if d:IsA("Trail") then
			d.Enabled = enabled
		end
	end
	local direct = holder:FindFirstChildOfClass("Trail")
	if direct then
		direct.Enabled = enabled
	end
end

-- Module-level description: which clips are registered and whether each one
-- carries markers. A clip with no markers is a pose with no timing.
function Anim.describe(): { [string]: any }
	local registered = {}
	for name, clip in clips do
		registered[name] = {
			duration = clip.duration,
			markers = #clip.markers,
			priority = clip.priority,
			loop = clip.loop == true,
		}
	end
	return { clips = registered, rigTypes = { "R6", "R15" } }
end

return Anim
