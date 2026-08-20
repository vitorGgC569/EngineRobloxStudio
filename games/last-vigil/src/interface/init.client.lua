--!strict
-- Interface: a HUD bound to the systems, and screens that read them.
--
-- The version this replaces built one row with two labels and called it a HUD.
-- Before that it built nothing at all, because it passed "horizontal" to a
-- function that takes "row" and took the whole LocalScript down on its first
-- line -- so the game ran with no interface and the only symptom was an empty
-- screenshot.
--
-- What a HUD has to do, in the order a player needs it:
--
-- **Say what changed.** A number that moves when you act is most of what
-- "the game is responding" feels like. Every readout here is driven by an
-- attribute the server owns; the client never keeps its own copy, because a
-- client that does disagrees with the ledger the moment anything is spent, and
-- it always disagrees in the player's favour on screen.
--
-- **Say what is happening now, and nothing else.** Wave, integrity and currency
-- during a round; the result when the round ends. A HUD that shows everything
-- shows nothing.
--
-- **Survive the device it lands on.** Anchored to safe areas rather than to
-- screen edges, and sized in token steps rather than pixels, so a phone with a
-- notch and a desktop at 1440p both get a readable layout.
--
-- Every colour, size and spacing comes from the token set. A HUD that picks its
-- own is a second design system that drifts from the world's.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")

local WorldKit = require(ReplicatedStorage.WorldKit)
local GameKit = require(ReplicatedStorage.GameKit)
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local CoreLoop = require(ReplicatedStorage.Shared.CoreLoop)
local FeedbackConfig = require(ReplicatedStorage.Shared.FeedbackConfig)

local tokens = WorldKit.Tokens.define(TokenData)
local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Interface = {}

-- One semantic packet becomes one toast, one sound and an optional world burst.
-- The bind is client presentation only; GameKit.Feedback exposes no mutation
-- remote, and the presenter never trusts an asset id from the packet.
local feedbackPresenter = WorldKit.Feedback.presenter(tokens, gui, FeedbackConfig)
local feedbackConnection = GameKit.Feedback.bindClient(FeedbackConfig, function(payload)
	feedbackPresenter:present(payload)
end)
Interface.feedbackPresenter = feedbackPresenter
Interface.feedbackConnection = feedbackConnection

-- Safe area, not screen edge. The top inset is where a phone puts its notch and
-- Roblox puts its own chrome, and a HUD pinned to 0,0 sits under both.
local inset = GuiService:GetGuiInset()

local hud = WorldKit.Ui.screen(gui, "HUD", { enabled = true })

--------------------------------------------------------------------- readouts

-- A shelf, not four floating labels.
--
-- The readouts used to be drawn straight onto the scene: over a bright
-- sky the numbers vanished, over a dark wall the glyphs did, and four
-- separate elements at the same weight gave the eye nothing to land on
-- first. One contained surface is one thing to glance at.
local top = WorldKit.Ui.shelf(tokens, hud, {
	name = "TopBar",
	anchor = Vector2.new(0.5, 0),
	position = UDim2.new(0.5, 0, 0, inset.Y + tokens:space("base")),
	size = UDim2.new(0, 0, 0, 0),
	gap = "tight",
})

--- One readout, bound to a player attribute the server writes.
---
--- Returns the label so a caller can flash it: a number that changes without
--- announcing itself is a number a player misses while looking elsewhere.
local function readout(caption: string, attribute: string, fallback: string, icon: string?): TextLabel
	local group = WorldKit.Ui.chip(tokens, top, {
		name = caption, icon = icon, value = fallback,
		step = "title",
	})
	local label = group:FindFirstChild("Text", true)
	for _, child in ipairs(group:GetDescendants()) do
		if child:IsA("TextLabel") and child.Text == fallback then
			label = child
			break
		end
	end

	local function refresh()
		local value = player:GetAttribute(attribute)
		if value == nil or label == nil then
			return
		end
		local text = if type(value) == "number" then tostring(math.floor(value)) else tostring(value)
		if (label :: TextLabel).Text ~= text then
			(label :: TextLabel).Text = text
			-- The flash. Feedback for a change the player did not cause is what
			-- makes income legible; without it a rising number is wallpaper.
			WorldKit.Ui.animate(tokens, label, "quick", "standard", {
				TextTransparency = 0,
			})
		end
	end

	player:GetAttributeChangedSignal(attribute):Connect(refresh)
	refresh()
	return label :: TextLabel
end

readout("cash", "cash", "0", "currency")
readout("wave", "wave", "-", "wave")
readout("integrity", "integrity", "100", "integrity")
readout("tier", "nextTier", "-", "tier")

