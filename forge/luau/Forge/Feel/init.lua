--!strict
--[[
	Feel — impact, weight and reaction.

	This is the module that decides whether a game reads as professional. Two
	games with identical mechanics, one with hitstop and screen shake and
	damage numbers that arc, one without — players will describe the first as
	"polished" and the second as "unfinished", and neither will be able to say
	why.

	It is also the layer agents skip, because nothing breaks without it. So it
	ships here, in the engine, as one call per effect.

		Feel.mount()                              -- once, on the client
		Feel.shake(0.6)                           -- trauma, 0..1
		Feel.hitstop(0.08)                        -- the pause that sells a hit
		Feel.number(pos, "142", { crit = true })
		Feel.impact(pos, { color = c, kind = "burst" })
		Feel.flash(model, Color3.new(1,1,1), 0.1)
		Feel.knockback(model, direction, 40)

	Camera shake here is trauma-based and noise-driven, not random jitter.
	Trauma decays, and offset scales with trauma squared, so small hits barely
	register and big ones hit hard — the difference between shake that feels
	like impact and shake that feels like a loose cable.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Ease = require(script.Parent.Core.Ease)
local Spring = require(script.Parent.Core.Spring)

local Access = require(script.Parent.Access)

local Feel = {}

local IS_CLIENT = RunService:IsClient()

-- ============================== camera shake ================================
local trauma = 0
local traumaDecay = 1.6
local shakeSeed = os.clock() * 1000
local mounted = false

local zoomSpring = Spring.new(0, { frequency = 5, damping = 0.55 })
local pausedAnimators: { any } = {}
local hitstopUntil = 0

Feel.config = {
	maxAngle = math.rad(4.5), -- rotational shake at full trauma
	maxOffset = 1.6, -- positional shake at full trauma, in studs
	shakeFrequency = 22,
	numberRise = 6.5,
	numberLifetime = 1.0,
	numberDrift = 2.2,
}

-- Adds trauma rather than setting it, so three hits in a frame compound.
function Feel.shake(amount: number, decay: number?)
	--[[
		Scaled by the player's motion setting.

		This module is deliberately aggressive — shake, tint, hitstop — and all
		three are common causes of motion sickness. `Access.motionScale`
		returns 1 for everyone who has not asked otherwise, so the ordinary
		path is unchanged and the person who needs it gets a quarter of it
		without the game having to know they exist.
	]]
	trauma = math.clamp(trauma + amount * Access.motionScale(), 0, 1)
	if decay then
		traumaDecay = decay
	end
end

function Feel.trauma(): number
	return trauma
end

-- A short pause on impact. Registered animators freeze; everything else keeps
-- running, which is what makes it read as weight rather than as lag.
function Feel.hitstop(seconds: number)
	hitstopUntil = math.max(hitstopUntil, os.clock() + seconds)
end

function Feel.isPaused(): boolean
	return os.clock() < hitstopUntil
end

function Feel.registerAnimator(animator: any)
	table.insert(pausedAnimators, animator)
	return function()
		local i = table.find(pausedAnimators, animator)
		if i then
			table.remove(pausedAnimators, i)
		end
	end
end

-- FOV punch: small, fast, and the cheapest way to sell a heavy hit.
function Feel.punch(amount: number)
	zoomSpring:impulse(amount)
end

--[[
	Installs the per-frame driver. Call once from a client script.

	It writes to `camera.CFrame` after the default camera script has run, so it
	composes with whatever camera mode the game uses instead of fighting it.
]]
function Feel.mount()
	if mounted or not IS_CLIENT then
		return
	end
	mounted = true

	local camera = Workspace.CurrentCamera
	local baseFov = camera and camera.FieldOfView or 70

	RunService:BindToRenderStep("ForgeFeel", Enum.RenderPriority.Camera.Value + 1, function(dt)
		camera = Workspace.CurrentCamera
		if not camera then
			return
		end

		-- hitstop freezes registered animators without stopping the world
		local paused = Feel.isPaused()
		for _, animator in pausedAnimators do
			animator.enabled = not paused
		end

		trauma = math.max(0, trauma - traumaDecay * dt)
		if trauma > 0 then
			local t = os.clock() * Feel.config.shakeFrequency
			local power = trauma * trauma -- the important line
			local nx = math.noise(t, shakeSeed, 0)
			local ny = math.noise(t, shakeSeed, 100)
			local nz = math.noise(t, shakeSeed, 200)

			camera.CFrame = camera.CFrame
				* CFrame.new(nx * Feel.config.maxOffset * power, ny * Feel.config.maxOffset * power, 0)
				* CFrame.Angles(
					ny * Feel.config.maxAngle * power,
					nx * Feel.config.maxAngle * power,
					nz * Feel.config.maxAngle * power
				)
		end

		zoomSpring:step(dt)
		camera.FieldOfView = baseFov + zoomSpring.value
	end)
end

function Feel.unmount()
	if not mounted then
		return
	end
	mounted = false
	RunService:UnbindFromRenderStep("ForgeFeel")
end

-- ============================= damage numbers ===============================
local numberGui: BillboardGui? = nil

--[[
	A number that rises, drifts sideways and fades. The sideways drift is what
	stops a burst of hits from stacking into an unreadable column — it is a
	two-line detail that decides whether the player can read their own DPS.
]]
function Feel.number(position: Vector3, text: string, options: any?)
	if not IS_CLIENT then
		return
	end
	local opts = options or {}
	local color = opts.color or (opts.crit and Color3.fromRGB(255, 206, 96) or Color3.fromRGB(248, 244, 236))
	local size = opts.crit and 34 or 24
	local lifetime = opts.lifetime or Feel.config.numberLifetime

	local anchor = Instance.new("Part")
	anchor.Size = Vector3.one * 0.1
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(160, 60)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = opts.maxDistance or 140
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.25
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextSize = size
	label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
	label.Parent = billboard

	local drift = (math.random() - 0.5) * 2 * Feel.config.numberDrift
	local rise = Feel.config.numberRise * (opts.crit and 1.4 or 1)
	local start = os.clock()

	-- crits pop in with overshoot; normal hits just appear
	if opts.crit then
		label.TextTransparency = 0
		label.TextSize = size * 0.4
		TweenService:Create(label, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			TextSize = size,
		}):Play()
	end

	local conn
	conn = RunService.RenderStepped:Connect(function()
		local alpha = (os.clock() - start) / lifetime
		if alpha >= 1 or not anchor.Parent then
			conn:Disconnect()
			anchor:Destroy()
			return
		end
		anchor.CFrame = CFrame.new(position + Vector3.new(drift * alpha, Ease.apply("outCubic", alpha) * rise, 0))
		label.TextTransparency = alpha < 0.6 and 0 or (alpha - 0.6) / 0.4
		label.TextStrokeTransparency = 0.25 + (label.TextTransparency * 0.75)
	end)
end

-- ================================ impacts ===================================
local function emitterPart(position: Vector3, lifetime: number): BasePart
	local p = Instance.new("Part")
	p.Size = Vector3.one * 0.1
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CFrame = CFrame.new(position)
	p.Parent = Workspace
	Debris:AddItem(p, lifetime)
	return p
end

--[[
	kind:
	  "burst"  omnidirectional spark — generic hit
	  "spray"  directional, needs options.direction — slashes, bullet impacts
	  "ring"   expanding disc — slams, shockwaves, spawns
	  "puff"   slow soft cloud — dust, landings, footfalls
]]
function Feel.impact(position: Vector3, options: any?)
	local opts = options or {}
	local kind = opts.kind or "burst"
	local color = opts.color or Color3.fromRGB(255, 220, 160)
	local scale = opts.scale or 1

	if kind == "ring" then
		local ring = Instance.new("Part")
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(0.4, 1, 1) * scale
		ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.Material = Enum.Material.Neon
		ring.Color = color
		ring.Transparency = 0.15
		ring.Parent = Workspace
		Debris:AddItem(ring, 0.6)
		TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.4, 26 * scale, 26 * scale),
			Transparency = 1,
		}):Play()
		return
	end

	local part = emitterPart(position, 1.2)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.8
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.Parent = part

	if kind == "spray" then
		local dir = opts.direction or Vector3.new(0, 1, 0)
		part.CFrame = CFrame.lookAt(position, position + dir)
		emitter.EmissionDirection = Enum.NormalId.Front
		emitter.SpreadAngle = Vector2.new(22, 22)
		emitter.Speed = NumberRange.new(18 * scale, 34 * scale)
		emitter.Lifetime = NumberRange.new(0.2, 0.4)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6 * scale),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter:Emit(math.floor(18 * scale))
	elseif kind == "puff" then
		emitter.Speed = NumberRange.new(2 * scale, 6 * scale)
		emitter.Lifetime = NumberRange.new(0.6, 1.1)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.LightEmission = 0.1
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1.2 * scale),
			NumberSequenceKeypoint.new(1, 3.5 * scale),
		})
		emitter:Emit(math.floor(14 * scale))
	else
		emitter.Speed = NumberRange.new(10 * scale, 26 * scale)
		emitter.Lifetime = NumberRange.new(0.18, 0.42)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.7 * scale),
			NumberSequenceKeypoint.new(1, 0),
		})
		emitter:Emit(math.floor(20 * scale))
	end

	if opts.light ~= false then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 18 * scale
		light.Brightness = 3
		light.Parent = part
		TweenService:Create(light, TweenInfo.new(0.3), { Brightness = 0 }):Play()
	end
