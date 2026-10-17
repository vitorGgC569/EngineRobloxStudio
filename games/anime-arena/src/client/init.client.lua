--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Wire = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Wire"))

local Net = Forge.Net
local Feel = Forge.Feel
local UI = Forge.UI
local Anim = Forge.Anim
local Rig = Forge.Rig
local Input = Forge.Input
local Audio = Forge.Audio

local player = Players.LocalPlayer

Wire.install()

Audio.defineMany({
	["hit.slash"] = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.5, pitch = { 0.9, 1.1 }, group = "sfx", cooldown = 0.05 },
	["hit.fireball"] = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.6, pitch = { 0.8, 1.0 }, group = "sfx", cooldown = 0.1 },
	["level.up"] = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.7, group = "ui", cooldown = 0.5 },
})

Feel.mount()

-- Populate HUD
local Hud = require(script:WaitForChild("ui"):WaitForChild("Hud"))
Hud.init()

Net.on("Notify", function(payload)
	UI.toast(payload.text, { color = payload.color })
end)

local state = {}
Net.on("StateSync", function(payload)
	for key, value in payload do
		state[key] = value
	end
end)

Net.on("Hit", function(payload)
	Feel.shake(0.4)
	Feel.impact(payload.pos, { color = Color3.fromRGB(255, 120, 40), count = 8 })
	Audio.playAt("hit.slash", payload.pos)
end)

Net.on("LevelUp", function(payload)
	UI.toast("Level " .. tostring(payload.level) .. "!", { color = Color3.fromRGB(255, 220, 80) })
	Audio.play("level.up")
end)

Net.on("XpGain", function(payload)
	-- handled by HUD
end)

local function getRoot()
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

Input.defineActions({
	attack = {
		keyboard = Enum.KeyCode.Q,
		gamepad = Enum.KeyCode.ButtonX,
		touch = { label = "Slash", order = 1, size = 80 },
	},
	fireball = {
		keyboard = Enum.KeyCode.E,
		gamepad = Enum.KeyCode.ButtonY,
		touch = { label = "Fireball", order = 2, size = 80 },
	},
	dash = {
		keyboard = Enum.KeyCode.LeftShift,
		gamepad = Enum.KeyCode.ButtonL2,
		touch = { label = "Dash", order = 3, size = 70 },
	},
})

Input.mount()

Input.bind("attack", function(phase)
	if phase == "began" then
		Net.send("Attack", { kind = "slash" })
	end
end)

Input.bind("fireball", function(phase)
	if phase == "began" then
		local root = getRoot()
		if root then
			Net.send("Fireball", { x = root.CFrame.LookVector.X, y = 0, z = root.CFrame.LookVector.Z })
		end
	end
end)

Input.bind("dash", function(phase)
	if phase == "began" then
		local root = getRoot()
		if root then
			local lv = root.CFrame.LookVector
			Net.send("Dash", { x = lv.X, z = lv.Z })
		end
	end
end)

local animator = nil
local function onCharacter(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not (humanoid and root) then return end
	if player.Character ~= character then return end
	Rig.stripDefaultAnimate(character)
	if animator then animator:destroy() end
	animator = Anim.new(character)
	Anim.bind(animator)
	Feel.registerAnimator(animator)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

print(string.format("[%s] client ready", Config.name))
