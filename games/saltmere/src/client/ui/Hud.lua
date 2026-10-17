--!strict
-- Saltmere HUD. StateSync and Tide repaint the labels. Buttons only send intents.

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Content = require(Shared:WaitForChild("Content"))

local UI = Forge.UI
local Net = Forge.Net

local Hud = {}

local GRADES = { "coarse", "fine", "flake", "smoked" }
local ROLES = { "raker", "grader", "watch" }

local PAD = 8
local GAP = 4
local WIDE_ROW = 36
local NARROW_ROW = 44
local TITLE = 20
local PHASE_H = 24
local BAR_H = 12
local STAT_H = 18
local PAN_INFO = 18
local PAN_BTN = 44
local PAN_GAP = 2
local PAN_ROW = PAN_INFO + PAN_BTN + PAN_GAP
local WIDE_MIN_X = 1100
local EDGE = 12

local function rgb(channels: { number }): Color3
	return Color3.fromRGB(channels[1] or 0, channels[2] or 0, channels[3] or 0)
end

-- Theme keys are the ones UI/init.lua actually stores. Timber is pulled toward
-- tar so a panel reads as dark timber on the tar ground; buttons stay on timber.
local function applySaltworksTheme()
	local tar = rgb(Config.colors.tar)
	local timber = rgb(Config.colors.timber)
	local salt = rgb(Config.colors.salt)
	local brine = rgb(Config.colors.brine)
	local copper = rgb(Config.colors.copper)
	local foam = rgb(Config.colors.foam)

	local color = UI.theme.color
	color.bg = tar
	color.panel = timber:Lerp(tar, 0.45)
	color.panelAlt = timber
	color.stroke = copper
	color.text = salt
	color.textDim = foam
	color.accent = brine
	color.gold = copper
end

local function num(value: any): number
	if type(value) == "number" and value == value and value > -1e12 and value < 1e12 then
		return value
	end
	return 0
end

local function whole(value: any): number
	return math.floor(num(value))
end

-- Current phase length. A numeric Config.tide entry is that length; a list would be summed.
local function phaseLength(phase: string): number
	local tide = Config.tide :: { [string]: any }
	local length = tide[phase]
	if type(length) == "number" then
		return length
	end
	if type(length) == "table" then
		local sum = 0
		for _, part in length :: { any } do
			if type(part) == "number" then
				sum += part
			end
		end
		return sum
	end
	return 0
end

local function tideColor(phase: string): Color3
	if phase == "harvest" then
		return UI.theme.color.gold
	elseif phase == "spoil" then
		return UI.theme.color.danger
	elseif phase == "flood" then
		return UI.theme.color.accent
	end
	return UI.theme.color.textDim
end

local function tideHeight(): number
	return PAD * 2 + PHASE_H + BAR_H + STAT_H + STAT_H + GAP * 3
end

local function marketHeight(row: number): number
	local n = #GRADES + 1
	return PAD * 2 + TITLE + n * row + n * GAP
end