end

-- ============================= character feedback ===========================
-- White flash on hit. Restores the original colours, so it is safe to stack.
function Feel.flash(model: Model, color: Color3?, duration: number?)
	local flashColor = color or Color3.new(1, 1, 1)
	local time = duration or 0.12
	local originals: { [BasePart]: Color3 } = {}

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Transparency < 1 then
			originals[d] = d.Color
			d.Color = flashColor
		end
	end

	task.delay(time, function()
		for part, original in originals do
			if part.Parent then
				part.Color = original
			end
		end
	end)
end

-- Impulse-based knockback that respects mass, so a golem shrugs off what
-- staggers a rat without any per-enemy special case.
function Feel.knockback(model: Model, direction: Vector3, force: number, upward: number?)
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not root or not root:IsA("BasePart") then
		return
	end
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	local impulse = flat.Unit * force + Vector3.new(0, upward or force * 0.25, 0)
	root:ApplyImpulse(impulse * root.AssemblyMass)
end

-- A brief full-screen tint. Damage taken, healing, level up.
function Feel.screenTint(color: Color3, intensity: number, duration: number?)
	if not IS_CLIENT then
		return
	end
	local player = Players.LocalPlayer
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then
		return
	end

	local screen = Instance.new("ScreenGui")
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 1000
	screen.Parent = gui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 1 - intensity
	frame.BorderSizePixel = 0
	frame.Parent = screen

	local tween = TweenService:Create(frame, TweenInfo.new(duration or 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	})
	tween.Completed:Connect(function()
		screen:Destroy()
	end)
	tween:Play()
