--!strict
-- Daily login-reward popup. Appears when the server says today's reward is claimable,
-- shows the current streak and payout, and fires ClaimDaily on the button. Purely
-- presentational — the server decides eligibility and grants.
--
-- Registers with MenuState so CameraController releases mouse lock; without that the
-- cursor stays locked at screen centre and CLAIM is unclickable (same class of bug as
-- the first-time tutorial).

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Theme = require(script.Parent.Theme)
local MenuState = require(script.Parent.MenuState)

local Daily = {}

local function rewardText(reward: { coins: number, keys: number, xp: number }): string
	local parts = { ("%d coins"):format(reward.coins), ("%d XP"):format(reward.xp) }
	if reward.keys > 0 then
		table.insert(parts, ("%d key%s"):format(reward.keys, reward.keys == 1 and "" or "s"))
	end
	return table.concat(parts, "  •  ")
end

function Daily.start(remotes: any)
	local gui = Theme.screenGui("Daily", 90)

	-- Full-screen dimmer so the panel is the clear focus and MenuState has something
	-- visible to track for the whole modal, not just the floating card.
	local dimmer = Theme.frame(gui, {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.45,
		Visible = false,
		Active = true,
	})
	MenuState.track(dimmer)

	local panel = Theme.frame(dimmer, {
		Size = UDim2.new(0, 380, 0, 240),
		Position = UDim2.new(0.5, -190, 0.5, -120),
		BackgroundColor3 = Theme.Colors.Panel,
		Active = true,
	})
	Theme.corner(panel, 16)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.Colors.Gold
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = panel

	Theme.label(panel, {
		Size = UDim2.new(1, -24, 0, 34),
		Position = UDim2.new(0, 12, 0, 14),
		Text = "DAILY REWARD",
		TextSize = 26,
		Font = Theme.FontDisplay,
		TextColor3 = Theme.Colors.Gold,
	})
	local streakLabel = Theme.label(panel, {
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.new(0, 12, 0, 52),
		Text = "",
		TextSize = 16,
		TextColor3 = Theme.Colors.TextDim,
	})
	local rewardLabel = Theme.label(panel, {
		Size = UDim2.new(1, -24, 0, 40),
		Position = UDim2.new(0, 12, 0, 96),
		Text = "",
		TextSize = 20,
	})

	local claimButton = Theme.button(panel, {
		Size = UDim2.new(0, 200, 0, 46),
		Position = UDim2.new(0.5, -100, 1, -64),
		Text = "CLAIM",
		TextSize = 20,
		BackgroundColor3 = Theme.Colors.Gold,
		TextColor3 = Theme.Colors.Bg,
	})

	local function hide()
		TweenService:Create(panel, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play()
		task.delay(0.22, function()
			dimmer.Visible = false
			panel.BackgroundTransparency = 0
		end)
	end

	local shownFor: number? = nil
	local claiming = false

	local function claim()
		if claiming or not dimmer.Visible then
			return
		end
		claiming = true
		remotes.fire("ClaimDaily")
		claimButton.Text = "..."
		claimButton.Active = false
	end

	-- Activated works for mouse + touch; MouseButton1Click alone fails under lock edge cases.
	claimButton.Activated:Connect(claim)

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not dimmer.Visible or claiming then
			return
		end
		if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.Space then
			claim()
		elseif input.KeyCode == Enum.KeyCode.Escape then
			-- Allow dismiss without claim so the player is never soft-locked.
			hide()
		end
	end)

	remotes.on("DailyStatus", function(status)
		if status.claimable and status.reward then
			shownFor = status.streak
			claiming = false
			streakLabel.Text = ("Day %d streak"):format(status.streak)
			rewardLabel.Text = rewardText(status.reward)
			claimButton.Text = "CLAIM"
			claimButton.Active = true
			panel.BackgroundTransparency = 0
			dimmer.Visible = true
			Theme.fadeIn(panel, 0.25)
		elseif shownFor ~= nil then
			-- No longer claimable (just claimed) — close the popup.
			hide()
		end
	end)

	remotes.on("DailyClaimed", function(payload)
		rewardLabel.Text = ("Claimed! %s"):format(rewardText(payload.reward))
		claimButton.Text = "✓"
		task.delay(0.9, hide)
	end)

	return {}
end

return Daily
