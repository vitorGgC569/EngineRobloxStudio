--!strict
-- The reticle. Four ticks and a centre dot built from plain Frames — no image assets.
--
-- The gap between the ticks is the on-screen projection of the *actual* cone the server
-- rolls in (see Shared.Ballistics), so the crosshair opening up while you hold the trigger
-- is a real readout of your accuracy, not decoration. Zombies get a melee pip instead.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared.Ballistics)

local Theme = require(script.Parent.Theme)
local CameraController = require(script.Parent.Parent.Controllers.CameraController)

local Crosshair = {}

local TICK_LENGTH = 7
local TICK_THICK = 2
local MIN_GAP = 3
local MAX_GAP = 90

function Crosshair.start(remotes: any, combat: any)
	-- Touch players aim with the stock cursor/thumbstick; a centre reticle would lie to them.
	if UserInputService.TouchEnabled then
		return {}
	end

	local gui = Theme.screenGui("Crosshair", 6)

	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.new(1, 0, 1, 0)
	root.Parent = gui

	local function tick(): Frame
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.fromRGB(240, 245, 240)
		f.BackgroundTransparency = 0.15
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Parent = root
		return f
	end

	local up, down, left, right = tick(), tick(), tick(), tick()

	local dot = Instance.new("Frame")
	dot.BorderSizePixel = 0
	dot.BackgroundColor3 = Color3.fromRGB(240, 245, 240)
	dot.BackgroundTransparency = 0.3
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.new(0.5, 0, 0.5, 0)
	dot.Size = UDim2.fromOffset(2, 2)
	dot.Parent = root
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot

	local role = "NONE"
	remotes.on("RoleAssigned", function(payload)
		role = payload.role
	end)

	RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if camera == nil then
			return
		end

		-- Zombies have no gun: collapse to a tight melee pip so the screen centre still
		-- reads as "where I am pointing" when you lunge.
		local isZombie = role == "ZOMBIE"
		root.Visible = true

		local gap: number
		if isZombie then
			gap = MIN_GAP + 4
		else
			local spread = combat and combat.currentSpread and combat.currentSpread() or 0
			gap = Ballistics.crosshairGap(spread, camera.FieldOfView, camera.ViewportSize.Y)
			gap = math.clamp(gap, MIN_GAP, MAX_GAP)
		end

		local length = isZombie and 4 or TICK_LENGTH
		local color = isZombie and Theme.Colors.Infected or Color3.fromRGB(240, 245, 240)

		up.Size = UDim2.fromOffset(TICK_THICK, length)
		down.Size = up.Size
		left.Size = UDim2.fromOffset(length, TICK_THICK)
		right.Size = left.Size

		up.Position = UDim2.new(0.5, 0, 0.5, -(gap + length / 2))
		down.Position = UDim2.new(0.5, 0, 0.5, gap + length / 2)
		left.Position = UDim2.new(0.5, -(gap + length / 2), 0.5, 0)
		right.Position = UDim2.new(0.5, gap + length / 2, 0.5, 0)

		for _, f in { up, down, left, right } do
			f.BackgroundColor3 = color
		end
		dot.BackgroundColor3 = color
		-- ADS drops the centre dot so it doesn't cover a distant head.
		dot.Visible = not CameraController.isAds()
	end)

	return {}
end

return Crosshair
