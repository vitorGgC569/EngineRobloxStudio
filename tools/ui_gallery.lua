-- Render the HUD components on their own, without running a game.
--
-- Iterating a HUD by rebuilding the place, restarting Studio, starting Play
-- Solo and capturing takes minutes and pays the client relay's twenty-second
-- window on every read. Composition does not converge at that cadence -- two
-- attempts at the shelf and the meter missed, and the reason was the loop, not
-- the components.
--
-- This runs in edit context through `bridge.exec`: it builds a gallery into
-- CoreGui, which renders in the viewport immediately and is thrown away on the
-- next run. No place rebuild, no Play Solo, no waiting.
--
-- The gallery is also the honest way to look at a component: on a real HUD a
-- chip sits over whatever the camera happens to see, and "does this read" gets
-- answered by the background rather than by the design. Here they sit on a
-- neutral field, at the sizes they actually ship at.

local CoreGui = game:GetService("CoreGui")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local existing = CoreGui:FindFirstChild("RQEUiGallery")
if existing then
	existing:Destroy()
end

local worldKit = ReplicatedStorage:FindFirstChild("WorldKit")
	or ServerStorage:FindFirstChild("WorldKit")
if worldKit == nil then
	return { ok = false, reason = "WorldKit is not in this place; open a built game" }
end

local WorldKit = require(worldKit)
local tokenData = ReplicatedStorage:FindFirstChild("Shared")
	and ReplicatedStorage.Shared:FindFirstChild("TokenData")
if tokenData == nil then
	return { ok = false, reason = "no TokenData; the gallery draws in the game's own palette" }
end

local tokens = WorldKit.Tokens.define(require(tokenData))
local Ui = WorldKit.Ui

local screen = Instance.new("ScreenGui")
screen.Name = "RQEUiGallery"
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 5000
screen.Parent = CoreGui

-- A neutral field, mid-value. Not black and not white: a component that only
-- reads on one of those has not been tested, it has been flattered.
local field = Instance.new("Frame")
field.Name = "Field"
field.Size = UDim2.fromScale(1, 1)
field.BackgroundColor3 = tokens:color("ground")
field.BorderSizePixel = 0
field.Parent = screen

local column = Ui.stack(tokens, field, "column", {
	name = "Gallery",
	anchor = Vector2.new(0, 0),
	position = UDim2.fromOffset(40, 40),
	size = UDim2.fromOffset(0, 0),
	gap = "loose",
})
column.AutomaticSize = Enum.AutomaticSize.XY

local function heading(text: string)
	Ui.text(tokens, column, "caption", text, { role = "neutralLight", weight = "bold" })
end

-- The shelf as the HUD actually assembles it.
heading("shelf + chips -- the top bar")
local shelf = Ui.shelf(tokens, column, { name = "Shelf", gap = "tight" })
Ui.chip(tokens, shelf, { name = "cash", icon = "currency", value = "1,240", step = "title" })
Ui.chip(tokens, shelf, { name = "wave", icon = "wave", value = "7", step = "title" })
Ui.chip(tokens, shelf, { name = "integrity", icon = "integrity", value = "62", step = "title" })
Ui.chip(tokens, shelf, { name = "tier", icon = "tier", value = "Tier 3", step = "title" })

-- Meters at the three states their colour is supposed to distinguish.
heading("meter -- healthy, warning, critical")
local meters = Ui.stack(tokens, column, "row", {
	name = "Meters", size = UDim2.fromOffset(0, 0), gap = "base" })
meters.AutomaticSize = Enum.AutomaticSize.XY
meters.BackgroundTransparency = 1
for _, fraction in ipairs({ 0.82, 0.35, 0.12 }) do
	local meter = Ui.meter(tokens, meters, {
		size = UDim2.fromOffset(200, tokens:space("tight")),
		fraction = fraction,
	})
	Ui.meterSet(tokens, meter, fraction)
end

-- Icons at the sizes the goal names, so a glyph that smears at 20px shows it.
heading("icons at 16 / 24 / 32 / 48 px")
local sizes = Ui.stack(tokens, column, "row", {
	name = "Icons", size = UDim2.fromOffset(0, 0), gap = "base" })
sizes.AutomaticSize = Enum.AutomaticSize.XY
sizes.BackgroundTransparency = 1
for _, side in ipairs({ 16, 24, 32, 48 }) do
	local row = Ui.shelf(tokens, sizes, { name = "At" .. side, gap = "hair" })
	for _, kind in ipairs({ "currency", "wave", "integrity", "tier", "tower" }) do
		Ui.icon(tokens, row, kind, { iconSize = side })
	end
end

heading("buttons")
local buttons = Ui.stack(tokens, column, "row", {
	name = "Buttons", size = UDim2.fromOffset(0, 0), gap = "base" })
buttons.AutomaticSize = Enum.AutomaticSize.XY
buttons.BackgroundTransparency = 1
Ui.button(tokens, buttons, "Build tower")
Ui.button(tokens, buttons, "Upgrade")
Ui.button(tokens, buttons, "Close")

local problems = Ui.audit(screen)
return {
	ok = true,
	rendered = #column:GetDescendants(),
	auditProblems = problems,
	note = "gallery is in CoreGui and is replaced on every run; it does not "
		.. "touch the place and is not saved with it",
}