local function worksHeight(row: number): number
	local n = math.ceil(#Config.upgrades / 2) + 2
	return PAD * 2 + TITLE + n * row + n * GAP
end

local function pansHeight(): number
	local n = #Config.pans
	return PAD * 2 + TITLE + n * PAN_ROW + n * GAP
end

local function crewHeight(row: number, count: number): number
	if count <= 0 then
		return 0
	end
	return PAD * 2 + TITLE + count * row + count * GAP
end

local root: ScreenGui? = nil
local scroller: ScrollingFrame? = nil
local wide = true
local rowHeight = WIDE_ROW
local mounted = false
local latest: any = nil
local tideSeen = false
local crewSignature = ""
local rakerCount = 0

local tidePanel: GuiObject
local marketPanel: GuiObject
local pansPanel: GuiObject
local worksPanel: GuiObject
local crewPanel: GuiObject
local crewBody: Frame
local phaseLabel: TextLabel
local cashLabel: TextLabel
local prestigeLabel: TextLabel
local lifetimeLabel: TextLabel
local needLabel: TextLabel
local tideBar: any

local trackedRows: { Frame } = {}
local restingText: { [TextButton]: Color3 } = {}

type SaltRow = {
	grade: string,
	amount: TextLabel,
	price: TextLabel,
	sellOne: TextButton,
	sellAll: TextButton,
}

type PanRow = {
	id: string,
	info: TextLabel,
	claim: TextButton,
	collect: TextButton,
	upgrade: TextButton,
}

local saltRows: { SaltRow } = {}
local panRows: { PanRow } = {}
local upgradeButtons: { [string]: TextButton } = {}
local upgradeMax: { [string]: number } = {}
local hireButtons: { [string]: TextButton } = {}
local assignButtons: { [string]: { [string]: TextButton } } = {}

local function send(name: string, payload: { [string]: any })
	Net.send(name, payload)
end

-- Active hides a button that cannot apply. MouseButton1Click can still arrive,
-- so the handler sends only while Active is true.
local function setActive(button: TextButton, active: boolean)
	button.Active = active
	local rest = restingText[button]
	if rest then
		button.TextColor3 = if active then rest else UI.theme.color.textDim
	end
	button.BackgroundTransparency = if active then 0 else 0.45
end

local function wire(
	parent: Instance,
	text: string,
	order: number,
	size: UDim2,
	action: () -> (),
	options: { name: string?, color: Color3?, textColor: Color3?, textSize: number? }?
): TextButton
	local extra = options or {}
	local button: TextButton
	button = UI.button(parent, text, {
		name = extra.name,
		size = size,
		color = extra.color,
		textColor = extra.textColor,
		textSize = extra.textSize or UI.theme.text.xs,
		onClick = function()
			if button.Active then
				action()
			end
		end,
	})
	button.LayoutOrder = order
	button.TextTruncate = Enum.TextTruncate.AtEnd
	restingText[button] = button.TextColor3
	return button
end

local function section(parent: Instance, text: string, order: number): TextLabel
	local label = UI.label(parent, text, {
		name = "Title",
		size = UI.theme.text.sm,
		font = UI.theme.font.bold,
		color = UI.theme.color.textDim,
		frameSize = UDim2.new(1, 0, 0, TITLE),
		rich = false,
	})
	label.LayoutOrder = order
	return label
end

local function field(
	parent: Instance,
	text: string,
	order: number,
	size: UDim2,
	color: Color3?,
	align: Enum.TextXAlignment?
): TextLabel
	local label = UI.label(parent, text, {
		size = UI.theme.text.xs,
		color = color,
		align = align,
		frameSize = size,
		rich = false,
	})
	label.LayoutOrder = order
	label.TextTruncate = Enum.TextTruncate.AtEnd
	return label
end

local function bodyOf(panel: GuiObject): Frame
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(PAD, PAD)
	body.Size = UDim2.new(1, -PAD * 2, 1, -PAD * 2)
	body.Parent = panel
	UI.list(body, { gap = GAP })
	return body
end

local function panelOf(screen: ScreenGui, name: string, order: number): (GuiObject, Frame)
	local panel = UI.panel(screen, {
		name = name,
		size = UDim2.fromOffset(320, 120),
		transparency = 0,
		radius = UI.theme.radius.sm,
	})
	panel.ClipsDescendants = true
	panel.LayoutOrder = order
	return panel, bodyOf(panel)
end

local function track(frame: Frame): Frame
	table.insert(trackedRows, frame)
	return frame
end

local function hrow(parent: Instance, order: number, name: string?, gap: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name or "Row"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, rowHeight)
	frame.LayoutOrder = order
	frame.Parent = parent
	UI.list(frame, {
		horizontal = true,
		gap = gap or GAP,
		vAlign = Enum.VerticalAlignment.Center,
	})
	return track(frame)
end

local function resizeRows()
	local alive: { Frame } = {}
	for _, frame in trackedRows do
		if frame.Parent then
			frame.Size = UDim2.new(1, 0, 0, rowHeight)
			table.insert(alive, frame)
		end
	end
	trackedRows = alive
end

local function releaseDeadButtons()
	local drop: { TextButton } = {}
	for button in restingText do
		if button.Parent == nil then
			table.insert(drop, button)
		end
	end
	for _, button in drop do
		restingText[button] = nil
	end
end

local function saltAmount(grade: string): number
	if type(latest) ~= "table" or type(latest.salt) ~= "table" then
		return 0
	end
	return math.max(0, whole(latest.salt[grade]))
end

local function priceText(grade: string): string
	if type(latest) ~= "table" or type(latest.prices) ~= "table" then
		return "—"
	end
	local price = latest.prices[grade]
	if type(price) ~= "number" then
		return "—"
	end
	return tostring(math.max(0, whole(price)))
end

type PanView = {
	owned: boolean,
	level: number,
	brine: number,
	ready: boolean,
}

local function panView(id: string): PanView
	local pans = if type(latest) == "table" then latest.pans else nil
	local pan = if type(pans) == "table" then (pans :: any)[id] else nil
	if type(pan) ~= "table" then
		return { owned = false, level = 0, brine = 0, ready = false }
	end
	return {
		owned = pan.owned == true,
		level = math.max(0, whole(pan.level)),
		brine = math.max(0, num(pan.brine)),
		ready = pan.ready == true,
	}
end

local function upgradeLevel(id: string): number
	if type(latest) ~= "table" or type(latest.upgrades) ~= "table" then
		return 0
	end
	return math.max(0, whole(latest.upgrades[id]))
end

local function paintBar(color: Color3)
	tideBar.fill.BackgroundColor3 = color
	local gradient = tideBar.fill:FindFirstChildOfClass("UIGradient")
	if gradient then
		gradient.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.22), color)
	end