-- Integrity as a proportion as well as a number.
--
-- A bare 62 is only meaningful against a maximum the player has to
-- remember. A bar is the shape of the question they are actually asking,
-- and its colour carries the urgency faster than the digits do.
local integrityMeter = WorldKit.Ui.meter(tokens, hud, {
	name = "IntegrityMeter",
	anchor = Vector2.new(0.5, 0),
	-- Centred and wide enough to read as a bar. Left at the default it
	-- took its own 168px at a fixed offset and sat under the first chip
	-- instead of under the shelf.
	position = UDim2.new(0.5, 0, 0, inset.Y + tokens:space("base") * 4),
	size = UDim2.fromOffset(240, tokens:space("tight")),
	fraction = 1,
})
player:GetAttributeChangedSignal("integrity"):Connect(function()
	local value = tonumber(player:GetAttribute("integrity")) or 0
	WorldKit.Ui.meterSet(tokens, integrityMeter, value / 100)
end)

-- Narrow screens get a tighter bar.
--
-- Measured on a 760x940 capture, which is the first phone-width evidence
-- this HUD was ever looked at on: the four readouts reached the toast the
-- platform draws top-right, and a 375px phone has half again less room.
-- The gap and the glyphs both come down, so the bar keeps its hierarchy
-- instead of wrapping into two rows of unrelated numbers.
local layout = top:FindFirstChildOfClass("UIListLayout")
local function fit()
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local narrow = camera.ViewportSize.X < 820
	if layout ~= nil then
		-- Still a real gap. Tightening this to `tight` was the first
		-- attempt and it made the bar unreadable: the groups touched and
		-- the readouts ran together as "4940Tier3". Spacing was never
		-- what was crowding the bar -- the type size was.
		layout.Padding = UDim.new(0, tokens:space(narrow and "base" or "loose"))
	end
	local step = narrow and "body" or "title"
	for _, item in ipairs(top:GetDescendants()) do
		if item:GetAttribute("RQEIcon") ~= nil then
			local side = tokens:text(step)
			local frame = item :: Frame
			frame.Size = UDim2.fromOffset(side, side)
		elseif item:IsA("TextLabel") and item.Name == "Amount" then
			local label = item :: TextLabel
			label.TextSize = tokens:text(step)
		end
	end
end

if workspace.CurrentCamera ~= nil then
	workspace.CurrentCamera
		:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
end
fit()

-- Audited at the size it ended up, not the size it was designed at. An icon
-- that passes at 32px and fails at 20 is the failure the goal names, and it
-- only appears after `fit` has run.
for _, problem in ipairs(WorldKit.Ui.audit(gui)) do
	warn("[last-vigil] ui narrow: " .. problem)
end

--------------------------------------------------------- objective and result

-- What to do next, one line, bottom centre. A player who has to open a menu to
-- find out what the game wants has already stopped playing.
local objective = WorldKit.Ui.panel(tokens, hud, {
	name = "Objective",
	anchor = Vector2.new(0.5, 1),
	position = UDim2.new(0.5, 0, 1, -tokens:space("loose")),
	size = UDim2.new(0, 0, 0, 0),
})
objective.AutomaticSize = Enum.AutomaticSize.XY
local objectiveText = WorldKit.Ui.text(tokens, objective, "body", CoreLoop[1] or "play")
local sessionInstruction = CoreLoop[1] or "play"

-- Onboarding advances only after server-owned effects. Its server presenter
-- publishes this instruction; the client renders it and has no mutation path
-- back into the state machine.
local function refreshObjective()
	local instruction = player:GetAttribute("RQEOnboardingInstruction")
	local complete = player:GetAttribute("RQEOnboardingComplete") == true
	if not complete and type(instruction) == "string" and instruction ~= "" then
		objectiveText.Text = instruction
		objective:SetAttribute("RQEObjectiveSource", "onboarding")
	else
		objectiveText.Text = sessionInstruction
		objective:SetAttribute("RQEObjectiveSource", "session")
	end
end
player:GetAttributeChangedSignal("RQEOnboardingInstruction"):Connect(refreshObjective)
player:GetAttributeChangedSignal("RQEOnboardingComplete"):Connect(refreshObjective)
refreshObjective()

-- Victory and defeat, which every genre has and none of them can leave to text
-- in the output window.
local banner = WorldKit.Ui.panel(tokens, hud, {
	name = "Result",
	anchor = Vector2.new(0.5, 0.5),
	position = UDim2.fromScale(0.5, 0.42),
	size = UDim2.new(0, 0, 0, 0),
})
banner.AutomaticSize = Enum.AutomaticSize.XY
banner.Visible = false
local bannerText = WorldKit.Ui.text(tokens, banner, "display", "")

function Interface.announce(kind: string, message: string)
	bannerText.Text = message
	bannerText.TextColor3 = tokens:color(
		if kind == "victory" then "accentSuccess"
		elseif kind == "defeat" then "accentDanger"
		else "neutralLight")
	banner.Visible = true
	if kind ~= "victory" and kind ~= "defeat" then
		task.delay(2.5, function()
			banner.Visible = false
		end)
	end
end

