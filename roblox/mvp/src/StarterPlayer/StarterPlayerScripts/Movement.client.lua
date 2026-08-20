--!strict
-- Sprint.
--
-- A farm is 175 studs across and the map is 964 by 1554. At the default 16
-- studs/second, crossing from the belt to the box shop takes long enough that
-- the walk becomes the game. Sprint is not a feature here so much as a fix for
-- a distance problem the map created.
--
-- Held, not toggled: a hold matches what the key does elsewhere in the genre,
-- and it cannot get stuck on after an alt-tab.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local WALK_SPEED = 16
local SPRINT_SPEED = 32
local RAMP_SECONDS = 0.22

local player = Players.LocalPlayer

local function humanoid(): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local sprinting = false

local function apply(target: number)
	local human = humanoid()
	if human == nil then
		return
	end
	-- Tweened rather than snapped: an instant speed change reads as a glitch,
	-- and the ramp is short enough to still feel immediate.
	TweenService:Create(human, TweenInfo.new(RAMP_SECONDS), { WalkSpeed = target }):Play()
end

local function setSprinting(value: boolean)
	if sprinting == value then
		return
	end
	sprinting = value
	apply(if value then SPRINT_SPEED else WALK_SPEED)
end

ContextActionService:BindAction("Sprint", function(_name, state)
	if state == Enum.UserInputState.Begin then
		setSprinting(true)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		setSprinting(false)
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.ButtonL3)

-- Touch and gamepad players have no shift key, so give them a button.
ContextActionService:SetTitle("Sprint", "Correr")
ContextActionService:SetPosition("Sprint", UDim2.fromScale(0.72, 0.18))

-- Losing focus while held would otherwise leave the player sprinting forever.
UserInputService.WindowFocusReleased:Connect(function()
	setSprinting(false)
end)

player.CharacterAdded:Connect(function()
	sprinting = false
	task.wait(0.4)
	apply(WALK_SPEED)
end)

apply(WALK_SPEED)
