--!strict
--[[
	Lanternreach — client.

	No combat input, no attack loop. Interaction is handled by ProximityPrompts
	that Forge registered server-side, so this file only renders state and runs
	the conversation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Net = Forge.Net
local Anim = Forge.Anim
local Rig = Forge.Rig
local Feel = Forge.Feel
local UI = Forge.UI
local Input = Forge.Input
local Audio = Forge.Audio
local Visual = Forge.Visual

local Hud = require(script:WaitForChild("ui"):WaitForChild("Hud"))
local EditorUi = require(ReplicatedStorage.Forge.Editor.Ui)

local player = Players.LocalPlayer

Net.define({
	StateSync = { dir = "s2c" },
	Notify = { dir = "s2c" },
	Opened = { dir = "s2c" },
	Dialogue = { dir = "s2c" },
	Quests = { dir = "s2c" },

	DialogueChoice = { dir = "c2s", rate = 6, shape = { index = "number" } },
	AcceptQuest = { dir = "c2s", rate = 4, shape = { quest = "string" } },
})

Anim.registerAll(require(ReplicatedStorage.Forge.Anim.Presets))

Feel.mount()
Hud.init()

-- Art direction scaled to the device. A phone that tries to run three post
-- effects and shadow maps drops to fifteen frames and the player blames the
-- game, not the settings they were never offered.
Visual.autoQuality()

--[[
	The sky, the clouds, the water and a day that passes.

	Lighting is a client concern, so the cycle runs here. Terrain water and the
	Clouds instance replicate from the server copy, but setting them client-side
	costs nothing and keeps every visual decision in one file.
]]
local Sky = require(ReplicatedStorage.Forge.Visual.Sky)
Sky.cycle({ minutesPerDay = 20, startHour = 21.5 })

-- Cues. Ids are the game's to supply; the engine handles pooling, pitch
-- variation, groups and ducking.
Audio.defineMany({
	["ui.toast"] = { id = "rbxassetid://12221967", volume = 0.25, pitch = { 0.96, 1.04 }, group = "ui" },
	["salvage.open"] = { id = "rbxassetid://9125402735", volume = 0.5, pitch = { 0.9, 1.1 }, cooldown = 0.05 },
	["salvage.empty"] = { id = "rbxassetid://9114641275", volume = 0.35, pitch = { 0.95, 1.05 } },
	["coin"] = { id = "rbxassetid://9083802673", volume = 0.4, pitch = { 0.98, 1.12 }, group = "ui" },
})

-- Actions, not keys. Declaring a `touch` table is the whole mobile port.
Input.defineActions({
	interact = {
		keyboard = Enum.KeyCode.F,
		gamepad = Enum.KeyCode.ButtonX,
		touch = { label = "Talk", order = 1 },
		description = "Speak to the Keeper",
	},
	journal = {
		keyboard = Enum.KeyCode.J,
		gamepad = Enum.KeyCode.ButtonY,
		touch = { label = "Log", order = 2 },
		description = "Open the night's log",
	},
})
Input.mount()

Input.bind("journal", function(phase)
	if phase == "begin" then
		Hud.toggleLog()
	end
end)

-- F4 opens the world editor. Same operations an agent sends, same server-side
-- authorisation, so there is nothing here automation cannot also reach.
EditorUi.mount()

-- ============================== character ===================================
local animator = nil

local function onCharacter(character: Model)
	character:WaitForChild("Humanoid")
	character:WaitForChild("HumanoidRootPart")
	Rig.stripDefaultAnimate(character)

	if animator then
		animator:destroy()
	end
	animator = Anim.new(character)
	-- Wading through shallow water: heavier gait than a fighter's.
	animator:setProfile(Anim.profiles.heavy)
	Anim.bind(animator)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

-- ============================== feedback ====================================
Net.on("Notify", function(payload)
	UI.toast(payload.text, { color = payload.color, duration = 4 })
	Audio.play("ui.toast")
end)

Net.on("Opened", function(payload)
	if animator then
		animator:play("interact")
	end

	Feel.impact(payload.pos, { kind = "puff", color = Color3.fromRGB(190, 210, 200), scale = 1.4 })
	Feel.shake(0.12)

	-- Float each item out of the cache, staggered so a three-item haul reads
	-- as three things and not one blur.
	for index, entry in payload.items do
		task.delay(index * 0.12, function()
			Feel.number(
				payload.pos + Vector3.new(0, 1.5, 0),
				string.format("+%d %s", entry.count, entry.item),
				{ color = Color3.fromRGB(214, 232, 224), lifetime = 1.5 }
			)
		end)
	end

	if #payload.items == 0 then
		Feel.number(payload.pos, "empty", { color = Color3.fromRGB(150, 150, 160) })
		Audio.playAt("salvage.empty", payload.pos)
	else
		Audio.playAt("salvage.open", payload.pos)
	end
end)

Net.on("StateSync", Hud.update)
Net.on("Dialogue", Hud.showDialogue)
Net.on("Quests", Hud.showQuests)

print(string.format("[%s] client ready", Config.name))
