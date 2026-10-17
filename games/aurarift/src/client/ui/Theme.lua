--!strict
--[[
	Theme — the palette and the type this game's interface shares.

	Every colour and every font the HUD and the roller draw with lives here,
	so two files written a day apart still look like one screen. The base
	tokens come from `Forge.UI.theme`; what is added is what this game needs
	beyond them: a gem cyan the base palette does not carry, two surface
	shades for depth, and the rarity spine.

	Rarity is read from Content rather than copied. The reveal frame, the
	announce stroke and the index preview all resolve through the same two
	functions, so a tier can never be two colours -- which is exactly how the
	"legendary" of one screen stopped matching the "legendary" of another in
	an earlier build of this repository.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Content = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Content"))

local UI = Forge.UI

local FALLBACK = Color3.fromRGB(168, 172, 184)

local Theme = {
	color = {
		bg = UI.theme.color.bg,
		panel = UI.theme.color.panel,
		panelAlt = UI.theme.color.panelAlt,
		stroke = UI.theme.color.stroke,
		text = UI.theme.color.text,
		textDim = UI.theme.color.textDim,
		accent = UI.theme.color.accent,
		gold = UI.theme.color.gold,
		danger = UI.theme.color.danger,
		good = UI.theme.color.good,
		gem = Color3.fromRGB(110, 240, 255),
		violet = Color3.fromRGB(186, 118, 255),
		sunken = Color3.fromRGB(20, 18, 24),
	},
	font = {
		title = UI.theme.font.title,
		body = UI.theme.font.body,
		bold = UI.theme.font.bold,
		mono = UI.theme.font.mono,
	},
	--: Spacing, radii and text sizes are the engine's, re-exported under one
	--: name so a UI file requires one module, not two that can disagree.
	space = UI.theme.space,
	radius = UI.theme.radius,
	text = UI.theme.text,
}

--: An order that is not in Content -- a truncated payload, a first sync
--: before any draw -- resolves to the common grey rather than erroring.
function Theme.rarityColor(order: number?): Color3
	local rarity = Content.rarityByOrder(order or 1)
	return if rarity then rarity.color else FALLBACK
end

function Theme.rarityName(order: number?): string
	local rarity = Content.rarityByOrder(order or 1)
	return if rarity then rarity.name else "RIFT"
end

return Theme