end

local function topOffset(): number
	local inset = GuiService:GetGuiInset()
	return math.max(inset.Y, 36) + 8
end

local function viewport(): Vector2
	local screen = root
	if screen then
		local size = screen.AbsoluteSize
		if size.X >= 50 and size.Y >= 50 then
			return size
		end
	end
	local camera = workspace.CurrentCamera
	if camera then
		local view = camera.ViewportSize
		if view.X >= 50 and view.Y >= 50 then
			return view
		end
	end
	return Vector2.new(1280, 720)
end

local function worksBottom(top: number, row: number): number
	return top + tideHeight() + 8 + marketHeight(row) + 8 + worksHeight(row)
end

local function pansNeedStack(bottom: number): boolean
	return topOffset() + pansHeight() + bottom > viewport().Y
end

local function useStack(size: Vector2): boolean
	if size.X < WIDE_MIN_X then
		return true
	end
	local top = topOffset()
	local bottom = if UserInputService.TouchEnabled then 88 else EDGE
	if pansNeedStack(bottom) then
		return true
	end
	return worksBottom(top, WIDE_ROW) > size.Y - EDGE
end

local function dock(panel: GuiObject, order: number, height: number)
	local holder = scroller
	if not holder then
		return
	end
	panel.Parent = holder
	panel.AnchorPoint = Vector2.zero
	panel.Position = UDim2.fromOffset(0, 0)
	panel.Size = UDim2.new(1, -8, 0, height)
	panel.LayoutOrder = order
	panel.Visible = true
end

local function syncCrew()
	local screen = root
	local holder = scroller
	if not screen or not holder then
		return
	end
	local height = crewHeight(rowHeight, rakerCount)
	crewPanel.Visible = rakerCount > 0
	if wide then
		local bottom = if UserInputService.TouchEnabled then 88 else EDGE
		crewPanel.Parent = screen
		crewPanel.AnchorPoint = Vector2.new(0, 1)
		crewPanel.Position = UDim2.new(0.33, 0, 1, -bottom)
		crewPanel.Size = UDim2.new(0.32, 0, 0, height)
	else
		crewPanel.Parent = holder
		crewPanel.AnchorPoint = Vector2.zero
		crewPanel.Position = UDim2.fromOffset(0, 0)
		crewPanel.Size = UDim2.new(1, -8, 0, height)
		crewPanel.LayoutOrder = 5
	end
end

local hintLabel: TextLabel? = nil

local function hasOpenedWorks(): boolean
	if type(latest) ~= "table" then
		return false
	end
	local quests = latest.quests
	if type(quests) == "table" and quests.collected == true then
		return true
	end
	local salt = latest.salt
	if type(salt) ~= "table" then
		return false
	end
	for _, grade in GRADES do
		local amount = salt[grade]
		if type(amount) == "number" and amount > 0 then
			return true
		end
	end
	return false
end

