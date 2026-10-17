--!strict
--[[
	Saltmere — client bootstrap.

	The server is the only place a price or a pan can change. This script
	draws what StateSync and Tide already decided and sends intents back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Net = Forge.Net
local Feel = Forge.Feel
local UI = Forge.UI

local Hud = require(script:WaitForChild("ui"):WaitForChild("Hud"))

local player = Players.LocalPlayer

Net.define({
	StateSync = { dir = "s2c" },
	Tide = { dir = "s2c" },
	Notify = { dir = "s2c" },

	ClaimPan = { dir = "c2s", rate = 3, shape = { panId = "string" } },
	CollectPan = { dir = "c2s", rate = 4, shape = { panId = "string" } },
	Refine = { dir = "c2s", rate = 3, shape = { kind = "string", amount = "number" } },
	Sell = { dir = "c2s", rate = 4, shape = { grade = "string", amount = "number" } },
	BuyUpgrade = { dir = "c2s", rate = 3, shape = { upgradeId = "string" } },
	UpgradePan = { dir = "c2s", rate = 3, shape = { panId = "string" } },
	Hire = { dir = "c2s", rate = 2, shape = { roleId = "string" } },
	AssignCrew = { dir = "c2s", rate = 3, shape = { crewId = "string", panId = "string" } },
	Prestige = { dir = "c2s", rate = 1, shape = { confirm = "boolean" } },
})

Feel.mount()

local screen = UI.mount("Hud")
Hud.mount(screen)

Net.on("Notify", function(payload)
	if type(payload) == "table" and type(payload.text) == "string" then
		UI.toast(payload.text, { color = payload.color })
	end
end)

Net.on("StateSync", function(payload)
	Hud.applyProfile(payload)
end)

Net.on("Tide", function(payload)
	Hud.applyTide(payload)
end)

local function openingShot(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 8)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	local focus = root.Position + Vector3.new(18, 2, -24)
	camera.CFrame = CFrame.new(root.Position + Vector3.new(-12, 11, 14), focus)
	task.wait(3.4)
	if camera.CameraType == Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end
end

local function onCharacter(character: Model)
	task.spawn(openingShot, character)
end

if player.Character then
	onCharacter(player.Character)
end
player.CharacterAdded:Connect(onCharacter)

print(string.format("[%s] client ready", Config.name))
