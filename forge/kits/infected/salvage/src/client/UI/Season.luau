--!strict
-- Season-pass panel: a toggle button opening the tier track (free + premium rewards) with
-- claim buttons, current tier + XP bar, and a premium badge. Server pushes resolved
-- SeasonStatus; this renders it and fires ClaimSeasonTier.

local Theme = require(script.Parent.Theme)
local MenuState = require(script.Parent.MenuState)

local Season = {}

local function rewardText(r: { coins: number, keys: number, pzTokens: number }): string
	local parts = { ("%dc"):format(r.coins) }
	if r.keys > 0 then
		table.insert(parts, ("%dk"):format(r.keys))
	end
	if r.pzTokens > 0 then
		table.insert(parts, ("%d PZ"):format(r.pzTokens))
	end
	return table.concat(parts, " ")
end

local function claimCell(parent: Instance, x: number, label: string): TextButton
	return Theme.button(parent, {
		Size = UDim2.new(0, 150, 0, 30),
		Position = UDim2.new(0, x, 0.5, -15),
		Text = label,
		TextSize = 13,
	})
end

function Season.start(remotes: any)
	local gui = Theme.screenGui("Season", 11)

	local toggle = Theme.button(gui, {
		Size = UDim2.new(0, 120, 0, 40),
		Position = UDim2.new(0, 264, 1, -104),
		Text = "SEASON",
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
		Size = UDim2.new(0, 460, 0, 460),
		Position = UDim2.new(0.5, -230, 0.5, -230),
		BackgroundColor3 = Theme.Colors.Panel,
		Visible = false,
	})
	-- Releases the locked mouse while this panel is open.
	MenuState.track(panel)
	Theme.corner(panel, 14)
	Theme.gradient(panel, Theme.Colors.PanelLight, Theme.Colors.Panel, 90)
	Theme.stroke(panel, Color3.fromRGB(60, 64, 78), 1, 0.3)

	local header = Theme.label(panel, {
		Size = UDim2.new(1, -110, 0, 30),
		Position = UDim2.new(0, 12, 0, 10),
		Text = "SEASON PASS",
		TextSize = 22,
		Font = Theme.FontDisplay,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local premiumBadge = Theme.label(panel, {
		Size = UDim2.new(0, 90, 0, 24),
		Position = UDim2.new(1, -140, 0, 14),
		Text = "",
		TextSize = 13,
		TextColor3 = Theme.Colors.Gold,
	})
	local closeBtn = Theme.button(panel, {
		Size = UDim2.new(0, 32, 0, 32),
		Position = UDim2.new(1, -40, 0, 8),
		Text = "✕",
		TextSize = 16,
	})
	local xpBar = Theme.frame(panel, {
		Size = UDim2.new(1, -24, 0, 10),
		Position = UDim2.new(0, 12, 0, 46),
		BackgroundColor3 = Theme.Colors.Bg,
	})
	Theme.corner(xpBar, 5)
	local xpFill = Theme.frame(xpBar, {
		Size = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = Theme.Colors.Infected,
	})
	Theme.corner(xpFill, 5)

	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.new(1, -24, 1, -70)
	scroll.Position = UDim2.new(0, 12, 0, 62)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 6
	scroll.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local function render(status)
		xpFill.Size = UDim2.new(status.span > 0 and math.clamp(status.into / status.span, 0, 1) or 0, 0, 1, 0)
		header.Text = ("SEASON PASS — TIER %d"):format(status.tier)
		premiumBadge.Text = status.premium and "★ PREMIUM" or ""
		for _, child in scroll:GetChildren() do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end
		local anyClaimable = false
		for _, t in status.tiers do
			local row = Theme.frame(scroll, {
				Size = UDim2.new(1, 0, 0, 44),
				BackgroundColor3 = t.reached and Theme.Colors.PanelLight or Theme.Colors.Panel,
				LayoutOrder = t.tier,
			})
			Theme.corner(row, 8)
			Theme.label(row, {
				Size = UDim2.new(0, 44, 1, 0),
				Position = UDim2.new(0, 6, 0, 0),
				Text = tostring(t.tier),
				TextSize = 16,
				TextColor3 = t.reached and Theme.Colors.Gold or Theme.Colors.TextDim,
			})
			-- Free cell
			local freeBtn = claimCell(row, 56, ("FREE: %s"):format(rewardText(t.free)))
			if t.freeClaimed then
				freeBtn.Text = "✓ " .. rewardText(t.free)
				freeBtn.BackgroundColor3 = Theme.Colors.Panel
			elseif t.freeClaimable then
				anyClaimable = true
				freeBtn.BackgroundColor3 = Theme.Colors.Gold
				freeBtn.TextColor3 = Theme.Colors.Bg
				freeBtn.Activated:Connect(function()
					remotes.fire("ClaimSeasonTier", { tier = t.tier, track = "free" })
				end)
			end
			-- Premium cell
			local premBtn = claimCell(row, 214, ("VIP: %s"):format(rewardText(t.premium)))
			if t.premiumClaimed then
				premBtn.Text = "✓ " .. rewardText(t.premium)
				premBtn.BackgroundColor3 = Theme.Colors.Panel
			elseif t.premiumClaimable then
				anyClaimable = true
				premBtn.BackgroundColor3 = Theme.Colors.Survivor
				premBtn.TextColor3 = Theme.Colors.Bg
				premBtn.Activated:Connect(function()
					remotes.fire("ClaimSeasonTier", { tier = t.tier, track = "premium" })
				end)
			else
				premBtn.TextColor3 = Theme.Colors.TextDim
			end
		end
		pip.Visible = anyClaimable
	end

	toggle.Activated:Connect(function()
		panel.Visible = not panel.Visible
	end)
	closeBtn.Activated:Connect(function()
		panel.Visible = false
	end)
	remotes.on("SeasonStatus", render)

	return {}
end

return Season
