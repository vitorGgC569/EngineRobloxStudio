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
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local CoreLoop = require(ReplicatedStorage.Shared.CoreLoop)

local tokens = WorldKit.Tokens.define(TokenData)
local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local Interface = {}

-- Safe area, not screen edge. The top inset is where a phone puts its notch and
-- Roblox puts its own chrome, and a HUD pinned to 0,0 sits under both.
local inset = GuiService:GetGuiInset()

local hud = WorldKit.Ui.screen(gui, "HUD", { enabled = true })

--------------------------------------------------------------------- readouts

local top = WorldKit.Ui.stack(tokens, hud, "row", {
	name = "TopBar",
	anchor = Vector2.new(0.5, 0),
	position = UDim2.new(0.5, 0, 0, inset.Y + tokens:space("base")),
	size = UDim2.new(0, 0, 0, 0),
	gap = "loose",
})
top.AutomaticSize = Enum.AutomaticSize.XY
top.BackgroundTransparency = 1

--- One readout, bound to a player attribute the server writes.
---
--- Returns the label so a caller can flash it: a number that changes without
--- announcing itself is a number a player misses while looking elsewhere.
local function readout(caption: string, attribute: string, fallback: string, icon: string?): TextLabel
	local group = WorldKit.Ui.value(tokens, top, caption, fallback, { name = caption, icon = icon })
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
		objectiveText.Text = CoreLoop[math.min(2, #CoreLoop)] or "defend"
	end
end)

--------------------------------------------------------------------- screens

--- One screen per template, hidden until asked for, each carrying its empty
--- state. The first session is the one where every list is empty, and a screen
--- designed only populated is the one a new player sees broken.
function Interface.build(name: string): ScreenGui
	local screen = WorldKit.Ui.screen(gui, name, { enabled = false })
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

local SCREENS = { "hud", "settings", "inventory", "upgrade_tree" }
for _, name in ipairs(SCREENS) do
	Interface.build(name)
end

-- Audited rather than assumed. `Ui.audit` reports text below the legibility
-- distance the token set declares -- the failure nobody sees on a desktop
-- monitor and every phone player sees immediately.
for _, problem in ipairs(WorldKit.Ui.audit(gui)) do
	warn("[brickfarm2] ui: " .. problem)
end

print(string.format("[brickfarm2] interface: %d readouts, %d screens",
	4, #SCREENS))

return Interface
