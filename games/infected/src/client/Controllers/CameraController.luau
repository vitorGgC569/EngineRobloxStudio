--!strict
-- The single owner of the camera: FOV, mouse lock, shoulder offset, shake and ADS.
--
-- Before this existed, Juice force-wrote FieldOfView every frame at Camera+1, which silently
-- overrode the player's own FOV slider. Everything that wants to move the camera now asks
-- here instead, so there is exactly one writer and the settings actually stick.
--
-- Aim model: the mouse is locked to screen centre and the character's yaw follows the camera,
-- so the crosshair at the middle of the screen is genuinely where the gun points. The camera
-- sits over the right shoulder; because the character is yaw-aligned to the camera, the
-- Humanoid.CameraOffset X axis is exactly "to the shooter's right".
--
-- Mouse lock is ONLY on during ACTIVE combat. Lobby / intermission / reveal keep a free
-- cursor so shop, daily, map vote, settings, etc. are always clickable. Any MenuState panel
-- (tutorial, daily, emote wheel, shop, …) also unlocks. Hold Left Alt to free the cursor
-- mid-round without opening a menu.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local MenuState = require(script.Parent.Parent.UI.MenuState)

local LocalPlayer = Players.LocalPlayer

local CameraController = {}

local DEFAULT_FOV = 70
local ADS_FOV_MULT = 0.72
local HIP_OFFSET = Vector3.new(1.75, 0.5, 0)
local ADS_OFFSET = Vector3.new(0.9, 0.35, 0)
local OFFSET_LERP = 12 -- per-second approach rate for the shoulder swap
local MAX_SHAKE_DEG = 5

local state = {
	baseFov = DEFAULT_FOV,
	fovKick = 0,
	trauma = 0,
	ads = false,
	sprinting = false,
	-- Touch keeps the stock camera and cursor entirely; mouse lock would break the thumbsticks.
	locking = not UserInputService.TouchEnabled,
	menuOpen = false,
	-- True only while a live round is ACTIVE (combat). Everything else is free-cursor UI time.
	combatActive = false,
	-- Hold Left Alt to free the mouse mid-round (click shop/settings without a keybind).
	freeMouseHold = false,
}

local shakeSeed = Random.new()

-- Public: the FOV slider in Settings calls this instead of writing the camera directly.
function CameraController.setBaseFov(fov: number)
	state.baseFov = math.clamp(fov, 40, 120)
end

function CameraController.getBaseFov(): number
	return state.baseFov
end

-- Public: Juice's per-shot punch. Additive and self-decaying.
function CameraController.addFovKick(amount: number)
	state.fovKick = math.clamp(state.fovKick + amount, 0, 12)
end

function CameraController.addTrauma(amount: number)
	state.trauma = math.clamp(state.trauma + amount, 0, 1)
end

function CameraController.setAds(on: boolean)
	state.ads = on
end

function CameraController.isAds(): boolean
	return state.ads
end

-- Mirrored from the combat controller's sprint input; sprinting widens the cone.
function CameraController.setSprinting(on: boolean)
	state.sprinting = on
end

-- Stance for the spread model: what the shooter is doing right now.
function CameraController.stance(): { ads: boolean, moving: boolean, sprinting: boolean, airborne: boolean }
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local moving, airborne = false, false
	if humanoid then
		moving = humanoid.MoveDirection.Magnitude > 0.1
		local s = humanoid:GetState()
		airborne = s == Enum.HumanoidStateType.Freefall or s == Enum.HumanoidStateType.Jumping
	end
	return {
		ads = state.ads,
		moving = moving,
		sprinting = moving and state.sprinting,
		airborne = airborne,
	}
end

local function wantsMouseLock(): boolean
	if not state.locking or UserInputService.TouchEnabled then
		return false
	end
	if state.menuOpen or state.freeMouseHold then
		return false
	end
	-- Free cursor outside live combat so every HUD / popup is clickable without a special case.
	if not state.combatActive then
		return false
	end
	return true
end

local function applyMouseBehavior()
	if wantsMouseLock() then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

function CameraController.start(remotes: any?)
	MenuState.onChanged(function(open)
		state.menuOpen = open
		applyMouseBehavior()
	end)

	-- Hold Alt to free the cursor mid-round (click any HUD button without opening a menu first).
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
			state.freeMouseHold = true
			applyMouseBehavior()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
			state.freeMouseHold = false
			applyMouseBehavior()
		end
	end)

	if remotes then
		remotes.on("RoundState", function(payload)
			local s = payload and payload.state
			state.combatActive = s == "ACTIVE"
			applyMouseBehavior()
		end)
	end

	-- Roblox resets MouseBehavior on its own in a few cases (respawn, focus loss), so we
	-- reassert it every frame rather than only on change.
	RunService:BindToRenderStep("InfectedCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local camera = workspace.CurrentCamera
		if camera == nil then
			return
		end

		applyMouseBehavior()

		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local alive = humanoid ~= nil and humanoid.Health > 0

		-- Shoulder offset. Tweened by hand rather than TweenService so ADS can be
		-- interrupted mid-transition without leaving a tween fighting us.
		if humanoid then
			local target = state.ads and ADS_OFFSET or HIP_OFFSET
			local alpha = math.clamp(dt * OFFSET_LERP, 0, 1)
			humanoid.CameraOffset = humanoid.CameraOffset:Lerp(target, alpha)
		end

		-- Yaw-align the character to the camera so "screen centre" is also "muzzle forward".
		-- Position is untouched, so this reads as pure rotation to the server's anti-cheat
		-- (which only measures speed and teleport distance).
		if alive and root and root:IsA("BasePart") and wantsMouseLock() then
			if humanoid and humanoid.AutoRotate then
				humanoid.AutoRotate = false
			end
			local look = camera.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude > 1e-4 then
				flat = flat.Unit
				root.CFrame = CFrame.lookAt(root.Position, root.Position + flat)
			end
		elseif humanoid and not humanoid.AutoRotate then
			-- Menu open, free-cursor phase, dead, or touch device: stock camera control.
			humanoid.AutoRotate = true
		end

		-- Accessibility: motion-sensitive players get a heavily damped version of both.
		local motionScale = LocalPlayer:GetAttribute("ReducedMotion") == true and 0.15 or 1

		local fov = state.baseFov * (state.ads and ADS_FOV_MULT or 1) + state.fovKick * motionScale
		if math.abs(camera.FieldOfView - fov) > 0.01 then
			camera.FieldOfView = fov
		end
		if state.fovKick > 0 then
			state.fovKick = math.max(0, state.fovKick - dt * 40)
		end

		if state.trauma > 0 then
			-- Perceived shake is trauma^2 so light taps stay subtle and getting infected kicks.
			local shake = state.trauma * state.trauma
			local maxAngle = math.rad(MAX_SHAKE_DEG) * shake * motionScale
			camera.CFrame = camera.CFrame
				* CFrame.Angles(
					shakeSeed:NextNumber(-1, 1) * maxAngle,
					shakeSeed:NextNumber(-1, 1) * maxAngle,
					shakeSeed:NextNumber(-1, 1) * maxAngle * 0.5
				)
			state.trauma = math.max(0, state.trauma - dt * 3.5)
		end
	end)

	return CameraController
end

return CameraController
