--!strict
-- Game feel ("juice"): the layer that makes a kill or a conversion look violent and
-- satisfying in a clip. Everything here is purely cosmetic and client-local — the server
-- already decided what happened; we just make it *land*.
--   • camera trauma shake (Squirrel Eiserloh model) + FOV punch on fire
--   • floating damage numbers at the hit point
--   • muzzle flash + light on your own shots
--   • hitstop white flash on a conversion you land
--   • full-screen infection takeover when YOU get turned (green burst + vignette + stinger)
--   • gamepad haptics scaled to event weight
-- Driven entirely by the same remotes the HUD/Effects listen to, so it needs no new
-- server protocol beyond the optional position/damage now carried on HitConfirm.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local HapticService = game:GetService("HapticService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local SkinCatalog = require(Shared.SkinCatalog)

local Theme = require(script.Parent.Theme)
local CameraController = require(script.Parent.Parent.Controllers.CameraController)

local function killEffectColor(effectId: string?): Color3?
	if effectId == nil then
		return nil
	end
	for _, skin in SkinCatalog do
		if skin.id == effectId and skin.slot == "KillEffect" then
			return Color3.fromRGB(skin.color[1], skin.color[2], skin.color[3])
		end
	end
	return nil
end

local LocalPlayer = Players.LocalPlayer

local Juice = {}

-- Accessibility: colorblind mode shifts infection cues to a hue distinct from both the
-- survivor blue and the danger red; the VFX toggle suppresses the bloody spray/bursts.
local function infectionColor(): Color3
	if LocalPlayer:GetAttribute("ColorblindMode") == true then
		return Color3.fromRGB(255, 236, 0)
	end
	return Theme.Colors.Infected
end

local function goreOn(): boolean
	return LocalPlayer:GetAttribute("GoreEnabled") ~= false
end

local shakeSeed = Random.new()

-- Camera shake and FOV punch live in CameraController now — it is the single writer, so the
-- player's FOV slider is no longer stomped every frame. We just feed it events.
local addTrauma = CameraController.addTrauma
local punchFov = CameraController.addFovKick

-- Muzzle flash --------------------------------------------------------------------
local function muzzleFlash(origin: Vector3, direction: Vector3)
	local flash = Instance.new("Part")
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 230, 150)
	flash.Size = Vector3.new(0.6, 0.6, 0.6)
	flash.CFrame = CFrame.new(origin + direction * 1.2)
	flash.Parent = workspace
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 220, 140)
	light.Brightness = 6
	light.Range = 14
	light.Parent = flash
	TweenService
		:Create(flash, TweenInfo.new(0.08), { Size = Vector3.new(0.05, 0.05, 0.05), Transparency = 1 })
		:Play()
	Debris:AddItem(flash, 0.1)
end

-- Floating damage numbers ---------------------------------------------------------
local function damageNumber(position: Vector3, amount: number, killed: boolean)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	local jitter =
		Vector3.new(shakeSeed:NextNumber(-1, 1), shakeSeed:NextNumber(0, 1), shakeSeed:NextNumber(-1, 1))
	anchor.CFrame = CFrame.new(position + jitter)
	anchor.Parent = workspace

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 90, 0, 40)
	billboard.AlwaysOnTop = true
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Font = Theme.Font
	label.Text = killed and "KILL" or tostring(math.floor(amount + 0.5))
	label.TextColor3 = killed and Theme.Colors.Danger or Theme.Colors.Text
	label.TextStrokeTransparency = 0.2
	label.TextScaled = true
	label.Parent = billboard

	TweenService:Create(anchor, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = anchor.CFrame + Vector3.new(0, 4, 0),
	}):Play()
	TweenService:Create(label, TweenInfo.new(0.7), { TextTransparency = 1, TextStrokeTransparency = 1 })
		:Play()
	Debris:AddItem(anchor, 0.75)
end

-- World-space particle burst at a hit or conversion point.
local function burst(position: Vector3, color: Color3, count: number, speed: number, size: number)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = CFrame.new(position)
	part.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, size),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.25, 0.5)
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LightEmission = 0.4
	emitter.Enabled = false
	emitter.Parent = part
	emitter:Emit(count)
	Debris:AddItem(part, 0.7)
end

