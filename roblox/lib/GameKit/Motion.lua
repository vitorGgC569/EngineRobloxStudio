--!strict
--- Procedural animation: the difference between a prop and a creature.
---
--- There was no animation in this engine at all. Not a thin layer -- zero:
--- no `Animator`, no `Motor6D`, no `AnimationTrack`. `Pursuit` gave creatures
--- somewhere to go and they slid there rigid, which is the loudest amateur tell
--- a Roblox game can have. A player forgives low-poly. Nobody forgives a
--- monster that glides.
---
--- **Why procedural rather than authored clips.** A Roblox `Animation` needs an
--- uploaded asset id, which needs a real account, an upload and moderation --
--- and the whole point of the runtime mesh path is that this factory builds
--- without any of that. Authored clips also need a rig, and `WorldKit.Threat`
--- builds loose parts under a Model, not a skeleton.
---
--- So motion here is a function of time applied to part offsets. Each part
--- remembers where it was placed, and every frame it is put back there plus a
--- displacement. Nothing is destroyed, nothing is uploaded, and stopping puts
--- everything exactly where it started.
---
--- **What this buys, concretely.** A `menace` gait gives the pilgrim a slow
--- shoulder roll and a head that leads the turn. A `walk` gait swings whatever
--- limbs it can find in opposition and bobs the body on the double frequency,
--- because that is what walking is. Neither needs a bone.
---
--- **What it does not do.** It cannot bend a mesh. A single-MeshPart creature
--- can only be moved as a whole -- it will sway and lean, not stride. That is a
--- real limit and it is the reason `Blocked` sits next to the quadruped in the
--- parts manifest.

local RunService = game:GetService("RunService")

local Motion = {}

export type Gait = "idle" | "walk" | "menace" | "hover" | "stagger"

export type Spec = {
	gait: Gait,
	--- Cycles per second. A walk near 1.6 reads natural; a menace wants 0.5.
	rate: number?,
	--- Overall displacement multiplier. 1 is calibrated, 2 is comic.
	intensity: number?,
	--- Hold this many studs above where the model was placed. Hover only.
	lift: number?,
}

type Piece = {
	part: BasePart,
	--- Where the part sits relative to the model's pivot, captured once. Every
	--- frame writes pivot * home * displacement, so drift cannot accumulate --
	--- which it does immediately if you offset from the current position.
	home: CFrame,
	--- -1, 0 or 1: which side of the body, used to put limbs in opposition.
	side: number,
	--- 0 at the feet, 1 at the crown. Sway scales with this so a head moves
	--- more than a base, which is what makes the motion read as a body.
	elevation: number,
	--- Guessed from name and shape: "limb", "head", "body".
	kind: string,
}

type Performer = {
	model: Model,
	--- The part that defines the frame of reference, never displaced itself.
	anchor: BasePart,
	pieces: { Piece },
	spec: Spec,
	phase: number,
	stopped: boolean,
	origin: CFrame,
}

local active: { [Model]: Performer } = {}
local heartbeat: RBXScriptConnection? = nil

--- The part everything else hangs off, and which motion must never move.
---
--- The first version animated every part including the model's PrimaryPart --
--- which *is* the pivot. So each frame displaced the frame of reference that
--- the next frame measured from, and the creature walked away from itself.
--- Measured: after twenty ticks of `menace` and a stop, parts sat 3.47 studs
--- from where they were placed, when the promise was zero.
---
--- So one part is the anchor. It stays put, and `Pursuit` is free to drive it
--- without the two fighting: motion is expressed entirely as offsets from
--- wherever the anchor currently is.
local function anchorOf(model: Model): BasePart?
	if model.PrimaryPart ~= nil then
		return model.PrimaryPart
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root
	end
	-- Largest part: the torso of anything shaped like a body.
	local best, bestVolume = nil, -1
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			local volume = item.Size.X * item.Size.Y * item.Size.Z
			if volume > bestVolume then
				best, bestVolume = item, volume
			end
		end
	end
	return best
