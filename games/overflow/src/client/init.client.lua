--!strict
--[[
	overflow — client bootstrap.

	Input, the panel opener, and the wiring between the server's pushes and the
	HUD. The interface is `ui/Hud`; nothing that draws belongs here.

	The rule this file keeps: **the client asks, it never tells.** `Pull` names
	a chute and nothing else — not what is on the belt, not what it is worth —
	and the server re-checks that the player is standing at that lever before it
	believes any of it.
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
--: copies is the bug where a control works in Studio and does nothing live.
Channels.define()
SoundBank.register(Forge.Audio)
Feel.mount()

--[[
	`ignoreInset = false`, and it matters more than it looks.

	`GuiService:GetGuiInset()` answers zero until Roblox's topbar has loaded, so
	a HUD that measures the inset itself at startup sits under the Roblox menu
	on a real device while looking correct in Studio. Letting Roblox own the
	inset is the version that is right on both.
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

Net.on("Sorted", function(payload)
	hud.flash(payload.result, payload.kind)
	if payload.result == "strike" then
		Feel.shake(0.25)
	end
end)

Net.on("Gate", function()
	--: The gate's own light in the world is the real feedback; this is only
	--: the click that says the lever answered.
	Forge.Audio.play("cue.lever")
end)

hud.onBuy = function(id: string)
	Forge.Audio.play("cue.lever")
	Net.send("Buy", { id = id })
end

-- ============================== the panel opener ============================
--[[
	One `BindableFunction`, and it is not a debug hook.

	Studio refuses synthetic clicks — `client.gui_click` answers
	`virtual_input_refused` — and clicking at screen coordinates breaks the
	moment a layout moves. So the panels are opened through a function the
	client owns, which is the same function the keyboard and the touch buttons
	call. A test drives the game the way a player does rather than through a
	second path that can drift from it.

	It takes exactly one argument, because `client.invoke_bindable` passes one.
]]
local opener = Instance.new("BindableFunction")
opener.Name = "OverflowUI"
opener.OnInvoke = function(request: any): any
	local text = tostring(request or "")
	local action, name = string.match(text, "^(%a+):(%a+)$")
	if action == "open" then
		hud.setPanel(name)
		return true
	end
	return false
end
opener.Parent = ReplicatedStorage

-- ============================ nearest lever =================================
--[[
	Which lever the player is standing at.

	A local scan, and only for the prompt and for which id `Pull` names. The
	server does its own range check and its answer is the one that counts, so
	the worst this can be is wrong by a frame.
]]
local chutesFolder = Workspace:WaitForChild("Chutes", 30)

local function nearestChute(): string?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or not chutesFolder then
		return nil
	end
	local best, bestDistance = nil, Config.gate.range
	for _, model in chutesFolder:GetChildren() do
		local lever = model:FindFirstChild("Lever") :: BasePart?
		if not lever then
			continue
		end
		local flat = (lever.Position - root.Position) * Vector3.new(1, 0, 1)
		if flat.Magnitude < bestDistance then
			best = string.gsub(model.Name, "^Chute_", "")
			bestDistance = flat.Magnitude
		end
	end
	return best
end

-- ================================== input ===================================
--: Two keys. E pulls the lever you are standing at — position is the skill, so
--: there is nothing to aim and nothing to choose. B opens the workshop.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.E then
		local chute = nearestChute()
		if chute then
			Net.send("Pull", { chute = chute })
		end
	elseif input.KeyCode == Enum.KeyCode.B then
		hud.setPanel("shop")
	end
end)

--[[
	Touch: the same two verbs.

	Roblox is majority mobile and a keyboard-only scheme is a game most of its
	audience cannot play. Both targets are 64 tall, comfortably over the 44 that
	Roblox counts as the minimum for a thumb.
]]
if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
	UI.button(screen, "PULL", {
		name = "TouchPull",
		size = UDim2.fromOffset(132, 64),
		pos = UDim2.new(1, -UI.theme.space.lg, 1, -UI.theme.space.lg),
		anchor = Vector2.new(1, 1),
		onClick = function()
			local chute = nearestChute()
			if chute then
				Net.send("Pull", { chute = chute })
			end
		end,
	})
	UI.button(screen, "WORKSHOP", {
		name = "TouchShop",
		size = UDim2.fromOffset(132, 48),
		pos = UDim2.new(1, -UI.theme.space.lg, 1, -(UI.theme.space.lg + 72)),
		anchor = Vector2.new(1, 1),
		onClick = function()
			hud.setPanel("shop")
		end,
	})
end

-- ================================== camera ==================================
--[[
	A side-on camera that tracks the player along the line.

	Roblox's default third-person camera sits behind the character at roughly
	their own height and looks horizontally, which for this game frames the
	catwalk the player is standing on and hides the belt behind its own edge.
	Three screenshots in a row came back that way.

	The game is read left to right: four crates coming, four chutes to be at.
	That is a 2.5D composition, so the camera is placed rather than inherited —
	above and behind the walkway, aimed at the belt, following only the player's
	position along the line. It never rotates, so "left" on screen is always
	upstream and the player never has to re-orient mid-shift.

	Scripted rather than a `CameraOffset` nudge, because the offset approach
	still lets the player spin the camera with the right stick and lose the
	line entirely.
]]
local camera = Workspace.CurrentCamera
local cameraReady = false

local function frameLine(dt: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	if not cameraReady then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.FieldOfView = 62
		cameraReady = true
	end

	--: Clamped to the belt's own span, so walking to the end of the hall does
	--: not carry the camera off the line.
	local x = math.clamp(root.Position.X, Config.belt.headX + 18, Config.belt.tailX - 18)
	local target = Vector3.new(x, Config.belt.y + 1, Config.belt.z + 2)
	--[[
		Far enough back to hold two chute gaps in frame.

		The chutes are 36 studs apart and the decision the player is making is
		always "this lever or the next one", so the camera has to show at least
		the pair. At 62 degrees and 33 studs it showed forty studs of belt —
		barely one gap — and the neighbour the player was about to run to was
		always off-screen.
	]]
	local want = CFrame.lookAt(target + Vector3.new(0, 30, -55), target)

	--: Eased, so a sprint between levers does not whip the camera. The belt is
	--: the thing that must look steady; the player moving under it is fine.
	camera.CFrame = camera.CFrame:Lerp(want, math.min(1, dt * 6))
end

RunService.RenderStepped:Connect(frameLine)

-- ================================ character =================================
local animator = nil

local function onCharacter(character: Model)
	--[[
		Roblox's own `Animate` is destroyed before anything is waited on.

		It is a LocalScript that requests eleven stock animation assets the
		moment it runs, and on a moderated account every one of those answers
		403 — twenty-five "Failed to load animation" errors in the output, none
		of them from this game's code, all of them enough to fail the playtest
		gate. Stripping it after `WaitForChild("Humanoid")` is already too late:
		the requests are away by then.

		`Anim` replaces it with procedural motion that asks for no assets.
	]]
	local stock = character:FindFirstChild("Animate")
	if stock then
		stock:Destroy()
	end

	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	character:WaitForChild("HumanoidRootPart")
	Rig.stripDefaultAnimate(character)

	--: Set here as well as on the server, because a respawned Humanoid comes
	--: back at Roblox's default 16 and the run between levers is the game.
	humanoid.WalkSpeed = Config.walk.speed

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
