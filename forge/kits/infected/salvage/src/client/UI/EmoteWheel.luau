--!strict
-- Emote wheel. Hold the emote key to open, click a wedge (or press 1-7) to play.
--
-- Only shown when your role can actually use it, so a zombie isn't offered a dance button
-- that silently does nothing. Note that the hidden Patient Zero DOES get the wheel — waving
-- along with the survivors is the bluff the game is built on.

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Emotes = require(Shared.Emotes)

local Theme = require(script.Parent.Theme)
local MenuState = require(script.Parent.MenuState)

local EmoteWheel = {}

local RADIUS = 120
local BUTTON = 78

function EmoteWheel.start(remotes: any)
	local gui = Theme.screenGui("EmoteWheel", 7)

	local panel = Instance.new("Frame")
	panel.BackgroundTransparency = 1
	panel.Size = UDim2.new(0, RADIUS * 2 + BUTTON, 0, RADIUS * 2 + BUTTON)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Visible = false
	panel.Parent = gui

	-- Releases the locked mouse while the wheel is open, so you can click a wedge.
	MenuState.track(panel)

	Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0, 0, 0.5, -13),
		Text = "EMOTE",
		TextSize = 16,
		TextTransparency = 0.35,
	})

	local role = "NONE"

	local function play(emoteId: string)
		remotes.fire("PlayEmote", { emoteId = emoteId })
		panel.Visible = false
	end

	local count = #Emotes.Catalog
	for i, emote in Emotes.Catalog do
		local angle = (i - 1) / count * math.pi * 2 - math.pi / 2
		local button = Theme.button(panel, {
			Size = UDim2.fromOffset(BUTTON, BUTTON),
			Position = UDim2.new(
				0.5,
				math.cos(angle) * RADIUS - BUTTON / 2,
				0.5,
				math.sin(angle) * RADIUS - BUTTON / 2
			),
			Text = ("%d\n%s"):format(i, emote.label),
			TextSize = 13,
		})
		button.Activated:Connect(function()
			play(emote.id)
		end)
	end

	remotes.on("RoleAssigned", function(payload)
		role = payload.role
		if not Emotes.canPlay(role) then
			panel.Visible = false
		end
	end)

	local function setOpen(open: boolean)
		if open and not Emotes.canPlay(role) then
			return
		end
		panel.Visible = open
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		-- G (not B — B is Shop). DPadUp on gamepad.
		if input.KeyCode == Enum.KeyCode.G or input.KeyCode == Enum.KeyCode.DPadUp then
			setOpen(not panel.Visible)
			return
		end
		-- Number keys are a shortcut for players who don't want the wheel at all.
		if panel.Visible then
			local digit = tonumber(string.match(input.KeyCode.Name, "^%a*(%d)$") or "")
			if digit and Emotes.Catalog[digit] then
				play(Emotes.Catalog[digit].id)
			elseif input.KeyCode == Enum.KeyCode.Escape then
				panel.Visible = false
			end
		end
	end)

	return {
		open = function()
			setOpen(true)
		end,
		toggle = function()
			setOpen(not panel.Visible)
		end,
	}
end

return EmoteWheel