end

--- Read a model's parts into something animatable, without a rig.
---
--- The classification is deliberately crude -- names and proportions, nothing
--- more. It is wrong sometimes, and being wrong costs a limb swinging like a
--- torso, which reads as a stylistic choice. Requiring a real rig would cost
--- the entire feature.
local function readRig(model: Model, anchor: BasePart): { Piece }
	local pivot = anchor.CFrame
	local _, size = model:GetBoundingBox()
	local floor = pivot.Position.Y - size.Y * 0.5
	local span = math.max(size.Y, 1)

	local pieces: { Piece } = {}
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") and item ~= anchor then
			local relative = pivot:ToObjectSpace(item.CFrame)
			local name = string.lower(item.Name)

			local kind = "body"
			if string.find(name, "arm") or string.find(name, "leg")
				or string.find(name, "limb") or string.find(name, "hand")
				or string.find(name, "foot") then
				kind = "limb"
			elseif string.find(name, "head") or string.find(name, "cowl")
				or string.find(name, "skull") then
				kind = "head"
			elseif item.Size.Y > item.Size.X * 2.2 and item.Size.Y > item.Size.Z * 2.2
				and item.Size.Y < size.Y * 0.6 then
				-- Tall, thin, and not the whole body: limb-shaped even if it is
				-- named `Part17`, which is what generated geometry is called.
				kind = "limb"
			end

			table.insert(pieces, {
				part = item,
				home = relative,
				side = if relative.Position.X > 0.15 then 1
					elseif relative.Position.X < -0.15 then -1
					else 0,
				elevation = math.clamp((item.Position.Y - floor) / span, 0, 1),
				kind = kind,
			})
		end
	end
	return pieces
end

--- The displacement for one piece at one moment.
---
--- Every gait is a small pile of sines. That sounds cheap and it is -- but a
--- body is a pendulum system, and sines are what pendulums do.
local function displace(piece: Piece, spec: Spec, phase: number): CFrame
	local gait = spec.gait
	local strength = spec.intensity or 1
	local swing = phase * math.pi * 2

	if gait == "walk" then
		-- Limbs oppose across the body; the torso bobs at twice the stride
		-- frequency, because a body rises once per step and there are two steps
		-- to a cycle.
		if piece.kind == "limb" then
			local lead = if piece.side >= 0 then swing else swing + math.pi
			return CFrame.Angles(math.sin(lead) * 0.55 * strength, 0, 0)
		end
		local bob = math.sin(swing * 2) * 0.16 * strength
		local roll = math.sin(swing) * 0.045 * strength * piece.elevation
		return CFrame.new(0, bob, 0) * CFrame.Angles(0, 0, roll)
	end

	if gait == "menace" then
		-- Slow, heavy, and led from the shoulders. The head lags the body by a
		-- quarter cycle, which is what makes a walk look like it is deciding
		-- something.
		local lag = if piece.kind == "head" then swing - math.pi * 0.5 else swing
		local sway = math.sin(lag) * 0.09 * strength * (0.35 + piece.elevation)
		local lean = math.cos(swing) * 0.05 * strength * piece.elevation
		return CFrame.new(math.sin(lag) * 0.25 * strength * piece.elevation, 0, 0)
			* CFrame.Angles(lean, sway * 0.6, sway)
	end

	if gait == "hover" then
		local rise = math.sin(swing) * 0.5 * strength + (spec.lift or 0)
		local drift = math.sin(swing * 0.6) * 0.08 * strength
		return CFrame.new(0, rise, 0) * CFrame.Angles(0, drift, drift * 0.5)
	end

	if gait == "stagger" then
		-- Deliberately irregular: two frequencies that do not divide, so the
		-- loop never resolves and the thing reads as hurt rather than rhythmic.
		local jolt = math.sin(swing * 1.7) * math.sin(swing * 0.43)
		return CFrame.new(jolt * 0.4 * strength * piece.elevation, 0, 0)
			* CFrame.Angles(0, 0, jolt * 0.14 * strength)
	end

	-- idle: breathing. Small enough to be deniable, large enough that its
	-- absence reads as a statue.
	local breath = math.sin(swing) * 0.05 * strength
	return CFrame.new(0, breath * 0.6, 0)
		* CFrame.Angles(0, 0, breath * 0.25 * piece.elevation)
