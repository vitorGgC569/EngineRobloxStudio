--!strict
-- Zombie ability button + cooldown. The server tells us (AbilityState) whether our current
-- zombie class has a player-activated ability and its cooldown/ready state; we show a button
-- (desktop Q / on-screen tap / gamepad Y) and fire UseAbility. The server is authoritative
-- on the cooldown — this is just input + feedback.

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Keybinds = require(ReplicatedStorage:WaitForChild("Shared").Keybinds)
local Theme = require(script.Parent.Theme)

local Ability = {}

function Ability.start(remotes: any)
	local gui = Theme.screenGui("Ability", 7)

	local ABILITY_LABELS = { lunge = "LUNGE  [Q]", cloak = "CLOAK  [Q]" }

	local button = Theme.button(gui, {
		Size = UDim2.new(0, 150, 0, 54),
		Position = UDim2.new(0.5, -75, 1, -80),
		Text = "ABILITY  [Q]",
		TextSize = 16,
		BackgroundColor3 = Theme.Colors.Infected,
		TextColor3 = Theme.Colors.Bg,
		Visible = false,
	})
	-- Cooldown wipe: a dark overlay that shrinks to reveal the button as it recharges.
	local cover = Theme.frame(button, {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.5,
		Visible = false,
	})
	Theme.corner(cover, 8)

	local hasAbility = false
	local ready = false

	local function activate()
		if hasAbility and ready then
			remotes.fire("UseAbility")
		end
	end

	button.Activated:Connect(activate)

	remotes.on("AbilityState", function(state)
		local label = state.ability and ABILITY_LABELS[state.ability]
		if label == nil then
			hasAbility = false
			button.Visible = false
			return
		end
		hasAbility = true
		button.Visible = true
		ready = state.ready == true
		if ready then
			button.Text = label
			cover.Visible = false
			button.AutoButtonColor = true
			button.BackgroundColor3 = Theme.Colors.Infected
		else
			-- Play a cooldown wipe over the button's cooldown seconds.
			button.AutoButtonColor = false
			button.BackgroundColor3 = Theme.Colors.PanelLight
			cover.Visible = true
			cover.Size = UDim2.new(1, 0, 1, 0)
			cover.Position = UDim2.new(0, 0, 0, 0)
			TweenService:Create(cover, TweenInfo.new(state.cooldown or 8, Enum.EasingStyle.Linear), {
				Size = UDim2.new(1, 0, 0, 0),
				Position = UDim2.new(0, 0, 1, 0),
			}):Play()
		end
	end)

	-- Reset on role change (no longer a zombie -> hide).
	remotes.on("RoleAssigned", function(payload)
		if payload.role ~= "ZOMBIE" then
			hasAbility = false
			button.Visible = false
		end
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		if
			Keybinds.matches(Players.LocalPlayer, "ability", input.KeyCode)
			or input.KeyCode == Enum.KeyCode.ButtonY
		then
			activate()
		end
	end)

	return {}
end

return Ability
