--!strict
-- Combat feel: knife flight rendering, hitmarkers, ammo counter.
-- All cosmetic — the server already decided what actually happened.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared.GameConfig)

local Theme = require(script.Parent.Theme)

local Effects = {}

local function renderKnifeFlight(origin: Vector3, direction: Vector3)
	local pz = GameConfig.Combat.PatientZero
	local knife = Instance.new("Part")
	knife.Size = Vector3.new(0.15, 0.5, 1.4)
	knife.Color = Color3.fromRGB(200, 205, 210)
	knife.Material = Enum.Material.Metal
	knife.CanCollide = false
	knife.CanQuery = false
	knife.Anchored = true
	knife.Parent = workspace

	-- Streaking trail so the throw reads as a fast, dangerous projectile in a clip.
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0, 0.6)
	a0.Parent = knife
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 0, -0.6)
	a1.Parent = knife
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.25
	trail.LightEmission = 0.5
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Color = ColorSequence.new(Color3.fromRGB(180, 255, 150))
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Parent = knife

	local position = origin
	local velocity = direction * pz.ThrowSpeed
	local traveled = 0
	local spin = 0
	local conn
	conn = RunService.RenderStepped:Connect(function(dt)
		local step = velocity * dt
		position += step
		traveled += step.Magnitude
		velocity -= Vector3.new(0, pz.ThrowGravity * dt, 0)
		spin += dt * 20
		knife.CFrame = CFrame.lookAt(position, position + velocity.Unit) * CFrame.Angles(spin, 0, 0)
		if traveled >= pz.MaxThrowRange then
			conn:Disconnect()
			knife:Destroy()
		end
	end)
	Debris:AddItem(knife, 4)
end

function Effects.start(remotes: any)
	local gui = Theme.screenGui("Effects", 2)

	-- Hitmarker
	local hitmarker = Theme.label(gui, {
		Size = UDim2.new(0, 40, 0, 40),
		Position = UDim2.new(0.5, -20, 0.5, -20),
		Text = "✕",
		TextSize = 26,
		Visible = false,
	})

	-- Ammo counter (client-side optimistic count; server is authoritative)
	local ammoLabel = Theme.label(gui, {
		Size = UDim2.new(0, 160, 0, 40),
		Position = UDim2.new(1, -172, 1, -56),
		Text = "",
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local role = "NONE"
	local primary = "AssaultRifle"
	local mag = 0

	local function magSize(): number
		local spec = (GameConfig.Combat.Guns :: any)[primary]
		return spec and spec.Mag or 0
	end

	local function refreshAmmo()
		if role == "SURVIVOR" or role == "PATIENT_ZERO" then
			ammoLabel.Text = ("%d / %d"):format(mag, magSize())
		else
			ammoLabel.Text = ""
		end
	end

	remotes.on("RoleAssigned", function(payload)
		role = payload.role
		mag = magSize()
		refreshAmmo()
	end)

	remotes.on("ProfileSync", function(profile)
		if profile.loadout and profile.loadout.primary then
			primary = profile.loadout.primary
			mag = magSize()
			refreshAmmo()
		end
	end)

	remotes.on("ShotFired", function(payload)
		if payload.shooterUserId == Players.LocalPlayer.UserId then
			mag = math.max(0, mag - 1)
			refreshAmmo()
		end
	end)

	remotes.on("HitConfirm", function(payload)
		hitmarker.TextColor3 = payload.killed and Theme.Colors.Danger or Theme.Colors.Text
		hitmarker.Text = payload.killed and "☠" or "✕"
		hitmarker.TextSize = payload.killed and 40 or 26
		-- Pop: snap large + opaque, then shrink and fade out so hits feel crunchy.
		hitmarker.Visible = true
		hitmarker.TextTransparency = 0
		hitmarker.Size = UDim2.new(0, 60, 0, 60)
		hitmarker.Position = UDim2.new(0.5, -30, 0.5, -30)
		TweenService
			:Create(hitmarker, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = UDim2.new(0, 40, 0, 40),
				Position = UDim2.new(0.5, -20, 0.5, -20),
				TextTransparency = 1,
			})
			:Play()
		task.delay(0.2, function()
			hitmarker.Visible = false
		end)
	end)

	remotes.on("KnifeThrown", function(payload)
		renderKnifeFlight(payload.origin, payload.direction)
	end)

	-- Reload finished feedback: optimistic refill after the weapon's reload time
	local reloading = false
	remotes.on("RoundState", function()
		-- reset between rounds
		mag = magSize()
		refreshAmmo()
	end)

	return {
		onReload = function()
			if reloading then
				return
			end
			reloading = true
			local spec = (GameConfig.Combat.Guns :: any)[primary]
			task.delay(spec and spec.Reload or 2, function()
				reloading = false
				mag = magSize()
				refreshAmmo()
			end)
		end,
	}
end

return Effects
