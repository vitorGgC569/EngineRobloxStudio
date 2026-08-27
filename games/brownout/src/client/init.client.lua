--!strict
--[[
	brownout — client bootstrap.

	Input, the lantern, and the wiring between the server's pushes and the HUD.
	The interface itself is `ui/Hud`; nothing that draws belongs in this file.

	The one rule this file exists to keep: **the client asks, it never tells.**
	`Grab` carries no cell id, `Buy` carries no price, and nothing here computes
	a value the server then trusts. Everything below is presentation and intent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Net = Forge.Net
local Feel = Forge.Feel
local UI = Forge.UI
local Anim = Forge.Anim
local Rig = Forge.Rig

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Channels = require(Shared:WaitForChild("Channels"))
local SoundBank = require(Shared:WaitForChild("Sound"))
local Hud = require(script:WaitForChild("ui"):WaitForChild("Hud"))

local player = Players.LocalPlayer

--: Same list the server declared, from the same module. Two hand-written
--: copies is the bug where a button works in Studio and does nothing live.
Channels.define()

--: Camera shake, hitstop and FOV punch. Without this call they are inert.
Feel.mount()

--[[
	The sound bank, and the two beds under everything.

	`Audio.define` is per-VM exactly like `Net.define`, so the client registers
	the same table the server did. The beds are played here rather than on the
	server because a non-positional looped sound started server-side is one
	Sound instance replicated to everybody and mixed identically for all of
	them — which is right for a cue and wrong for ambience.
]]
SoundBank.register(Forge.Audio)
Forge.Audio.play("bed.night")
Forge.Audio.play("bed.wind")

--[[
	The HUD keeps Roblox's top inset.

	`UI.mount` defaults to `IgnoreGuiInset = true`, which puts (0, 0) at the
	true top of the window — underneath the Roblox topbar. The first screenshot
	of this game had the generator gauge sitting behind the chat and menu
	buttons, reporting `absolutePosition` of -40 on the Y axis. A full-bleed
	background wants the inset ignored; a panel the player has to read does not.
]]
local screen = UI.mount("Hud", { ignoreInset = false })
local hud = Hud.build(screen)

-- ================================= the wire =================================

Net.on("Shift", function(payload)
	hud.setShift(payload)
end)

Net.on("You", function(payload)
	hud.setYou(payload)
end)

Net.on("Notify", function(payload)
	local colour = UI.theme.color.text
	if payload.tone == "good" then
		colour = UI.theme.color.good
	elseif payload.tone == "warn" then
		colour = UI.theme.color.warning
	elseif payload.tone == "bad" then
		colour = UI.theme.color.danger
	end
	UI.toast(payload.text, { color = colour })
end)

Net.on("Surge", function(payload)
	hud.surge(payload)
	--: A small kick on every delivery, anybody's. Co-op needs its teammates to
	--: be audible in some sense, and this game has no voice for them otherwise.
	Feel.shake(payload.grade * 0.05)
end)

hud.onBuy = function(id: string)
	Forge.Audio.play("cue.click")
	Net.send("Buy", { id = id })
end

-- ================================== input ===================================
--[[
	Three keys and no menus.

	E and Q are next to each other and next to WASD, because both are pressed
	while running. B opens the outfitter, which is the only thing here that is
	ever done standing still.
]]
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.E then
		Net.send("Grab", {})
	elseif input.KeyCode == Enum.KeyCode.Q then
		Net.send("Drop", {})
	elseif input.KeyCode == Enum.KeyCode.B then
		hud.toggleShop()
	end
end)

--[[
	Touch: the same three actions as buttons.

	Roblox is majority mobile and a keyboard-only control scheme is a game most
	of its audience cannot play at all. This is not a port, it is the same three
	verbs with a thumb-sized target each.
]]
if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
	local pad = UI.panel(screen, {
		name = "TouchPad",
		size = UDim2.fromOffset(196, 64),
		pos = UDim2.new(1, -UI.theme.space.lg, 1, -UI.theme.space.lg),
		anchor = Vector2.new(1, 1),
		padding = UI.theme.space.sm,
	})
	UI.button(pad, "LIFT", {
		size = UDim2.fromOffset(84, 46),
		onClick = function()
			Net.send("Grab", {})
		end,
	})
	UI.button(pad, "DROP", {
		size = UDim2.fromOffset(84, 46),
		pos = UDim2.fromOffset(96, 0),
		onClick = function()
			Net.send("Drop", {})
		end,
	})
	UI.button(screen, "OUTFITTER", {
		size = UDim2.fromOffset(120, 34),
		pos = UDim2.new(1, -UI.theme.space.lg, 1, -96),
		anchor = Vector2.new(1, 1),
		onClick = function()
			hud.toggleShop()
		end,
	})
end

-- ================================= lantern ==================================
--[[
	The light the player carries.

	Client-side, and that is not a shortcut. A PointLight parented to a
	character on the server replicates to every other client, which for eight
	players is eight extra dynamic lights in a Future-lighting scene that
	already has forty. Each player rendering only their own lantern costs one
	light and looks identical from where they are standing.

	Its radius is the server's number, pushed in the `You` packet, so the light
	the player sees and the leash the server enforces cannot disagree.
]]
local lantern: PointLight? = nil

local function attachLantern(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not root then
		return
	end
	--[[
		Carried on a point in front of the chest, not inside it.

		A PointLight parented straight to the HumanoidRootPart sits inside the
		torso and lights the character from within: the first screenshot with a
		lantern in it had a player who read as a glowing white blob rather than a
		person holding a lamp. An attachment two studs forward puts the source
		where a held lantern would be, and the character is lit by it instead of
		being it.

		Brightness is low for the same reason. This is a lamp you see *by*, not a
		lamp you look at, and at fifteen studs anything above about one washes
		out everything it touches.
	]]
	local mount = Instance.new("Attachment")
	mount.Name = "LanternMount"
	mount.Position = Vector3.new(0, 0.4, -1.8)
	mount.Parent = root

	local light = Instance.new("PointLight")
	light.Name = "Lantern"
	light.Brightness = 1.05
	light.Range = Config.exposure.lanternRadius
	light.Color = Color3.fromRGB(255, 206, 148)
	light.Shadows = false
	light.Parent = mount
	lantern = light
end

RunService.RenderStepped:Connect(function(dt)
	if lantern then
		--: Eased, so buying the upgrade is a light that grows rather than a
		--: light that was suddenly different.
		local want = hud.you.lantern or Config.exposure.lanternRadius
		lantern.Range += (want - lantern.Range) * math.min(1, dt * 4)
	end
end)

-- ============================== nearest cell ================================
--[[
	The prompt's eyes.

	A purely local scan, purely for the prompt. The server does its own search
	when `Grab` arrives and its answer is the one that counts — this can be
	wrong by a frame or by a streaming boundary and the worst case is a hint
	that appears slightly early.
]]
local cellFolder = Workspace:WaitForChild("Cells", 30)

local function nearestCell(): any
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or not cellFolder then
		return nil
	end

	local best, bestDistance = nil, Config.cells.pickupRange
	for _, model in cellFolder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local core = model:FindFirstChild("Core") :: BasePart?
		if not core then
			continue
		end
		local distance = (core.Position - root.Position).Magnitude
		if distance < bestDistance then
			best = { grade = model:GetAttribute("Grade") or 1 }
			bestDistance = distance
		end
	end
	return best
end

task.spawn(function()
	--: Six times a second. The prompt is a hint, and a hint that costs a full
	--: scan of the cell folder every frame is a hint that costs frames.
	while true do
		task.wait(1 / 6)
		hud.nearCell = nearestCell()
	end
end)

-- ================================ character =================================
local animator = nil

local function onCharacter(character: Model)
	character:WaitForChild("Humanoid")
	character:WaitForChild("HumanoidRootPart")
	Rig.stripDefaultAnimate(character)

	if animator then
		animator:destroy()
	end
	animator = Anim.new(character)
	Anim.bind(animator)
	Feel.registerAnimator(animator)

	attachLantern(character)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

print(string.format("[%s] client ready", Config.name))
