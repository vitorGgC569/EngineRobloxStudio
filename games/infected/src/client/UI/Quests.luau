--!strict
-- Quests panel: a toggle button that opens the daily/weekly quest list with progress bars
-- and claim buttons. Server pushes fully-resolved QuestStatus; this just renders it and
-- fires ClaimQuest. A pip on the toggle flags when something is claimable.

local Theme = require(script.Parent.Theme)
local MenuState = require(script.Parent.MenuState)

local Quests = {}

local function makeRow(
	parent: Instance,
	order: number
): { root: Frame, desc: TextLabel, bar: Frame, fill: Frame, claim: TextButton }
	local row = Theme.frame(parent, {
		Size = UDim2.new(1, 0, 0, 54),
		BackgroundColor3 = Theme.Colors.PanelLight,
		LayoutOrder = order,
	})
	Theme.corner(row, 8)
	local desc = Theme.label(row, {
		Size = UDim2.new(1, -110, 0, 22),
		Position = UDim2.new(0, 12, 0, 6),
		Text = "",
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local bar = Theme.frame(row, {
		Size = UDim2.new(1, -110, 0, 10),
		Position = UDim2.new(0, 12, 0, 34),
		BackgroundColor3 = Theme.Colors.Bg,
	})
	Theme.corner(bar, 5)
	local fill = Theme.frame(bar, {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Theme.Colors.Infected,
	})
	Theme.corner(fill, 5)
	local claim = Theme.button(row, {
		Size = UDim2.new(0, 88, 0, 38),
		Position = UDim2.new(1, -96, 0.5, -19),
		Text = "",
		TextSize = 14,
		Visible = false,
	})
	return { root = row, desc = desc, bar = bar, fill = fill, claim = claim }
end

function Quests.start(remotes: any)
	local gui = Theme.screenGui("Quests", 11)

	local toggle = Theme.button(gui, {
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.new(0, 12, 1, -104),
		Text = "QUESTS",
		TextSize = 16,
	})
	local pip = Theme.frame(toggle, {
		Size = UDim2.new(0, 12, 0, 12),
		Position = UDim2.new(1, -16, 0, 4),
		BackgroundColor3 = Theme.Colors.Gold,
		Visible = false,
	})
	Theme.corner(pip, 6)

	local panel = Theme.frame(gui, {
		Size = UDim2.new(0, 440, 0, 440),
		Position = UDim2.new(0.5, -220, 0.5, -220),
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
		Text = "QUESTS",
		TextSize = 24,
		Font = Theme.FontDisplay,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local closeBtn = Theme.button(panel, {
		Size = UDim2.new(0, 32, 0, 32),
		Position = UDim2.new(1, -40, 0, 8),
		Text = "✕",
		TextSize = 16,
	})

	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, -24, 1, -56)
	scroll.Position = UDim2.new(0, 12, 0, 48)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local function header(text: string, order: number)
		Theme.label(scroll, {
			Size = UDim2.new(1, 0, 0, 22),
			Text = text,
			TextSize = 16,
			TextColor3 = Theme.Colors.Gold,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = order,
		})
	end

	local function render(status)
		for _, child in scroll:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
		local anyClaimable = false
		local order = 0
		local function section(title: string, list: { any }, scope: string)
			order += 1
			header(title, order)
			for _, q in list do
				order += 1
				local row = makeRow(scroll, order)
				row.desc.Text = ("%s  (%d/%d)"):format(q.desc, q.progress, q.target)
				row.fill.Size = UDim2.new(math.clamp(q.progress / q.target, 0, 1), 0, 1, 0)
				if q.claimable then
					anyClaimable = true
					row.claim.Visible = true
					row.claim.Text = "CLAIM"
					row.claim.BackgroundColor3 = Theme.Colors.Gold
					row.claim.TextColor3 = Theme.Colors.Bg
					row.claim.Activated:Connect(function()
						remotes.fire("ClaimQuest", { scope = scope, questId = q.id })
						row.claim.Text = "..."
					end)
				elseif q.claimed then
					row.claim.Visible = true
					row.claim.Active = false
					row.claim.Text = "✓"
					row.claim.BackgroundColor3 = Theme.Colors.PanelLight
				end
			end
		end
		section("DAILY", status.daily or {}, "daily")
		section("WEEKLY", status.weekly or {}, "weekly")
		pip.Visible = anyClaimable
	end

	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
	closeBtn.Activated:Connect(function()
		panel.Visible = false
	end)

	remotes.on("QuestStatus", render)

	return {}
end

return Quests
