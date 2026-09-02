--!strict
-- Client combat input + immediate cosmetic feedback. The server is the only
-- authority on damage; everything here is input capture and visuals.
--   Survivor / hidden PZ blending in: hold LMB to fire, RMB to aim, R reload, Shift sprint
--   Patient Zero: F (or LMB with knife out, mobile button) throws the knife
--   Zombie / PZ: LMB near a survivor = melee
--
-- Aiming is centre-screen (the mouse is locked by CameraController), and the shot is
-- corrected for the over-the-shoulder camera offset so hugging a corner doesn't send
-- rounds into the wall you are peeking past.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)
local Keybinds = require(Shared.Keybinds)
local Ballistics = require(Shared.Ballistics)

local CameraController = require(script.Parent.CameraController)

local LocalPlayer = Players.LocalPlayer

local CombatController = {}

local state = {
	role = "NONE" :: string,
	primary = "AssaultRifle" :: string,
	sprinting = false,
	firing = false,
	shotsInBurst = 0,
	nextShotAt = 0,
}

-- Semi-automatic weapons still want one shot per click; everything else is hold-to-fire.
local SEMI_AUTO = { Shotgun = true, Pistol = true }

local function currentSpread(): number
	local stance = CameraController.stance()
	return Ballistics.spread(state.primary, {
		shotsInBurst = state.shotsInBurst,
		ads = stance.ads,
		moving = stance.moving,
		sprinting = stance.sprinting,
		airborne = stance.airborne,
	})
end

-- Muzzle origin plus the direction that actually reaches what the crosshair covers.
--
-- The camera sits off the shoulder, so "camera forward" and "gun forward" are not the same
-- ray. We resolve what the crosshair is over first, then aim the muzzle at that point.
local function myOriginAndDirection(): (Vector3?, Vector3?)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil, nil
	end
	local camera = workspace.CurrentCamera
	if camera == nil then
		return nil, nil
	end

	local origin = root.Position + Vector3.new(0, 1.5, 0)

	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
	local aimPoint = hit and hit.Position or (ray.Origin + ray.Direction * 2000)

	local toAim = aimPoint - origin
	if toAim.Magnitude < 1e-3 then
		return origin, ray.Direction.Unit
	end
	return origin, toAim.Unit
end

-- Apply the current cone to a direction. The server rolls its own (it is the authority);
-- this keeps the tracer honest about the fact that the shot was not perfectly centred.
local function applySpread(direction: Vector3, spreadDeg: number, rng: Random): Vector3
	local offset = Ballistics.coneOffset(spreadDeg, rng:NextNumber(), rng:NextNumber())
	local up = if Ballistics.safeUpAxis(direction.Y) == "Z" then Vector3.zAxis else Vector3.yAxis
	local frame = CFrame.lookAt(Vector3.zero, direction, up)
	return (frame * CFrame.Angles(math.rad(offset.pitchDeg), math.rad(offset.yawDeg), 0)).LookVector
end

local function nearestSurvivorTarget(maxRange: number): number?
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	local best: Player? = nil
	local bestDist = maxRange
	for _, other in Players:GetPlayers() do
		if other ~= LocalPlayer and other.Character then
			local otherRoot = other.Character:FindFirstChild("HumanoidRootPart")
			if otherRoot and otherRoot:IsA("BasePart") then
				local d = (otherRoot.Position - root.Position).Magnitude
				if d < bestDist then
					best = other
					bestDist = d
				end
			end
		end
	end
	return best and best.UserId or nil
end

-- Impact feedback ------------------------------------------------------------------
-- Missing used to produce absolutely nothing on screen, which is why the gunfight read as
-- broken: you could not tell a miss from a hit on an enemy you could not see. Every shot
-- now terminates in something visible.
local liveImpacts = 0
local MAX_LIVE_IMPACTS = 40