local function applyLayout()
	local screen = root
	local holder = scroller
	if not screen or not holder then
		return
	end
	local size = viewport()
	local top = topOffset()
	local stack = useStack(size)
	wide = not stack
	rowHeight = if wide then WIDE_ROW else NARROW_ROW
	resizeRows()

	local bottom = if UserInputService.TouchEnabled then 88 else EDGE
	if wide then
		holder.Visible = false
		tidePanel.Parent = screen
		tidePanel.AnchorPoint = Vector2.zero
		tidePanel.Position = UDim2.new(0, EDGE, 0, top)
		tidePanel.Size = UDim2.new(0.30, 0, 0, tideHeight())

		marketPanel.Parent = screen
		marketPanel.AnchorPoint = Vector2.zero
		marketPanel.Position = UDim2.new(0, EDGE, 0, top + tideHeight() + 8)
		marketPanel.Size = UDim2.new(0.30, 0, 0, marketHeight(rowHeight))

		worksPanel.Parent = screen
		worksPanel.AnchorPoint = Vector2.zero
		worksPanel.Position = UDim2.new(0, EDGE, 0, top + tideHeight() + 8 + marketHeight(rowHeight) + 8)
		worksPanel.Size = UDim2.new(0.30, 0, 0, worksHeight(rowHeight))

		pansPanel.Parent = screen
		pansPanel.AnchorPoint = Vector2.new(1, 1)
		pansPanel.Position = UDim2.new(1, -EDGE, 1, -bottom)
		pansPanel.Size = UDim2.new(0.30, 0, 0, pansHeight())
		pansPanel.Visible = true
		tidePanel.Visible = true
		marketPanel.Visible = true
		worksPanel.Visible = true
	else
		holder.Visible = true
		holder.Position = UDim2.new(0, 8, 0, top)
		holder.Size = UDim2.new(1, -16, 1, -(top + 8))
		dock(tidePanel, 1, tideHeight())
		dock(marketPanel, 2, marketHeight(rowHeight))
		dock(pansPanel, 3, pansHeight())
		dock(worksPanel, 4, worksHeight(rowHeight))
	end
	local open = hasOpenedWorks()
	marketPanel.Visible = open
	worksPanel.Visible = open
	pansPanel.Visible = open
	if hintLabel then
		hintLabel.Visible = not open
	end
	syncCrew()
end

local function paintAssignments(crew: any)
	local assigned: { [string]: string } = {}
	if type(crew) == "table" then
		for _, member in crew :: { any } do
			if type(member) == "table" and type(member.id) == "string" and type(member.panId) == "string" then
				assigned[member.id] = member.panId
			end
		end
	end
	for crewId, buttons in assignButtons do
		local chosen = assigned[crewId]
		for panId, button in buttons do
			button.TextColor3 = if panId == chosen then UI.theme.color.gold else UI.theme.color.text
		end
	end
end

local function rakerIds(crew: any): { string }
	local ids: { string } = {}
	if type(crew) ~= "table" then
		return ids
	end
	for _, member in crew :: { any } do
		if type(member) == "table" and member.role == "raker" and type(member.id) == "string" then
			table.insert(ids, member.id)
		end
	end
	table.sort(ids)
	return ids
end

local function rebuildCrew(crew: any)
	local ids = rakerIds(crew)
	local key = table.concat(ids, ",")
	rakerCount = #ids
	if key == crewSignature then
		paintAssignments(crew)
		return
	end
	crewSignature = key
	assignButtons = {}
	for _, child in crewBody:GetChildren() do
		if child:IsA("GuiObject") and child.Name == "Assign" then
			child:Destroy()
		end
	end
	for index, crewId in ids do
		local line = hrow(crewBody, index + 1, "Assign", 2)
		field(line, crewId, 1, UDim2.new(0.18, 0, 1, 0))
		local buttons: { [string]: TextButton } = {}
		for panIndex, spec in Config.pans do
			local panId = spec.id
			local button = wire(line, panId, panIndex + 1, UDim2.new(0.13, -2, 1, 0), function()
				send("AssignCrew", { crewId = crewId, panId = panId })
			end, {
				name = "Assign_" .. crewId .. "_" .. panId,
				textSize = UI.theme.text.xs,
			})
			buttons[panId] = button
		end
		assignButtons[crewId] = buttons
	end
	resizeRows()
	releaseDeadButtons()
	paintAssignments(crew)
end