-- The session tells the HUD, rather than the HUD polling it. One announcement
-- per event means the wave counter and the banner can never disagree about
-- which wave it is.
local events = ReplicatedStorage:FindFirstChild("RQEClientChannel")
player:GetAttributeChangedSignal("sessionState"):Connect(function()
	local state = player:GetAttribute("sessionState")
	if state == "VICTORY" then
		Interface.announce("victory", "Held")
	elseif state == "DEFEAT" then
		Interface.announce("defeat", "Fallen")
	elseif state == "ACTIVE" then
		sessionInstruction = CoreLoop[math.min(2, #CoreLoop)] or "defend"
		refreshObjective()
	end
end)

--------------------------------------------------------------------- screens

--- One screen per template, hidden until asked for, each carrying its empty
--- state. The first session is the one where every list is empty, and a screen
--- designed only populated is the one a new player sees broken.
function Interface.build(name: string): ScreenGui
	local screen = WorldKit.Ui.screen(gui, name, { enabled = false, displayOrder = 10 })
	local panel = WorldKit.Ui.panel(tokens, screen, {
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
	})
	WorldKit.Ui.text(tokens, panel, "title", name)

	if name == "hud" then
		for index, step in ipairs(CoreLoop) do
			WorldKit.Ui.text(tokens, panel, "body", index .. ". " .. step)
		end
	elseif name == "upgrade_tree" then
		WorldKit.Ui.text(tokens, panel, "body",
			"Build on a prepared foundation to raise your income.")
	else
		WorldKit.Ui.text(tokens, panel, "body", "Nothing here yet.")
	end

	-- Every screen closes. A screen with no way out is a screen a controller
	-- player is trapped in.
	local close = WorldKit.Ui.button(tokens, panel, "Close")
	close.Activated:Connect(function()
		screen.Enabled = false
	end)
	return screen
end

local SCREENS = { "hud", "settings", "upgrade_tree" }
local screens: { [string]: ScreenGui } = {}
for _, name in ipairs(SCREENS) do
	screens[name] = Interface.build(name)
end

-- A way in.
--
-- The screens above were built, wired and left unreachable: every one of
-- them is created with `Enabled = false` and nothing ever set it true. A
-- menu a player cannot open is the same as a menu nobody wrote, and it is
-- also why no capture of this game had a screen open in it.
--
-- Bottom right, one target, sized from the token scale so it stays within reach of a
-- thumb on a phone and does not swell on a desktop.
local opener = WorldKit.Ui.stack(tokens, hud, "column", {
	name = "Menu",
	anchor = Vector2.new(1, 1),
	position = UDim2.new(1, -tokens:space("base"), 1, -tokens:space("base")),
	size = UDim2.fromOffset(0, 0),
	gap = "tight",
})
opener.AutomaticSize = Enum.AutomaticSize.XY
opener.BackgroundTransparency = 1

for _, name in ipairs(SCREENS) do
	local screen = screens[name]
	if screen == nil then
		continue
	end
	local label = string.gsub(name, "_", " ")
	local button = WorldKit.Ui.button(tokens, opener, label)
	button.Activated:Connect(function()
		-- One at a time. Two overlapping panels is the state a player
		-- cannot get out of without knowing which close button is on top.
		for other, gui in pairs(screens) do
			gui.Enabled = other == name and not screen.Enabled
		end
	end)
end

--- Open a screen by name, for anything that is not a finger.
---
--- The capture tooling needs it: the goal asks for evidence with the UI
--- open, and driving a click through VirtualInputManager to get there is a
--- lot of machinery to prove a panel exists.
function Interface.open(name: string): boolean
	local screen = screens[name]
	if screen == nil then
		return false
	end
	for other, gui in pairs(screens) do
		gui.Enabled = other == name
	end
	return true
end

-- Reachable from the client bridge, which cannot require a LocalScript.
--
-- One BindableFunction per screen rather than one taking a name: the bridge
-- command that invokes these accepts a single `argument` and no array, so a
-- function keyed by name failed schema validation before it reached Studio.
-- A capture step that has to guess an encoding is one that quietly stops
-- producing evidence.
for _, name in ipairs(SCREENS) do
	local request = Instance.new("BindableFunction")
	request.Name = "RQEOpen_" .. name
	request.OnInvoke = function()
		return Interface.open(name)
	end
	request.Parent = gui

	-- And a way back out, for the same reason: a capture step that opens a
	-- screen has to be able to close it, or every later shot is taken
	-- through it.
	local closer = Instance.new("BindableFunction")
	closer.Name = "RQEClose_" .. name
	closer.OnInvoke = function()
		local screen = screens[name]
		if screen == nil then
			return false
		end
		screen.Enabled = false
		return true
	end
	closer.Parent = gui
end

-- Reachable from the client bridge, which cannot require a LocalScript.

-- Audited rather than assumed. `Ui.audit` reports text below the legibility
-- distance the token set declares -- the failure nobody sees on a desktop
-- monitor and every phone player sees immediately.
for _, problem in ipairs(WorldKit.Ui.audit(gui)) do
	warn("[last-vigil] ui: " .. problem)
end

print(string.format("[last-vigil] interface: %d readouts, %d screens",
	4, #SCREENS))

return Interface
