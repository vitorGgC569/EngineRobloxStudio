--!strict
--[[
	{{NAME}} — client bootstrap.

	Wiring only. Interface goes in `src/client/ui/`, input in
	`src/client/input/`, and neither belongs in this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Net = Forge.Net
local Feel = Forge.Feel
local UI = Forge.UI
local Anim = Forge.Anim
local Rig = Forge.Rig

local player = Players.LocalPlayer

-- The client must declare the same contract as the server.
Net.define({
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	Ping = { dir = "c2s", rate = 2, shape = {} },
})

-- Camera shake, hitstop and FOV punch. Without this call they are inert.
Feel.mount()

local screen = UI.mount("Hud")

Net.on("Notify", function(payload)
	UI.toast(payload.text, { color = payload.color })
end)

-- The server pushes the whole profile on join and whenever it changes.
-- Read from here; never keep a second copy of state on the client.
local state = {}

Net.on("StateSync", function(payload)
	for key, value in payload do
		state[key] = value
	end
end)

-- Procedural animation on the local character.
-- Rig.stripDefaultAnimate first, or Roblox's own Animate script fights it.
local animator = nil

local function onCharacter(character)
	character:WaitForChild("Humanoid")
	character:WaitForChild("HumanoidRootPart")
	Rig.stripDefaultAnimate(character)

	if animator then
		animator:destroy()
	end
	animator = Anim.new(character)
	Anim.bind(animator)
	Feel.registerAnimator(animator)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

print(string.format("[%s] client ready", Config.name))
