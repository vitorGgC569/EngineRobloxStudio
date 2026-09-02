--!strict
-- Global leaderboard panel: a toggle button opening top-Wins and top-Conversions lists
-- pushed from the server. Read-only; refreshes whenever a Leaderboard broadcast arrives.

local Theme = require(script.Parent.Theme)
local MenuState = require(script.Parent.MenuState)

local Leaderboard = {}

local function column(parent: Instance, xScale: number, title: string): Frame
	local col = Instance.new("Frame")
	col.BackgroundTransparency = 1
	col.Size = UDim2.new(0.5, -18, 1, -48)
	col.Position = UDim2.new(xScale, xScale == 0 and 12 or 6, 0, 44)
	col.Parent = parent
	Theme.label(col, {
		Size = UDim2.new(1, 0, 0, 22),
		Text = title,
		TextSize = 15,
		TextColor3 = Theme.Colors.Gold,
	})
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 1, -26)
	holder.Position = UDim2.new(0, 0, 0, 26)
	holder.Parent = col
	listLayout.Parent = holder
	return holder
end

local function fill(holder: Frame, list: { any })
	for _, child in holder:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	if #list == 0 then
		Theme.label(holder, {
			Size = UDim2.new(1, 0, 0, 20),
			Text = "No entries yet",
			TextSize = 13,
			TextColor3 = Theme.Colors.TextDim,
			LayoutOrder = 1,
		})
		return
	end
	for rank, entry in list do
		Theme.label(holder, {
			Size = UDim2.new(1, 0, 0, 20),
			Text = ("%d.  %s — %s"):format(rank, entry.name, tostring(entry.value)),
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = rank == 1 and Theme.Colors.Gold or Theme.Colors.Text,
			LayoutOrder = rank,
		})
	end
end

function Leaderboard.start(remotes: any)
	local gui = Theme.screenGui("Leaderboard", 11)

	local toggle = Theme.button(gui, {
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.new(0, 138, 1, -104),
		Text = "RANKS",
		TextSize = 16,
	})

	local panel = Theme.frame(gui, {
		Size = UDim2.new(0, 500, 0, 380),
		Position = UDim2.new(0.5, -250, 0.5, -190),
		BackgroundColor3 = Theme.Colors.Panel,
		Visible = false,
	})
	-- Releases the locked mouse while this panel is open.
	MenuState.track(panel)
	Theme.corner(panel, 14)
	Theme.gradient(panel, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	Theme.stroke(panel, Color3.fromRGB(60, 64, 78), 1, 0.3)
	Theme.label(panel, {
		Size = UDim2.new(1, -24, 0, 30),
		Position = UDim2.new(0, 12, 0, 10),
		Text = "GLOBAL LEADERBOARD",
		TextSize = 22,
		Font = Theme.FontDisplay,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local closeBtn = Theme.button(panel, {
		Size = UDim2.new(0, 32, 0, 32),
		Position = UDim2.new(1, -40, 0, 8),
		Text = "✕",
		TextSize = 16,
	})

	local winsHolder = column(panel, 0, "MOST WINS")
	local convHolder = column(panel, 0.5, "MOST INFECTIONS")

	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
	closeBtn.Activated:Connect(function()
		panel.Visible = false
	end)

	remotes.on("Leaderboard", function(payload)
		fill(winsHolder, payload.wins or {})
		fill(convHolder, payload.conversions or {})
	end)

	return {}
end

return Leaderboard