local function impactFx(position: Vector3, normal: Vector3, hitCharacter: boolean)
	if liveImpacts >= MAX_LIVE_IMPACTS then
		return
	end
	liveImpacts += 1

	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.lookAt(position + normal * 0.05, position + normal)
	anchor.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	-- PATIENT ZERO GUARD: the FX for hitting a person is identical no matter who they are.
	-- Anything role-dependent here would turn this client-side raycast into a PZ scanner and
	-- undo the server's deliberate silence on survivor-on-survivor shots.
	emitter.Color =
		ColorSequence.new(hitCharacter and Color3.fromRGB(255, 235, 190) or Color3.fromRGB(190, 185, 175))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.15, 0.35)
	emitter.Speed = NumberRange.new(3, 9)
	emitter.SpreadAngle = Vector2.new(35, 35)
	emitter.Enabled = false
	emitter.Parent = anchor
	emitter:Emit(hitCharacter and 6 or 10)

	-- A short-lived scorch so you can read your own grouping on a wall.
	if not hitCharacter then
		local hole = Instance.new("Part")
		hole.Anchored = true
		hole.CanCollide = false
		hole.CanQuery = false
		hole.Material = Enum.Material.SmoothPlastic
		hole.Color = Color3.fromRGB(30, 28, 26)
		hole.Size = Vector3.new(0.28, 0.28, 0.02)
		hole.CFrame = CFrame.lookAt(position + normal * 0.02, position + normal)
		hole.Parent = workspace
		Debris:AddItem(hole, 4)
	end

	Debris:AddItem(anchor, 0.6)
	task.delay(0.6, function()
		liveImpacts -= 1
	end)
end

-- Cosmetic tracer so shots feel instant (server re-simulates the real hit). Drawn to where
-- the round actually stopped rather than a fixed length, so it reads as a bullet path.
local function drawTracer(origin: Vector3, direction: Vector3, range: number, ownShot: boolean)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { LocalPlayer.Character }
	local hit = workspace:Raycast(origin, direction * range, params)
	local endPoint = hit and hit.Position or (origin + direction * math.min(range, 400))

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 220, 120)
	local length = (endPoint - origin).Magnitude
	part.Size = Vector3.new(0.08, 0.08, length)
	part.CFrame = CFrame.lookAt(origin, endPoint) * CFrame.new(0, 0, -length / 2)
	part.Parent = workspace
	Debris:AddItem(part, 0.06)

	if ownShot and hit then
		local hitCharacter = hit.Instance:FindFirstAncestorOfClass("Model") ~= nil
			and hit.Instance.Parent ~= nil
			and hit.Instance.Parent:FindFirstChildOfClass("Humanoid") ~= nil
		impactFx(hit.Position, hit.Normal, hitCharacter)
	end
end

