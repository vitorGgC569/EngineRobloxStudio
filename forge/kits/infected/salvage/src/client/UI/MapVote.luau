--!strict
-- Intermission map vote: three buttons, highlights your pick.
-- MenuState unlocks mouse lock so the vote buttons are actually clickable on desktop.

local Theme = require(script.Parent.Theme)
local MenuState = require(script.Parent.MenuState)

local MapVote = {}

-- Fallback labels shown for the instant before the server's payload arrives. These are the
-- three maps in rotation; the server relabels the buttons from its own list either way.
local MAP_NAMES = { "Abandoned Mall", "Suburbia", "Research Facility" }

function MapVote.start(remotes: any)
	local gui = Theme.screenGui("MapVote", 3)

	local panel = Theme.frame(gui, {
		Size = UDim2.new(0, 560, 0, 92),
		Position = UDim2.new(0.5, -280, 1, -116),
		BackgroundTransparency = 0.2,
		Visible = false,
		Active = true,
	})
	MenuState.track(panel)
	Theme.corner(panel, 12)
	Theme.gradient(panel, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	Theme.stroke(panel, Color3.fromRGB(60, 64, 78), 1, 0.35)
	Theme.label(panel, {
		Size = UDim2.new(1, 0, 0, 22),
		Position = UDim2.new(0, 0, 0, 6),
		Text = "VOTE NEXT MAP",
		TextSize = 14,
		Font = Theme.FontDisplay,
		TextColor3 = Theme.Colors.Gold,
	})

	local buttons = {}
	for i = 1, 3 do
		local button = Theme.button(panel, {
			Size = UDim2.new(0, 172, 0, 48),
			Position = UDim2.new(0, 8 + (i - 1) * 182, 0, 34),
			Text = MAP_NAMES[i] or ("Map " .. i),
			TextSize = 15,
		})
		button.Activated:Connect(function()
			remotes.fire("VoteMap", { mapIndex = i })
			for j, other in buttons do
				other.BackgroundColor3 = if j == i then Theme.Colors.Survivor else Theme.Colors.PanelLight
			end
		end)
		buttons[i] = button
	end

	-- The server offers 3 random maps each vote; relabel the buttons to those candidates.
	remotes.on("HordeUpdate", function(payload)
		if payload.mapVote then
			for i, button in buttons do
				local name = payload.mapVote[i]
				button.Visible = name ~= nil
				if name then
					button.Text = name
				end
			end
		end
	end)

	remotes.on("RoundState", function(state)
		panel.Visible = state.state == "INTERMISSION"
		if state.state == "INTERMISSION" then
			for _, button in buttons do
				button.BackgroundColor3 = Theme.Colors.PanelLight
			end
		end
	end)

	return {}
end

return MapVote