end

local function tick(performer: Performer, delta: number)
	performer.phase += delta * (performer.spec.rate or 1.2)
	-- Read from the anchor, which motion never writes to. Reading the model's
	-- pivot instead makes the reference frame a function of the animation.
	local pivot = performer.anchor.CFrame
	for _, piece in ipairs(performer.pieces) do
		if piece.part.Parent ~= nil then
			-- Rebuilt from the pivot every frame. Offsetting from the part's
			-- current CFrame instead lets floating-point error accumulate, and
			-- a creature slowly corkscrews into the floor over a minute.
			piece.part.CFrame = pivot * piece.home
				* displace(piece, performer.spec, performer.phase)
		end
	end
end

local function ensureHeartbeat()
	if heartbeat ~= nil then
		return
	end
	heartbeat = RunService.Heartbeat:Connect(function(delta)
		for model, performer in pairs(active) do
			if performer.stopped or model.Parent == nil then
				active[model] = nil
			else
				local ok, err = pcall(tick, performer, delta)
				if not ok then
					warn("[Motion] " .. model.Name .. ": " .. tostring(err))
					active[model] = nil
				end
			end
		end
		if next(active) == nil and heartbeat ~= nil then
			heartbeat:Disconnect()
			heartbeat = nil
		end
	end)
end

local GAITS = { idle = true, walk = true, menace = true, hover = true, stagger = true }

function Motion.gaits(): { string }
	local names = {}
	for name in pairs(GAITS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- Animate a model. Returns nil and a reason when it cannot.
function Motion.play(model: Model, spec: Spec): (Performer?, string?)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil, "motion needs a Model"
	end
	if not GAITS[spec.gait] then
		return nil, ("no gait %q; have %s"):format(
			tostring(spec.gait), table.concat(Motion.gaits(), ", "))
	end

	Motion.stop(model)

	local anchor = anchorOf(model)
	if anchor == nil then
		return nil, model.Name .. " has no BaseParts to move"
	end
	local pieces = readRig(model, anchor)
	if #pieces == 0 then
		return nil, model.Name .. " has only one part, so there is nothing to move "
			.. "relative to it -- a single-mesh creature can be carried but not animated"
	end

	local performer: Performer = {
		model = model,
		anchor = anchor,
		pieces = pieces,
		spec = spec,
		-- Staggered by name, so twenty pilgrims do not breathe in unison --
		-- which reads as a machine, not a crowd.
		phase = (#model.Name % 7) / 7,
		stopped = false,
		origin = anchor.CFrame,
	}
	active[model] = performer
	model:SetAttribute("MotionGait", spec.gait)
	ensureHeartbeat()
	return performer, nil
end

--- Stop, and put every part back exactly where it was placed.
function Motion.stop(model: Model)
	local performer = active[model]
	if performer ~= nil then
		performer.stopped = true
		local pivot = performer.anchor.CFrame
		for _, piece in ipairs(performer.pieces) do
			if piece.part.Parent ~= nil then
				pcall(function()
					piece.part.CFrame = pivot * piece.home
				end)
			end
		end
		active[model] = nil
	end
	if typeof(model) == "Instance" then
		model:SetAttribute("MotionGait", nil)
	end
end

function Motion.stopAll()
	for model in pairs(active) do
		Motion.stop(model)
	end
end

function Motion.report(): { [string]: any }
	local gaits: { [string]: number } = {}
	local count, parts = 0, 0
	for _, performer in pairs(active) do
		count += 1
		parts += #performer.pieces
		gaits[performer.spec.gait] = (gaits[performer.spec.gait] or 0) + 1
	end
	return { performers = count, parts = parts, gaits = gaits }
end

return Motion
