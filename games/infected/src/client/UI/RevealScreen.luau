--!strict
-- End-of-round reveal: a clip-ready sequence — the winner banner pops in, then the
-- Patient Zero is dramatically unmasked, then MVP + your earnings. Built to be
-- screenshotted/shared.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local RevealScreen = {}

function RevealScreen.start(remotes: any)
	local gui = Theme.screenGui("RevealScreen", 6)

	local overlay = Theme.frame(gui, {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		Visible = false,
	})

	local panel = Theme.frame(overlay, {
		Size = UDim2.new(0, 540, 0, 360),
		Position = UDim2.new(0.5, -270, 0.5, -180),
		BackgroundTransparency = 0.05,
	})
	Theme.corner(panel, 16)

	local winnerLabel = Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 50),
		Position = UDim2.new(0, 0, 0, 20),
		Text = "",
		TextSize = 36,
		Font = Theme.FontDisplay,
	})

	-- Patient Zero unmask block.
	Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.new(0, 0, 0, 84),
		Text = "PATIENT ZERO WAS",
		TextSize = 13,
		TextColor3 = Theme.Colors.TextDim,
	})
	local pzName = Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.new(0, 0, 0, 104),
		Text = "",
		TextSize = 30,
		TextColor3 = Theme.Colors.Infected,
		TextTransparency = 1,
	})

	local mvpLabel = Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0, 0, 0, 158),
		Text = "",
		TextSize = 18,
		TextColor3 = Theme.Colors.Gold,
		TextTransparency = 1,
	})
	local survivorsLabel = Theme.label(panel, {
		Size = UDim2.new(1, -60, 0, 90),
		Position = UDim2.new(0, 30, 0, 192),
		Text = "",
		TextSize = 15,
		Font = Theme.FontLight,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Theme.Colors.TextDim,
	})
	local earningsLabel = Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.new(0, 0, 1, -46),
		Text = "",
		TextSize = 18,
		TextColor3 = Theme.Colors.Gold,
	})

	local function fadeInText(label: TextLabel, delay: number)
		label.TextTransparency = 1
		task.delay(delay, function()
			TweenService:Create(label, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				TextTransparency = 0,
			}):Play()
		end)
	end

	remotes.on("RevealScreen", function(payload)
		if payload.winner == "SURVIVORS" then
			winnerLabel.Text = "SURVIVORS WIN"
			winnerLabel.TextColor3 = Theme.Colors.Survivor
		elseif payload.winner == "INFECTED" then
			winnerLabel.Text = "THE INFECTION WINS"
			winnerLabel.TextColor3 = Theme.Colors.Infected
		else
			winnerLabel.Text = "ROUND OVER"
			winnerLabel.TextColor3 = Theme.Colors.Text
		end

		-- Winner banner pops; the rest fades in staggered for drama.
		winnerLabel.TextTransparency = 0
		panel.Size = UDim2.new(0, 480, 0, 360)
		overlay.Visible = true
		TweenService:Create(panel, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 540, 0, 360),
		}):Play()

		pzName.Text = payload.patientZeroName or "?"
		fadeInText(pzName, 0.7)

		if payload.mvpName then
			mvpLabel.Text = ("★ MVP: %s (%d coins)"):format(payload.mvpName, payload.mvpCoins or 0)
			fadeInText(mvpLabel, 1.2)
		else
			mvpLabel.Text = ""
		end

		local survivors = payload.survivors or {}
		survivorsLabel.Text = #survivors > 0 and ("Survived: " .. table.concat(survivors, ", "))
			or "Nobody survived."

		local myEarnings = payload.earnings and payload.earnings[tostring(Players.LocalPlayer.UserId)]
		earningsLabel.Text = myEarnings and ("+%d coins this round"):format(myEarnings) or ""
	end)

	remotes.on("RoundState", function(state)
		if state.state ~= "ROUND_END" then
			overlay.Visible = false
		end
	end)

	return {}
end

return RevealScreen
