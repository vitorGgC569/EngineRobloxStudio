--!strict
-- Interface: the screens this game's systems imply, bound to those systems.
--
-- Laid out by the screen templates and checked across the device matrix before
-- this file existed. Bound here, because a screen that displays nothing is a
-- panel: it passes every layout check and tells the player nothing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldKit = require(ReplicatedStorage.WorldKit)
local TokenData = require(ReplicatedStorage.Shared.TokenData)
local CoreLoop = require(ReplicatedStorage.Shared.CoreLoop)

local tokens = WorldKit.Tokens.define(TokenData)
local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local SCREENS = { "hud", "settings", "upgrade_tree" }

local Interface = {}

--- The always-on readout. One number that moves when the player acts is most of
--- what "the game is responding" feels like, and it is the first thing missing
--- when a HUD is only laid out.
local hud = WorldKit.Ui.screen(gui, "HUD", { enabled = true })
local bar = WorldKit.Ui.stack(tokens, hud, "horizontal", {
	anchor = Vector2.new(0.5, 0),
	position = UDim2.fromScale(0.5, 0.02),
})

local balance = WorldKit.Ui.value(tokens, bar, "cash", "0")
local progress = WorldKit.Ui.value(tokens, bar, "next", CoreLoop[1] or "play")

--- The server owns the number; the client reads it. A client that keeps its own
--- balance disagrees with the ledger the moment anything is spent, and it
--- always disagrees in the player's favour on screen.
local function bind()
	local function refresh()
		local amount = player:GetAttribute("cash")
		if amount ~= nil then
			local label = balance:FindFirstChildWhichIsA("TextLabel", true)
			if label then
				label.Text = tostring(math.floor(amount))
			end
		end
	end
	player:GetAttributeChangedSignal("cash"):Connect(refresh)
	refresh()
end
bind()

--- One screen per template, hidden until asked for, and each one carrying its
--- empty state. The first session is the one where every list is empty, and a
--- screen only designed populated is the one a new player sees broken.
function Interface.build(name: string): ScreenGui
	local screen = WorldKit.Ui.screen(gui, name, { enabled = false })
	local panel = WorldKit.Ui.panel(tokens, screen)
	WorldKit.Ui.text(tokens, panel, "title", name)

	if name == "hud" then
		for index, step in ipairs(CoreLoop) do
			WorldKit.Ui.text(tokens, panel, "body", index .. ". " .. step)
		end
	elseif name == "upgrade_tree" then
		WorldKit.Ui.text(tokens, panel, "body", "Build on a pad to raise your income.")
	else
		WorldKit.Ui.text(tokens, panel, "body", "Nothing here yet.")
	end
	return screen
end

for _, name in ipairs(SCREENS) do
	Interface.build(name)
end

-- Audited rather than assumed. `Ui.audit` reports text below the legibility
-- distance the token set declares, which is the failure nobody sees on a
-- desktop monitor and every phone player sees immediately.
for _, problem in ipairs(WorldKit.Ui.audit(gui)) do
	warn("[probe-roles] ui: " .. problem)
end

return Interface