function CombatController.start(remotes: any)
	local actions = {}

	local rng = Random.new()

	function actions.fire()
		local origin, direction = myOriginAndDirection()
		if origin == nil or direction == nil then
			return
		end
		if state.role ~= "SURVIVOR" and state.role ~= "PATIENT_ZERO" then
			return
		end
		local spec = (GameConfig.Combat.Guns :: any)[state.primary]

		local spread = currentSpread()
		local shotDirection = applySpread(direction, spread, rng)
		state.shotsInBurst = math.min(state.shotsInBurst + 1, Ballistics.maxShots(state.primary))

		drawTracer(origin, shotDirection, spec.Range, true)
		-- The server rolls its own spread from the same model; we send the unspread aim so a
		-- client cannot hand-pick a zero-deviation direction.
		remotes.fire("FireWeapon", { origin = origin, direction = direction, weaponId = state.primary })
	end

	-- Held-trigger loop. Firing used to be bound to InputBegan only, so an 8-round-per-second
	-- rifle demanded eight clicks a second.
	RunService.Heartbeat:Connect(function(dt)
		state.shotsInBurst = Ballistics.decayShots(state.shotsInBurst, state.primary, dt)

		if not state.firing then
			return
		end
		if state.role ~= "SURVIVOR" and state.role ~= "PATIENT_ZERO" then
			return
		end
		if SEMI_AUTO[state.primary] then
			return
		end
		local spec = (GameConfig.Combat.Guns :: any)[state.primary]
		local now = os.clock()
		if now < state.nextShotAt then
			return
		end
		state.nextShotAt = now + 1 / spec.FireRate
		actions.fire()
	end)

	function actions.setFiring(on: boolean)
		state.firing = on
		if on then
			-- Fire the first round immediately; the loop paces the rest.
			local spec = (GameConfig.Combat.Guns :: any)[state.primary]
			local now = os.clock()
			if now >= state.nextShotAt then
				state.nextShotAt = now + 1 / spec.FireRate
				actions.fire()
			end
		end
	end

	function actions.setAds(on: boolean)
		-- No scope while sprinting or as a zombie.
		CameraController.setAds(on and state.role ~= "ZOMBIE" and not state.sprinting)
	end

	function actions.throwKnife()
		local origin, direction = myOriginAndDirection()
		if origin and direction and state.role == "PATIENT_ZERO" then
			remotes.fire("ThrowKnife", { origin = origin, direction = direction })
		end
	end

	function actions.melee()
		-- Swing-based: server finds the nearest survivor (player OR bot) in range.
		-- Also send the legacy targeted melee when a human target is right there.
		local origin, direction = myOriginAndDirection()
		if origin and direction then
			remotes.fire("MeleeSwing", { origin = origin, direction = direction })
		end
		local target = nearestSurvivorTarget(GameConfig.Combat.Zombie.MeleeRange)
		if target then
			remotes.fire("MeleeAttack", { targetUserId = target })
		end
	end

	function actions.reload()
		remotes.fire("Reload", { weaponId = state.primary })
	end

	function actions.setSprint(on: boolean)
		state.sprinting = on
		CameraController.setSprinting(on)
		if on then
			-- You cannot aim and sprint at the same time.
			CameraController.setAds(false)
		end
		remotes.fire("SprintState", { sprinting = on and "on" or "off" })
	end

	-- Read by the crosshair so the reticle opens exactly as wide as the real cone.
	actions.currentSpread = currentSpread

	remotes.on("RoleAssigned", function(payload)
		state.role = payload.role
	end)

	remotes.on("ProfileSync", function(profile)
		if profile.loadout and profile.loadout.primary then
			state.primary = profile.loadout.primary
		end
	end)

	remotes.on("ShotFired", function(payload)
		if payload.shooterUserId ~= LocalPlayer.UserId then
			-- Someone else's round: draw it, but never spawn impact FX for it (that would
			-- paint a marker on whoever they hit, including a hidden Patient Zero).
			drawTracer(payload.origin, payload.direction, 300, false)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end

		-- LMB / gamepad right trigger: fire as gunner, claw as zombie
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.KeyCode == Enum.KeyCode.ButtonR2
		then
			if state.role == "ZOMBIE" then
				actions.melee()
			elseif SEMI_AUTO[state.primary] then
				actions.fire()
			else
				actions.setFiring(true)
			end
		elseif
			input.UserInputType == Enum.UserInputType.MouseButton2
			or input.KeyCode == Enum.KeyCode.ButtonL2
		then
			actions.setAds(true)
		elseif
			Keybinds.matches(LocalPlayer, "throwKnife", input.KeyCode) and state.role == "PATIENT_ZERO"
		then
			actions.throwKnife()
		elseif Keybinds.matches(LocalPlayer, "melee", input.KeyCode) and state.role == "PATIENT_ZERO" then
			actions.melee()
		elseif
			Keybinds.matches(LocalPlayer, "reload", input.KeyCode)
			or input.KeyCode == Enum.KeyCode.ButtonX
		then
			actions.reload()
		elseif
			Keybinds.matches(LocalPlayer, "sprint", input.KeyCode)
			or input.KeyCode == Enum.KeyCode.ButtonL3
		then
			actions.setSprint(true)
		elseif input.KeyCode == Enum.KeyCode.ButtonL1 then
			if state.role == "PATIENT_ZERO" then
				actions.throwKnife()
			else
				actions.melee()
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.KeyCode == Enum.KeyCode.ButtonR2
		then
			actions.setFiring(false)
		elseif
			input.UserInputType == Enum.UserInputType.MouseButton2
			or input.KeyCode == Enum.KeyCode.ButtonL2
		then
			actions.setAds(false)
		elseif
			(Keybinds.matches(LocalPlayer, "sprint", input.KeyCode) or input.KeyCode == Enum.KeyCode.ButtonL3)
			and state.sprinting
		then
			actions.setSprint(false)
		end
	end)

	-- Dying, respawning or being converted mid-burst must not leave the trigger stuck down.
	local function releaseTrigger()
		actions.setFiring(false)
		CameraController.setAds(false)
	end
	remotes.on("RoleAssigned", releaseTrigger)
	LocalPlayer.CharacterRemoving:Connect(releaseTrigger)
	UserInputService.WindowFocusReleased:Connect(releaseTrigger)

	return actions
end

return CombatController