function Juice.start(remotes: any)
	local gui = Theme.screenGui("Juice", 8)

	-- Full-screen flash overlay (white hitstop + green infection).
	local flash = Instance.new("Frame")
	flash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	flash.BackgroundTransparency = 1
	flash.Size = UDim2.new(1, 0, 1, 0)
	flash.BorderSizePixel = 0
	flash.ZIndex = 20
	flash.Parent = gui

	-- Persistent infection mood while you're a zombie: a faint green wash whose edges
	-- are stronger than the center, built from a gradient so it needs no image asset.
	local vignette = Instance.new("Frame")
	vignette.BackgroundColor3 = Theme.Colors.Infected
	vignette.BackgroundTransparency = 1
	vignette.BorderSizePixel = 0
	vignette.Size = UDim2.new(1, 0, 1, 0)
	vignette.ZIndex = 18
	vignette.Parent = gui
	local vignetteGradient = Instance.new("UIGradient")
	vignetteGradient.Rotation = 90
	-- Opaque(ish) at the top/bottom edges, clear through the middle band.
	vignetteGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.25, 1),
		NumberSequenceKeypoint.new(0.75, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	vignetteGradient.Parent = vignette

	local stinger = Theme.label(gui, {
		Size = UDim2.new(0, 500, 0, 90),
		Position = UDim2.new(0.5, -250, 0.42, -45),
		Text = "",
		TextSize = 64,
		TextTransparency = 1,
		TextColor3 = Theme.Colors.Infected,
		TextStrokeTransparency = 0.3,
		ZIndex = 21,
	})

	local function flashScreen(color: Color3, strength: number)
		flash.BackgroundColor3 = color
		flash.BackgroundTransparency = 1 - strength
		TweenService:Create(flash, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1,
		}):Play()
	end

	local function haptic(strength: number, duration: number)
		if not HapticService:IsMotorSupported(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Large) then
			return
		end
		HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Large, strength)
		task.delay(duration, function()
			HapticService:SetMotor(Enum.UserInputType.Gamepad1, Enum.VibrationMotor.Large, 0)
		end)
	end

	local myRole = "NONE"
	local myKillEffect: string? = nil

	remotes.on("ProfileSync", function(profile)
		myKillEffect = profile.equipped and profile.equipped.KillEffect or nil
	end)

	remotes.on("ShotFired", function(payload)
		if payload.shooterUserId == LocalPlayer.UserId then
			muzzleFlash(payload.origin, payload.direction)
			-- Held-trigger fire means these stack every shot. At the old 0.12 per shot
			-- against a 1.6/s decay, trauma pinned at maximum for the whole burst and you
			-- could not see what you were shooting at.
			addTrauma(0.035)
			punchFov(1.2)
			haptic(0.35, 0.06)
		end
	end)

	remotes.on("HitConfirm", function(payload)
		addTrauma(payload.killed and 0.3 or 0.1)
		haptic(payload.killed and 0.7 or 0.3, payload.killed and 0.16 or 0.05)
		if payload.position then
			damageNumber(payload.position, payload.damage or 0, payload.killed == true)
			-- Impact spray (suppressed when VFX are off): red on a kill, pale spark otherwise.
			if goreOn() then
				burst(
					payload.position,
					payload.killed and Theme.Colors.Danger or Color3.fromRGB(255, 235, 180),
					payload.killed and 24 or 10,
					payload.killed and 22 or 12,
					payload.killed and 1.4 or 0.7
				)
			end
		end
	end)

	remotes.on("ConversionAlert", function(alert)
		-- Everyone sees an outbreak burst where a survivor turned (unless VFX are off).
		if alert.position and goreOn() then
			burst(alert.position, infectionColor(), 40, 26, 2)
		end
		-- A conversion I personally landed: hitstop-style flash + heavy kick, plus my
		-- equipped kill effect (a bigger burst in its colour) if I have one.
		if alert.killerName and alert.killerName == LocalPlayer.DisplayName then
			flashScreen(infectionColor(), 0.5)
			addTrauma(0.4)
			haptic(0.9, 0.2)
			local fxColor = killEffectColor(myKillEffect)
			if fxColor and alert.position and goreOn() then
				burst(alert.position, fxColor, 70, 34, 2.6)
			end
		end
	end)

	remotes.on("RoleAssigned", function(payload)
		local was = myRole
		myRole = payload.role
		if payload.role == "ZOMBIE" and was == "SURVIVOR" then
			-- YOU got turned: full infection takeover.
			local infColor = infectionColor()
			flashScreen(infColor, 0.85)
			addTrauma(0.9)
			haptic(1, 0.4)
			stinger.Text = "INFECTED"
			stinger.TextColor3 = infColor
			vignette.BackgroundColor3 = infColor
			stinger.TextTransparency = 0
			stinger.TextStrokeTransparency = 0.3
			TweenService
				:Create(stinger, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
					TextTransparency = 1,
					TextStrokeTransparency = 1,
				})
				:Play()
			TweenService:Create(vignette, TweenInfo.new(0.6), { BackgroundTransparency = 0.5 }):Play()
		elseif payload.role ~= "ZOMBIE" then
			-- New round / non-zombie: clear the infection vignette.
			TweenService:Create(vignette, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
		end
	end)

	remotes.on("SurvivorPing", function()
		addTrauma(0.15)
	end)

	return {}
end

return Juice
