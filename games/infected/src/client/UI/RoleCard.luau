--!strict
-- The private role reveal: a dramatic card only you see at round start,
-- plus the reveal screen at round end.

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local RoleCard = {}

function RoleCard.start(remotes: any)
	local gui = Theme.screenGui("RoleCard", 5)

	local card = Theme.frame(gui, {
		Size = UDim2.new(0, 420, 0, 140),
		Position = UDim2.new(0.5, -210, 0.35, 0),
		BackgroundTransparency = 1,
		Visible = false,
	})
	Theme.corner(card, 16)
	local cardStroke = Theme.stroke(card, Theme.Colors.PanelLight, 2, 0.2)
	local title = Theme.label(card, {
		Size = UDim2.new(1, 0, 0, 54),
		Position = UDim2.new(0, 0, 0, 22),
		Text = "",
		TextSize = 36,
		Font = Theme.FontDisplay,
	})
	local subtitle = Theme.label(card, {
		Size = UDim2.new(1, -40, 0, 44),
		Position = UDim2.new(0, 20, 0, 76),
		Text = "",
		TextSize = 15,
		Font = Theme.FontLight,
		TextColor3 = Theme.Colors.TextDim,
		TextWrapped = true,
	})

	local function show(titleText: string, subtitleText: string, color: Color3, holdSeconds: number)
		title.Text = titleText
		title.TextColor3 = color
		cardStroke.Color = color
		subtitle.Text = subtitleText
		card.BackgroundColor3 = Theme.Colors.Bg
		card.BackgroundTransparency = 0.15
		card.Visible = true
		card.Position = UDim2.new(0.5, -210, 0.30, 0)
		TweenService:Create(card, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, -210, 0.35, 0),
		}):Play()
		task.delay(holdSeconds, function()
			card.Visible = false
		end)
	end

	remotes.on("RoleAssigned", function(payload)
		if payload.lastStand then
			show(
				"LAST STAND",
				"You are the final survivor. Damage resist up, Minigun unlocked. Make it count.",
				Theme.Colors.Gold,
				4
			)
		elseif payload.role == "PATIENT_ZERO" then
			show(
				"YOU ARE INFECTED",
				"Nobody knows it's you. Throw knives with F. Every kill grows your horde. Stay hidden.",
				Theme.Colors.Infected,
				6
			)
		elseif payload.role == "SURVIVOR" then
			show(
				"SURVIVOR",
				"One of you is already infected. Trust no one. Survive until the timer ends.",
				Theme.Colors.Survivor,
				5
			)
		elseif payload.role == "ZOMBIE" then
			show(
				"INFECTED",
				"You're one of them now. Hunt the living. Click survivors up close to claw them.",
				Theme.Colors.Infected,
				4
			)
		end
	end)

	return {}
end

return RoleCard
