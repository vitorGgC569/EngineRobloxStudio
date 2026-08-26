--!strict
-- Settings panel (accessibility + comfort): FOV, independent Music + SFX volume (via the
-- SoundGroups from Sounds), a colorblind-mode toggle (infection cues shift to a colorblind-
-- distinct hue, read by Juice), and an infection-VFX toggle. Persisted for the session via
-- player attributes / SoundGroup volumes.

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Keybinds = require(ReplicatedStorage:WaitForChild("Shared").Keybinds)
local Theme = require(script.Parent.Theme)
local CameraController = require(script.Parent.Parent.Controllers.CameraController)
local MenuState = require(script.Parent.MenuState)
local Sounds = require(script.Parent.Sounds)

local Settings = {}

function Settings.start()
	local gui = Theme.screenGui("Settings", 4)
	local LocalPlayer = Players.LocalPlayer

	local toggle = Theme.button(gui, {
		Size = UDim2.new(0, 90, 0, 36),
		Position = UDim2.new(0, 12, 0, 108),
		Text = "SETTINGS",
		TextSize = 13,
	})

	local panel = Theme.frame(gui, {
		Size = UDim2.new(0, 300, 0, 428),
		Position = UDim2.new(0.5, -150, 0.5, -214),
		BackgroundTransparency = 0.05,
		Visible = false,
	})
	-- Releases the locked mouse while this panel is open.
	MenuState.track(panel)
	Theme.corner(panel, 14)
	Theme.gradient(panel, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	Theme.stroke(panel, Color3.fromRGB(60, 64, 78), 1, 0.3)
	Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 0, 8),
		Text = "SETTINGS",
		TextSize = 20,
		Font = Theme.FontDisplay,
	})

	local function sliderRow(
		order: number,
		labelText: string,
		initial: number,
		onChange: (value: number) -> ()
	)
		local y = 44 + (order - 1) * 52
		Theme.label(panel, {
			Size = UDim2.new(1, -32, 0, 18),
			Position = UDim2.new(0, 16, 0, y),
			Text = labelText,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.Colors.TextDim,
		})
		local bar = Theme.frame(panel, {
			Size = UDim2.new(1, -32, 0, 10),
			Position = UDim2.new(0, 16, 0, y + 24),
			BackgroundColor3 = Theme.Colors.PanelLight,
		})
		Theme.corner(bar, 5)
		local fill = Theme.frame(bar, {
			Size = UDim2.new(initial, 0, 1, 0),
			BackgroundColor3 = Theme.Colors.Survivor,
		})
		Theme.corner(fill, 5)
		local dragging = false
		local function setFromX(x: number)
			local fraction = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
			fill.Size = UDim2.new(fraction, 0, 1, 0)
			onChange(fraction)
		end
		bar.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = true
				setFromX(input.Position.X)
			end
		end)
		UserInputService.InputEnded:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				dragging = false
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if
				dragging
				and (
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				setFromX(input.Position.X)
			end
		end)
	end

	local musicGroup, sfxGroup = Sounds.getGroups()

	sliderRow(1, "FIELD OF VIEW", 0.5, function(fraction)
		-- Goes through CameraController, which is the only thing allowed to write
		-- FieldOfView. Writing the camera directly here used to be undone the next frame.
		CameraController.setBaseFov(60 + fraction * 40) -- 60..100
	end)
	sliderRow(2, "MUSIC VOLUME", musicGroup.Volume, function(fraction)
		musicGroup.Volume = fraction
	end)
	sliderRow(3, "SFX VOLUME", sfxGroup.Volume, function(fraction)
		sfxGroup.Volume = fraction
	end)
	-- UI SIZE: scale the whole interface (accessibility / readability) by adding a UIScale to
	-- every ScreenGui. Applies to existing and future GUIs.
	sliderRow(4, "UI SIZE", 0.28, function(fraction)
		local scale = 0.8 + fraction * 0.7 -- 0.8 .. 1.5
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if playerGui == nil then
			return
		end
		for _, screen in playerGui:GetChildren() do
			if screen:IsA("ScreenGui") then
				local uiScale = screen:FindFirstChildOfClass("UIScale")
				if uiScale == nil then
					uiScale = Instance.new("UIScale")
					uiScale.Parent = screen
				end
				uiScale.Scale = scale
			end
		end
	end)

	-- Toggle buttons
	local function toggleButton(
		y: number,
		onText: string,
		offText: string,
		initial: boolean,
		onChange: (on: boolean) -> ()
	)
		local on = initial
		local button = Theme.button(panel, {
			Size = UDim2.new(1, -32, 0, 32),
			Position = UDim2.new(0, 16, 0, y),
			Text = initial and onText or offText,
			TextSize = 13,
		})
		button.Activated:Connect(function()
			on = not on
			button.Text = on and onText or offText
			onChange(on)
		end)
		return button
	end

	toggleButton(262, "COLORBLIND MODE: ON", "COLORBLIND MODE: OFF", false, function(on)
		-- Juice reads this to shift infection cues to a colorblind-distinct hue.
		LocalPlayer:SetAttribute("ColorblindMode", on)
	end)
	toggleButton(300, "INFECTION VFX: ON", "INFECTION VFX: OFF", true, function(on)
		LocalPlayer:SetAttribute("GoreEnabled", on)
	end)
	toggleButton(338, "REDUCED MOTION: ON", "REDUCED MOTION: OFF", false, function(on)
		-- Juice reads this to damp camera shake + FOV kick for motion-sensitive players.
		LocalPlayer:SetAttribute("ReducedMotion", on)
	end)

	-- Controls / rebind sub-panel ------------------------------------------------
	local controlsPanel = Theme.frame(gui, {
		Size = UDim2.new(0, 320, 0, 320),
		Position = UDim2.new(0.5, -160, 0.5, -160),
		BackgroundColor3 = Theme.Colors.Panel,
		Visible = false,
	})
	-- Own MenuState entry so rebind stays clickable even if the main panel is closed.
	MenuState.track(controlsPanel)
	Theme.corner(controlsPanel, 14)
	Theme.gradient(controlsPanel, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	Theme.stroke(controlsPanel, Color3.fromRGB(60, 64, 78), 1, 0.3)
	Theme.label(controlsPanel, {
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 0, 8),
		Text = "CONTROLS",
		TextSize = 20,
		Font = Theme.FontDisplay,
	})
	local controlsClose = Theme.button(controlsPanel, {
		Size = UDim2.new(0, 32, 0, 32),
		Position = UDim2.new(1, -40, 0, 8),
		Text = "X",
	})
	controlsClose.Activated:Connect(function()
		controlsPanel.Visible = false
	end)

	local listening: string? = nil
	local keyButtons: { [string]: TextButton } = {}
	for i, action in Keybinds.Order do
		local y = 44 + (i - 1) * 42
		Theme.label(controlsPanel, {
			Size = UDim2.new(0, 160, 0, 32),
			Position = UDim2.new(0, 16, 0, y),
			Text = Keybinds.Labels[action],
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.Colors.TextDim,
		})
		local keyButton = Theme.button(controlsPanel, {
			Size = UDim2.new(0, 110, 0, 32),
			Position = UDim2.new(1, -126, 0, y),
			Text = Keybinds.get(LocalPlayer, action),
			TextSize = 14,
		})
		keyButton.Activated:Connect(function()
			listening = action
			keyButton.Text = "press a key..."
		end)
		keyButtons[action] = keyButton
	end

	-- Capture the next keyboard key while listening for a rebind.
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if listening == nil or gameProcessed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode ~= Enum.KeyCode.None then
			local action = listening
			listening = nil
			Keybinds.set(LocalPlayer, action, input.KeyCode.Name)
			keyButtons[action].Text = input.KeyCode.Name
		end
	end)

	local controlsButton = Theme.button(panel, {
		Size = UDim2.new(1, -32, 0, 32),
		Position = UDim2.new(0, 16, 0, 376),
		Text = "CONTROLS / REBIND",
		TextSize = 13,
		BackgroundColor3 = Theme.Colors.Survivor,
		TextColor3 = Theme.Colors.Bg,
	})
	controlsButton.Activated:Connect(function()
		controlsPanel.Visible = not controlsPanel.Visible
	end)

	local close = Theme.button(panel, {
		Size = UDim2.new(0, 32, 0, 32),
		Position = UDim2.new(1, -40, 0, 8),
		Text = "X",
	})
	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
	close.Activated:Connect(function()
		panel.Visible = false
	end)

	return {}
end

return Settings