end

-- ================================== breath ==================================
--[[
	Visible breath from a character's mouth.

	Exhaustion is a state the player is *in*, and a bar going empty in the
	corner of the screen does not communicate it — the character has to show it.
	One puff per breath, in bursts, because a continuous stream reads as smoke
	rather than as breathing.

		Feel.breath(character)                      -- one puff
		Feel.breathing(character, true)             -- keep panting until told to stop

	The emitter is created once per character and reused: making and destroying
	a ParticleEmitter twice a second is exactly the allocation pattern the rest
	of this module exists to avoid.
]]
local breathing: { [Model]: any } = {}

local function breathEmitter(character: Model): ParticleEmitter?
	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return nil
	end

	local existing = head:FindFirstChild("ForgeBreath")
	if existing then
		return existing:FindFirstChildOfClass("ParticleEmitter")
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "ForgeBreath"
	-- Mouth height and slightly forward. On both R6 and R15 the head's front
	-- is -Z, so this sits where a mouth would be rather than inside the skull.
	attachment.Position = Vector3.new(0, -0.15, -0.65)
	attachment.Parent = head

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Breath"
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.55, 0.95)
	emitter.Speed = NumberRange.new(2.5, 5)
	emitter.SpreadAngle = Vector2.new(9, 9)
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Acceleration = Vector3.new(0, 1.6, 0)
	emitter.LightEmission = 0.15
	emitter.LightInfluence = 1
	emitter.Color = ColorSequence.new(Color3.fromRGB(232, 240, 248))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.18),
		NumberSequenceKeypoint.new(0.45, 0.7),
		NumberSequenceKeypoint.new(1, 1.25),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(0.35, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Parent = attachment
	return emitter
end

function Feel.breath(character: Model, options: any?)
	local emitter = breathEmitter(character)
	if not emitter then
		return
	end
	local opts = options or {}
	emitter:Emit(opts.count or 5)
end

--[[
	Keep breathing until stopped.

	Interval jitters slightly: a puff on an exact metronome reads as a machine.
	Real panting slows as it recovers, which the caller can drive by changing
	`interval` on the fly.
]]
function Feel.breathing(character: Model, on: boolean, options: any?)
	if not on then
		local entry = breathing[character]
		if entry then
			entry.stopped = true
			breathing[character] = nil
		end
		return
	end
	if breathing[character] then
		breathing[character].options = options or breathing[character].options
		return
	end

	local entry = { stopped = false, options = options or {} }
	breathing[character] = entry

	task.spawn(function()
		while not entry.stopped and character.Parent do
			Feel.breath(character, entry.options)
			local interval = (entry.options.interval or 0.85) * (0.85 + math.random() * 0.3)
			task.wait(interval)
		end
	end)
end

function Feel.isBreathing(character: Model): boolean
	return breathing[character] ~= nil
end

-- One call for the common case: something got hit here, sell it.
-- Keeps the four things that always go together from drifting apart.
function Feel.hit(position: Vector3, options: any?)
	local opts = options or {}
	local power = opts.power or 1

	Feel.impact(position, {
		kind = opts.kind or "burst",
		color = opts.color,
		direction = opts.direction,
		scale = power,
	})
	if IS_CLIENT then
		Feel.shake(0.22 * power)
		Feel.hitstop(math.min(0.02 + 0.05 * power, 0.12))
		if opts.crit then
			Feel.punch(2.5)
		end
	end
	if opts.model then
		Feel.flash(opts.model, opts.flashColor, 0.1)
	end
	if opts.model and opts.direction and opts.knockback then
		Feel.knockback(opts.model, opts.direction, opts.knockback)
	end
end

return Feel