local function refreshProfile()
	if type(latest) ~= "table" then
		return
	end

	cashLabel.Text = string.format("Cash  %d", whole(latest.cash))
	prestigeLabel.Text = string.format("Prestige  %d", whole(latest.prestige))
	lifetimeLabel.Text = string.format("Lifetime  %d", whole(latest.lifetime))
	if type(latest.prestigeNeed) == "number" then
		needLabel.Text = string.format("Need  %d", whole(latest.prestigeNeed))
	else
		needLabel.Text = "Need  —"
	end

	for _, entry in saltRows do
		local amount = saltAmount(entry.grade)
		entry.amount.Text = tostring(amount)
		entry.price.Text = priceText(entry.grade)
		local canSell = amount >= 1
		setActive(entry.sellOne, canSell)
		setActive(entry.sellAll, canSell)
	end

	local cap = Config.panUpgrade.maxLevel
	for _, entry in panRows do
		local pan = panView(entry.id)
		local owned = if pan.owned then "owned" else "not owned"
		local ready = if pan.ready then "ready" else "not ready"
		entry.info.Text = string.format(
			"%s  %s  L%d  brine %.1f  %s",
			entry.id,
			owned,
			pan.level,
			pan.brine,
			ready
		)
		entry.info.TextColor3 = if pan.ready
			then UI.theme.color.gold
			elseif pan.owned then UI.theme.color.text
			else UI.theme.color.textDim
		setActive(entry.claim, not pan.owned)
		setActive(entry.collect, pan.owned and pan.ready)
		setActive(entry.upgrade, pan.owned and pan.level < cap)
	end

	for _, spec in Config.upgrades do
		local button = upgradeButtons[spec.id]
		local level = upgradeLevel(spec.id)
		local maxLevel = upgradeMax[spec.id] or spec.maxLevel
		button.Text = string.format("%s  %d/%d", Content.lookup("upgrade", spec.id), level, maxLevel)
	end

	local crew = latest.crew
	local hired = 0
	if type(crew) == "table" then
		for _, member in crew :: { any } do
			if type(member) == "table" then
				hired += 1
			end
		end
	end
	local crewOpen = hired < Config.crew.max
	for _, role in ROLES do
		setActive(hireButtons[role], crewOpen)
	end

	rebuildCrew(crew)
	syncCrew()
	applyLayout()
end

local function refreshTide(payload: any)
	local phase = if type(payload.phase) == "string" then payload.phase else ""
	local remaining = num(payload.remaining)
	local total = phaseLength(phase)
	local name = if phase ~= "" then Content.lookup("phase", phase) else "Tide"
	phaseLabel.TextColor3 = if phase == "harvest" then UI.theme.color.gold else UI.theme.color.text
	paintBar(tideColor(phase))

	if total > 0 then
		local shownTotal = math.max(1, math.floor(total + 0.5))
		local left = math.clamp(math.ceil(remaining), 0, shownTotal)
		local text = string.format("%s    %d / %d", name, left, shownTotal)
		if type(payload.tideIndex) == "number" then
			text ..= string.format("    tide %d", math.floor(payload.tideIndex))
		end
		phaseLabel.Text = text
		local alpha = math.clamp(remaining / total, 0, 1)
		if tideSeen then
			tideBar:set(alpha)
		else
			tideBar:setInstant(alpha)
			tideSeen = true
		end
	else
		phaseLabel.Text = name
		tideBar:setInstant(0)
	end
end

local function buildTide(screen: ScreenGui)
	local panel, body = panelOf(screen, "Tide", 1)
	tidePanel = panel

	phaseLabel = UI.label(body, "Tide", {
		name = "Phase",
		size = UI.theme.text.lg,
		font = UI.theme.font.title,
		frameSize = UDim2.new(1, 0, 0, PHASE_H),
		rich = false,
	})
	phaseLabel.LayoutOrder = 1
	phaseLabel.TextTruncate = Enum.TextTruncate.AtEnd

	tideBar = UI.bar(body, {
		name = "TideBar",
		color = UI.theme.color.accent,
		background = UI.theme.color.bg,
		size = UDim2.new(1, 0, 0, BAR_H),
	})
	tideBar.holder.LayoutOrder = 2
	tideBar:setInstant(0)

	local function statPair(order: number): (TextLabel, TextLabel)
		local line = Instance.new("Frame")
		line.Name = "Stats"
		line.BackgroundTransparency = 1
		line.Size = UDim2.new(1, 0, 0, STAT_H)
		line.LayoutOrder = order
		line.Parent = body
		UI.list(line, {
			horizontal = true,
			gap = 8,
			vAlign = Enum.VerticalAlignment.Center,
		})
		local left = field(line, "", 1, UDim2.new(0.5, -4, 1, 0))
		local right = field(line, "", 2, UDim2.new(0.5, -4, 1, 0))
		left.TextSize = UI.theme.text.sm
		right.TextSize = UI.theme.text.sm
		return left, right
	end

	cashLabel, prestigeLabel = statPair(3)
	lifetimeLabel, needLabel = statPair(4)
	cashLabel.Text = "Cash  —"
	prestigeLabel.Text = "Prestige  —"
	lifetimeLabel.Text = "Lifetime  —"
	needLabel.Text = "Need  —"
	cashLabel.FontFace = UI.theme.font.bold
	cashLabel.TextColor3 = UI.theme.color.gold
	needLabel.TextColor3 = UI.theme.color.textDim
