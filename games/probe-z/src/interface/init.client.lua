--!strict
-- Interface: the screens this game's systems imply.
--
-- Laid out by the screen templates and checked across the device matrix before
-- this file existed. Built with WorldKit.Ui so the spacing and type come from
-- the token set rather than from numbers chosen here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldKit = require(ReplicatedStorage.WorldKit)
local TokenData = require(ReplicatedStorage.Shared.TokenData)

local tokens = WorldKit.Tokens.define(TokenData)
local player = Players.LocalPlayer
local gui = player:WaitForChild("PlayerGui")

local SCREENS = { "hud", "settings", "upgrade_tree" }

local Interface = {}

--- One screen, hidden until something asks for it.
---
--- Every screen carries an empty state, because the first session is the one
--- where every list is empty and a screen only designed populated is a screen
--- the new player sees broken.
function Interface.build(name: string): ScreenGui
	local screen = WorldKit.Ui.screen(gui, name, { enabled = false })
	local panel = WorldKit.Ui.panel(tokens, screen)
	WorldKit.Ui.text(tokens, panel, "title", name)
	WorldKit.Ui.text(tokens, panel, "caption", "Nothing here yet.")
	return screen
end

for _, name in ipairs(SCREENS) do
	Interface.build(name)
end

return Interface
