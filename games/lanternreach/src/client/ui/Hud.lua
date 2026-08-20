--!strict
-- Hud — satchel, coin, level, quest tracker and the Keeper's conversation.
-- Built from UI widgets and theme tokens; no colour literals below.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local UI = Forge.UI
local Net = Forge.Net

local Hud = {}
Hud.state = {}

local widgets = {}

function Hud.init()
	local T = UI.theme
	local screen = UI.mount("LanternreachHud")

	-- ------------------------------------------------ satchel, bottom left
	local satchel = UI.panel(screen, {
		size = UDim2.fromOffset(260, 66),
		pos = UDim2.new(0, 18, 1, -84),
		transparency = 0.2,
	})

	widgets.carried = UI.label(satchel, "0 / 18 carried", {
		size = T.text.sm,
		frameSize = UDim2.new(1, -20, 0, 18),
		pos = UDim2.fromOffset(14, 8),
	})
	widgets.satchelBar = UI.bar(satchel, {
		color = T.color.accent,
		size = UDim2.fromOffset(232, 8),
		pos = UDim2.fromOffset(14, 28),
	})
	widgets.level = UI.label(satchel, "Level 1", {
		size = T.text.xs,
		color = T.color.textDim,
		frameSize = UDim2.new(1, -20, 0, 14),
		pos = UDim2.fromOffset(14, 42),
	})
	widgets.levelBar = UI.bar(satchel, {
		color = T.color.good,
		size = UDim2.fromOffset(232, 4),
		pos = UDim2.fromOffset(14, 56),
	})

	-- ------------------------------------------------------ coin, top right
	local purse = UI.panel(screen, {
		size = UDim2.fromOffset(150, 40),
		pos = UDim2.new(1, -168, 0, 18),
		transparency = 0.25,
	})
	widgets.coin = UI.label(purse, "0", {
		size = T.text.lg,
		color = T.color.gold,
		font = T.font.title,
		align = Enum.TextXAlignment.Right,
		frameSize = UDim2.new(1, -14, 1, 0),
	})

	-- ------------------------------------------------- quest log, top left
	local log = UI.panel(screen, {
		size = UDim2.fromOffset(280, 130),
		pos = UDim2.fromOffset(18, 18),
		transparency = 0.3,
	})
	UI.label(log, "Tonight", {
		size = T.text.sm,
		color = T.color.textDim,
		font = T.font.bold,
		frameSize = UDim2.new(1, -20, 0, 18),
		pos = UDim2.fromOffset(14, 6),
	})
	widgets.questList = Instance.new("Frame")
	widgets.questList.Size = UDim2.new(1, -24, 1, -32)
	widgets.questList.Position = UDim2.fromOffset(14, 26)
	widgets.questList.BackgroundTransparency = 1
	widgets.questList.Parent = log
	UI.list(widgets.questList, { gap = 4 })
	widgets.log = log

	-- -------------------------------------------------- dialogue, bottom
	local dialogue = UI.panel(screen, {
		size = UDim2.fromOffset(620, 190),
		pos = UDim2.new(0.5, -310, 1, -220),
		transparency = 0.08,
	})
	dialogue.Visible = false
	widgets.dialogue = dialogue

	widgets.speaker = UI.label(dialogue, "The Keeper", {
		size = T.text.sm,
		color = T.color.gold,
		font = T.font.bold,
		frameSize = UDim2.new(1, -32, 0, 18),
		pos = UDim2.fromOffset(18, 12),
	})
	widgets.dialogueText = UI.label(dialogue, "", {
		size = T.text.md,
		wrap = true,
		valign = Enum.TextYAlignment.Top,
		frameSize = UDim2.new(1, -36, 0, 56),
		pos = UDim2.fromOffset(18, 34),
	})
	widgets.choices = Instance.new("Frame")
	widgets.choices.Size = UDim2.new(1, -36, 0, 84)
	widgets.choices.Position = UDim2.fromOffset(18, 96)
	widgets.choices.BackgroundTransparency = 1
	widgets.choices.Parent = dialogue
	UI.list(widgets.choices, { gap = 4 })
end

function Hud.update(payload)
	for key, value in payload do
		Hud.state[key] = value
	end
	local T = UI.theme

	widgets.carried.Text = string.format("%d / %d carried", payload.carried or 0, payload.slots or 0)
	widgets.satchelBar:set((payload.slots or 1) > 0 and (payload.carried or 0) / payload.slots or 0)
	widgets.coin.Text = tostring(payload.coin or 0)
	widgets.level.Text = string.format("Level %d", payload.level or 1)
	widgets.levelBar:set(payload.progress or 0)

	-- Satchel bar turns amber as it fills: the pressure to walk home should be
	-- visible without reading a number.
	local fill = (payload.slots or 1) > 0 and (payload.carried or 0) / payload.slots or 0
	widgets.satchelBar.fill.BackgroundColor3 = fill > 0.85 and T.color.warning or T.color.accent

	for _, child in widgets.questList:GetChildren() do
		if child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	for index, entry in (payload.journal or {}) do
		local done = entry.fulfilled
		local objective = entry.objectives[1]
		local text = done and string.format("<b>%s</b> — return to the light", entry.name)
			or string.format("<b>%s</b>  %d/%d", entry.name, objective.progress, objective.target)
		local label = UI.label(widgets.questList, text, {
			size = T.text.xs,
			color = done and T.color.good or T.color.text,
			frameSize = UDim2.new(1, 0, 0, 16),
		})
		label.LayoutOrder = index
	end
end

-- Bound to the `journal` action, which is a key on desktop, a face button on a
-- gamepad and an on-screen button on a phone — none of which this file knows.
function Hud.toggleLog()
	widgets.log.Visible = not widgets.log.Visible
end

function Hud.showDialogue(payload)
	if not payload or payload.closed then
		widgets.dialogue.Visible = false
		return
	end

	widgets.dialogue.Visible = true
	widgets.dialogueText.Text = payload.text or ""

	for _, child in widgets.choices:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	for index, choice in (payload.choices or {}) do
		local button = UI.button(widgets.choices, choice.text, {
			size = UDim2.new(1, 0, 0, 24),
			textSize = UI.theme.text.sm,
			onClick = function()
				Net.send("DialogueChoice", { index = index })
			end,
		})
		button.TextXAlignment = Enum.TextXAlignment.Left
		button.LayoutOrder = index
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 10)
		padding.Parent = button
	end
end

function Hud.showQuests(payload)
	local T = UI.theme
	if #payload.offers == 0 then
		Hud.showDialogue({
			text = payload.turnedIn and #payload.turnedIn > 0
					and "Good. That is one less thing the water keeps."
				or "Nothing new tonight. The shelf is still open.",
			choices = {},
		})
		task.delay(2.5, function()
			widgets.dialogue.Visible = false
		end)
		return
	end

	local lines = {}
	for _, offer in payload.offers do
		table.insert(lines, offer.summary or offer.name)
	end

	widgets.dialogue.Visible = true
	widgets.dialogueText.Text = table.concat(lines, "\n")

	for _, child in widgets.choices:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	for index, offer in payload.offers do
		local button = UI.button(widgets.choices, "Take: " .. offer.name, {
			size = UDim2.new(1, 0, 0, 24),
			textSize = T.text.sm,
			onClick = function()
				Net.send("AcceptQuest", { quest = offer.id })
				widgets.dialogue.Visible = false
			end,
		})
		button.LayoutOrder = index
	end
end

return Hud