end

local function buildMarket(screen: ScreenGui)
	local panel, body = panelOf(screen, "Quay", 2)
	marketPanel = panel
	section(body, "Quay", 1)

	for index, grade in GRADES do
		local line = hrow(body, index + 1, "Salt")
		field(line, Content.lookup("grade", grade), 1, UDim2.new(0.26, 0, 1, 0))
		local amount = field(line, "—", 2, UDim2.new(0.13, 0, 1, 0), nil, Enum.TextXAlignment.Right)
		local price = field(line, "—", 3, UDim2.new(0.15, 0, 1, 0), UI.theme.color.gold, Enum.TextXAlignment.Right)
		local sellOne = wire(line, "Sell 1", 4, UDim2.new(0.21, -4, 1, 0), function()
			send("Sell", { grade = grade, amount = 1 })
		end, {
			name = "Sell1_" .. grade,
			color = UI.theme.color.gold,
			textColor = UI.theme.color.bg,
		})
		local sellAll = wire(line, "Sell all", 5, UDim2.new(0.21, -4, 1, 0), function()
			local amountNow = math.clamp(saltAmount(grade), 1, 10000)
			send("Sell", { grade = grade, amount = amountNow })
		end, {
			name = "SellAll_" .. grade,
			color = UI.theme.color.gold,
			textColor = UI.theme.color.bg,
		})
		setActive(sellOne, false)
		setActive(sellAll, false)
		table.insert(saltRows, {
			grade = grade,
			amount = amount,
			price = price,
			sellOne = sellOne,
			sellAll = sellAll,
		})
	end

	local refine = hrow(body, #GRADES + 2, "Refine")
	wire(refine, "Refine fine", 1, UDim2.new(0.5, -2, 1, 0), function()
		send("Refine", { kind = "fine", amount = 1 })
	end, { name = "RefineFine", textSize = UI.theme.text.sm })
	wire(refine, "Refine smoked", 2, UDim2.new(0.5, -2, 1, 0), function()
		send("Refine", { kind = "smoked", amount = 1 })
	end, { name = "RefineSmoked", textSize = UI.theme.text.sm })
end

local function buildPans(screen: ScreenGui)
	local panel, body = panelOf(screen, "Pans", 3)
	pansPanel = panel
	section(body, "Pans", 1)

	for index, spec in Config.pans do
		local panId = spec.id
		local block = Instance.new("Frame")
		block.Name = panId
		block.BackgroundTransparency = 1
		block.Size = UDim2.new(1, 0, 0, PAN_ROW)
		block.LayoutOrder = index + 1
		block.Parent = body
		UI.list(block, { gap = PAN_GAP })

		local info = field(block, panId, 1, UDim2.new(1, 0, 0, PAN_INFO))

		local buttons = Instance.new("Frame")
		buttons.Name = "Buttons"
		buttons.BackgroundTransparency = 1
		buttons.Size = UDim2.new(1, 0, 0, PAN_BTN)
		buttons.LayoutOrder = 2
		buttons.Parent = block
		UI.list(buttons, {
			horizontal = true,
			gap = GAP,
			vAlign = Enum.VerticalAlignment.Center,
		})

		local claim = wire(buttons, "Claim", 1, UDim2.new(0.33, -4, 1, 0), function()
			send("ClaimPan", { panId = panId })
		end, { name = "Claim_" .. panId, textSize = UI.theme.text.sm })
		local collect = wire(buttons, "Collect", 2, UDim2.new(0.33, -4, 1, 0), function()
			send("CollectPan", { panId = panId })
		end, {
			name = "Collect_" .. panId,
			color = UI.theme.color.accent,
			textSize = UI.theme.text.sm,
		})
		local upgrade = wire(buttons, "Upgrade", 3, UDim2.new(0.33, -4, 1, 0), function()
			send("UpgradePan", { panId = panId })
		end, { name = "Upgrade_" .. panId, textSize = UI.theme.text.sm })
		setActive(claim, false)
		setActive(collect, false)
		setActive(upgrade, false)

		table.insert(panRows, {
			id = panId,
			info = info,
			claim = claim,
			collect = collect,
			upgrade = upgrade,
		})
	end
end

local function buildWorks(screen: ScreenGui)
	local panel, body = panelOf(screen, "Works", 4)
	worksPanel = panel
	section(body, "Works", 1)

	local rows: { Frame } = {}
	for index, spec in Config.upgrades do
		local rowIndex = math.ceil(index / 2)
		local line = rows[rowIndex]
		if not line then
			line = hrow(body, rowIndex + 1, "Upgrade")
			rows[rowIndex] = line
		end
		local id = spec.id
		local column = ((index - 1) % 2) + 1
		local button = wire(line, Content.lookup("upgrade", id), column, UDim2.new(0.5, -2, 1, 0), function()
			send("BuyUpgrade", { upgradeId = id })
		end, { name = "Buy_" .. id, textSize = UI.theme.text.xs })
		upgradeButtons[id] = button
		upgradeMax[id] = spec.maxLevel
	end

	local hireOrder = math.ceil(#Config.upgrades / 2) + 2
	local hire = hrow(body, hireOrder, "Hire")
	for index, role in ROLES do
		local button = wire(hire, Content.lookup("role", role), index, UDim2.new(0.33, -3, 1, 0), function()
			send("Hire", { roleId = role })
		end, { name = "Hire_" .. role, textSize = UI.theme.text.sm })
		hireButtons[role] = button
	end

	local prestigeRow = hrow(body, hireOrder + 1, "Prestige")
	wire(prestigeRow, "Prestige", 1, UDim2.new(1, 0, 1, 0), function()
		send("Prestige", { confirm = true })
	end, {
		name = "Prestige",
		color = UI.theme.color.gold,
		textColor = UI.theme.color.bg,
		textSize = UI.theme.text.sm,
	})
end

local function buildCrew(screen: ScreenGui)
	local panel, body = panelOf(screen, "Crew", 5)
	crewPanel = panel
	crewBody = body
	section(body, "Assign rakers", 1)
	crewPanel.Visible = false
end

function Hud.mount(screen: ScreenGui)
	if mounted then
		return
	end
	applySaltworksTheme()

	root = screen
	hintLabel = UI.label(screen, "Rake the white pan, sell at the stall, and catch the other houses on the board.", {
		frameSize = UDim2.new(0.5, 0, 0, 36),
		pos = UDim2.new(0.25, 0, 0.08, 0),
		align = Enum.TextXAlignment.Center,
		wrap = true,
		textSize = 18,
	})
	if hintLabel then
		hintLabel.Name = "FirstHint"
		hintLabel.TextSize = 18
	end
	local holder = Instance.new("ScrollingFrame")
	holder.Name = "NarrowStack"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.CanvasSize = UDim2.fromOffset(0, 0)
	holder.AutomaticCanvasSize = Enum.AutomaticSize.Y
	holder.ScrollingDirection = Enum.ScrollingDirection.Y
	holder.ScrollBarThickness = 6
	holder.ScrollBarImageColor3 = UI.theme.color.accent
	holder.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	holder.Visible = false
	holder.Parent = screen
	UI.list(holder, { gap = 8 })
	local tail = Instance.new("Frame")
	tail.Name = "Tail"
	tail.BackgroundTransparency = 1
	tail.Size = UDim2.new(1, 0, 0, 72)
	tail.LayoutOrder = 100
	tail.Parent = holder
	scroller = holder

	buildTide(screen)
	buildMarket(screen)
	buildPans(screen)
	buildWorks(screen)
	buildCrew(screen)

	mounted = true
	applyLayout()
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout)
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(applyLayout)
	end
end

function Hud.applyProfile(payload: any)
	if not mounted or type(payload) ~= "table" then
		return
	end
	latest = payload
	refreshProfile()
end

function Hud.applyTide(payload: any)
	if not mounted or type(payload) ~= "table" then
		return
	end
	refreshTide(payload)
end

return Hud
