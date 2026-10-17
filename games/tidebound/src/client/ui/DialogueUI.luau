--!strict
--[[
	DialogueUI — the conversation panel, and the camera leaning in.

	Bottom centre, above the hint bar, because that is where the eye already
	is after reading a hint. The speaker's name sits on a plate, the words
	sit in a darker well so the paragraph has edges, and choices are 46px
	rows on a 44px floor: this is a fishing game and fishing games are
	played on tablets. While a conversation is open the camera script-tilts
	toward the speaker and on close it hands the camera back exactly as it
	found it. Walking away closes the panel, because a conversation that
	follows you home is a bug with good intentions.

	The server owns every word. This file draws payloads and sends the index
	the player tapped; nothing else crosses the wire, and `busy` means a
	jabbed finger cannot spend two choices on one turn.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local UI = Forge.UI

local Skin = require(script.Parent.Skin)

local audio = require(script.Parent.Parent.audio)

local DialogueUI = {}

local T = UI.theme
local CHOICE_HEIGHT = 46
--: How far the player may wander before the conversation ends. Matches the
--: server's tolerance plus a stride, so the server is the one that decides.
local LEAVE_DISTANCE = 22

--: `mount`, like every other UI here: build it once and leave it listening.
function DialogueUI.mount(openPanel: (string) -> ())
	local gui = UI.mount("TideboundDialogue", { displayOrder = 15 })

	local panel = UI.panel(gui, {
		name = "Dialogue",
		size = UDim2.fromOffset(560, 288),
		pos = UDim2.new(0.5, 0, 1, -116),
		anchor = Vector2.new(0.5, 1),
		color = T.color.panel,
		transparency = 0.06,
		radius = T.radius.lg,
		visible = false,
	})
	Skin.wash(panel, T.color.panelAlt:Lerp(T.color.panel, 0.55), T.color.panel)
	Skin.strip(panel, T.color.accent)

	--: The name plate is the label: the identifier the payload writes into
	--: never moves, it just lives on a pill now.
	local _, nameLabel = Skin.chip(panel, "", {
		name = "NamePlate",
		size = UDim2.fromOffset(260, 26),
		pos = UDim2.fromOffset(18, 10),
		color = T.color.panelAlt,
		transparency = 0.15,
		textColor = T.color.accent,
		font = T.font.title,
		fontSize = T.text.md,
		align = Enum.TextXAlignment.Left,
		padX = 12,
	})
	local titleLabel = UI.label(panel, "", {
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.new(1, -218, 0, 14),
		frameSize = UDim2.fromOffset(200, 16),
		align = Enum.TextXAlignment.Right,
	})

	--: The body is a well: darker than the panel so the words sit in it.
	local body = UI.panel(panel, {
		name = "Body",
		size = UDim2.new(1, -28, 0, 64),
		pos = UDim2.fromOffset(14, 40),
		color = T.color.bg,
		transparency = 0.35,
		radius = T.radius.md,
	})
	local textLabel = UI.label(body, "", {
		size = T.text.sm,
		color = T.color.text,
		pos = UDim2.fromOffset(14, 8),
		frameSize = UDim2.new(1, -28, 1, -16),
	})
	--: Scaled and wrapped rather than sized: one sentence and four
	--: sentences both have to fit the same box on the smallest tablet.
	textLabel.TextWrapped = true
	textLabel.TextScaled = true
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.TextYAlignment = Enum.TextYAlignment.Top

	Skin.divider(panel, 110)

	local choices = Instance.new("ScrollingFrame")
	choices.Name = "Choices"
	choices.BackgroundTransparency = 1
	choices.BorderSizePixel = 0
	choices.Size = UDim2.new(1, -28, 1, -126)
	choices.Position = UDim2.fromOffset(14, 116)
	choices.ScrollBarThickness = 4
	choices.ScrollBarImageColor3 = T.color.stroke
	choices.CanvasSize = UDim2.new(0, 0, 0, 0)
	choices.AutomaticCanvasSize = Enum.AutomaticSize.Y
	choices.Parent = panel
	UI.list(choices, { gap = 6 })

	local current: { npc: string }? = nil
	local busy = false
	local storedCFrame: CFrame? = nil
	local lastText = ""

	local function npcRoot(): BasePart?
		if not current then
			return nil
		end
		local root = Workspace:FindFirstChild("Tidebound")
		local npcs = root and root:FindFirstChild("Npcs")
		local model = npcs and npcs:FindFirstChild("Npc_" .. current.npc)
		if model and model:IsA("Model") then
			return model.PrimaryPart
		end
		return nil
	end

	local function close(sendLeave: boolean)
		if not current then
			return
		end
		if sendLeave then
			Net.send("DialogueLeave", { npc = current.npc })
		end
		current = nil
		busy = false
		panel.Visible = false
		local camera = Workspace.CurrentCamera
		if camera and storedCFrame then
			camera.CFrame = storedCFrame
			camera.CameraType = Enum.CameraType.Custom
		end
		storedCFrame = nil
	end

	local function rebuildChoices(offered: { any })
		for _, child in choices:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		for _, choice in offered do
			local index = choice.index
			local button = UI.button(choices, tostring(choice.text or "..."), {
				size = UDim2.new(1, -6, 0, CHOICE_HEIGHT),
				color = T.color.panelAlt,
				onClick = function()
					local active = current
					if busy or not active then
						return
					end
					busy = true
					audio.sfx("ui.click")
					Net.send("DialogueChoose", { npc = active.npc, index = index })
					--: If the server never answers (a dropped packet at the
					--: rate limit), the panel must not stay frozen forever.
					task.delay(2, function()
						busy = false
					end)
				end,
			})
			button.TextSize = T.text.sm
			button.TextWrapped = true
			--: Choices are lines to read, not labels to centre: the tick
			--: anchors the eye, the padding keeps the wrap off it.
			button.TextXAlignment = Enum.TextXAlignment.Left
			local tick = Instance.new("Frame")
			tick.Name = "Tick"
			tick.BackgroundColor3 = T.color.accent
			tick.BackgroundTransparency = 0.25
			tick.BorderSizePixel = 0
			tick.Size = UDim2.new(0, 3, 1, -18)
			tick.Position = UDim2.fromOffset(0, 9)
			tick.ZIndex = 2
			tick.Parent = button
			UI.corner(tick, 2)
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft = UDim.new(0, 28)
			pad.PaddingRight = UDim.new(0, 12)
			pad.Parent = button
		end
	end

	local function render(payload: any)
		current = { npc = payload.npc }
		busy = false
		nameLabel.Text = payload.name or "Someone"
		titleLabel.Text = payload.title or ""
		lastText = payload.text or "..."
		textLabel.Text = lastText
		rebuildChoices(payload.choices or {})
		panel.Visible = true
	end

	Net.on("DialogueOpen", function(payload: any)
		if type(payload) ~= "table" or type(payload.npc) ~= "string" then
			return
		end
		local camera = Workspace.CurrentCamera
		--: Only the first open takes the camera: if a second villager answers
		--: before the first panel closes, the frame we owe the player is the
		--: one from before the leaning started, not the lean itself.
		if camera and not current then
			storedCFrame = camera.CFrame
			camera.CameraType = Enum.CameraType.Scriptable
		end
		audio.sfx("ui.open")
		render(payload)
	end)

	Net.on("DialogueNode", function(payload: any)
		if current and type(payload) == "table" then
			render(payload)
		end
	end)

	Net.on("DialogueAction", function(payload: any)
		close(false)
		if type(payload) == "table" and type(payload.to) == "string" then
			audio.sfx("ui.open")
			openPanel(payload.to)
		end
	end)

	Net.on("DialogueClose", function()
		close(false)
	end)

	RunService.RenderStepped:Connect(function(delta: number)
		if not current then
			return
		end
		local anchor = npcRoot()
		if not anchor then
			--: The speaker left the world under us; the seam closes itself.
			close(true)
			return
		end
		local camera = Workspace.CurrentCamera
		if camera then
			local stand = anchor.Position
			local eye = stand + anchor.CFrame.LookVector * 8.5 + Vector3.new(0, 3.4, 0)
			local look = stand + Vector3.new(0, 3.2, 0)
			local alpha = 1 - math.exp(-6 * delta)
			camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(eye, look), alpha)
		end
		local character = Players.LocalPlayer.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") and (hrp.Position - anchor.Position).Magnitude > LEAVE_DISTANCE then
			close(true)
		end
	end)
end

return DialogueUI
