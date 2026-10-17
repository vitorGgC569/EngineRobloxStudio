--!strict
--[[
	CatchCard — the reveal.

	The whole loop pays off here, so this gets the ones that matter: the
	species' name in title type, the rarity as the card's spine and its
	frame, the weight, value and xp as three equal cells, and one loud
	pill when it is new or a personal best.

	The card takes over the middle of the screen for a moment and then gets
	out of the way. Fights for the crate come later; the fish already went.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local UI = Forge.UI

local Skin = require(script.Parent.Skin)

local audio = require(script.Parent.Parent.audio)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Format = require(Shared.Format)
local FishCatalog = require(Shared.FishCatalog)

local CatchCard = {}

local T = UI.theme
local gui: ScreenGui? = nil

local function rarityColor(id: string): Color3
	for _, tier in FishCatalog.rarities do
		if tier.id == id then
			return tier.color
		end
	end
	return T.color.text
end

local function mutationColor(id: string): Color3?
	for _, mutation in Config.mutations do
		if mutation.id == id and id ~= "normal" then
			return mutation.color
		end
	end
	return nil
end

function CatchCard.hide()
	if gui then
		gui:Destroy()
	end
	gui = nil
end

local function statColumn(parent: Instance, x: number, caption: string, value: string, color: Color3)
	local cell = UI.panel(parent, {
		size = UDim2.fromOffset(124, 54),
		pos = UDim2.fromOffset(x, 122),
		color = T.color.panelAlt,
		transparency = 0.3,
		radius = T.radius.md,
	})
	UI.label(cell, caption, {
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.fromOffset(8, 4),
		frameSize = UDim2.new(1, -16, 0, 14),
	})
	UI.label(cell, value, {
		font = T.font.mono,
		size = T.text.lg,
		color = color,
		pos = UDim2.fromOffset(8, 20),
		frameSize = UDim2.new(1, -16, 0, 26),
	})
end

function CatchCard.show(payload: any)
	CatchCard.hide()

	gui = UI.mount("TideboundCatch", { displayOrder = 40 })
	local tier = rarityColor(payload.rarity)
	local mutation = mutationColor(payload.mutation)

	local card = UI.panel(gui, {
		name = "Card",
		size = UDim2.fromOffset(430, 320),
		pos = UDim2.fromScale(0.5, 0.46),
		anchor = Vector2.new(0.5, 0.5),
		color = T.color.panel,
		strokeColor = mutation or tier,
	})
	Skin.wash(card, T.color.panelAlt:Lerp(T.color.panel, 0.55), T.color.panel)
	Skin.strip(card, mutation or tier, { size = UDim2.new(1, -40, 0, 3), pos = UDim2.fromOffset(26, 2) })

	--: The spine: rarity bleeds down the left edge of the card.
	local spine = Instance.new("Frame")
	spine.Name = "Spine"
	spine.BackgroundColor3 = mutation or tier
	spine.BorderSizePixel = 0
	spine.Size = UDim2.new(0, 10, 1, 0)
	spine.Parent = card

	local glow = Instance.new("ImageLabel")
	glow.Image = "rbxasset://textures/particles/sparkles_main.dds"
	glow.ImageTransparency = 0.25
	glow.BackgroundTransparency = 1
	glow.Size = UDim2.fromOffset(300, 300)
	glow.Position = UDim2.fromScale(0.8, 0.1)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.ImageColor3 = mutation or tier
	glow.Parent = card

	--: The swatch repeats the frame's colour at text scale, so the line
	--: still reads as a rarity even where the stroke is faint.
	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.BackgroundColor3 = mutation or tier
	swatch.BorderSizePixel = 0
	swatch.Size = UDim2.fromOffset(10, 10)
	swatch.Position = UDim2.fromOffset(28, 21)
	swatch.ZIndex = 2
	swatch.Parent = card
	UI.corner(swatch, 3)

	UI.label(card, string.upper(payload.rarityName) .. (mutation and ("  --  " .. string.upper(payload.mutationName)) or ""), {
		name = "Rarity",
		font = T.font.bold,
		size = T.text.sm,
		color = mutation or tier,
		pos = UDim2.fromOffset(44, 18),
		frameSize = UDim2.new(1, -72, 0, 16),
	})

	UI.label(card, payload.name, {
		name = "Species",
		font = T.font.title,
		size = T.text.xl,
		color = T.color.text,
		pos = UDim2.fromOffset(28, 38),
		frameSize = UDim2.new(1, -56, 0, 36),
	})

	local tag = if payload.isNew then "NEW SPECIES"
		elseif payload.isRecord then "PERSONAL BEST"
		else if payload.perfect then "CLEAN CATCH" else nil
	if tag then
		Skin.chip(card, tag, {
			name = "Tag",
			size = UDim2.fromOffset(150, 22),
			pos = UDim2.fromOffset(28, 76),
			color = if payload.isNew then T.color.gold else T.color.accent,
			transparency = 0.15,
			textColor = T.color.bg,
		})
	end

	statColumn(card, 24, "WEIGHT", string.format("%.2f kg", payload.weightKg), T.color.text)
	statColumn(card, 154, "VALUE", Format.money(payload.value), T.color.gold)
	statColumn(card, 284, "XP", "+" .. tostring(payload.xp), T.color.accent)

	UI.label(card, payload.blurb or "", {
		name = "Blurb",
		size = T.text.sm,
		color = T.color.textDim,
		wrap = true,
		pos = UDim2.fromOffset(28, 186),
		frameSize = UDim2.new(1, -56, 0, 36),
	})

	local crateLine = if payload.stored
		then string.format("In the crate  %d/%d", payload.crateCount, payload.crateCap)
		else "Crate full -- released (the bestiary still counts it)"
	UI.label(card, crateLine, {
		name = "Crate",
		size = T.text.xs,
		color = if payload.stored then T.color.textDim else T.color.warning,
		pos = UDim2.fromOffset(28, 230),
		frameSize = UDim2.new(1, -56, 0, 14),
	})

	local close = UI.button(card, "KEEL IT", {
		name = "Close",
		size = UDim2.new(1, -56, 0, 34),
		pos = UDim2.fromOffset(28, 262),
		color = T.color.panelAlt,
		onClick = CatchCard.hide,
	})
	close.TextSize = T.text.sm

	--: The entrance: a short scale-up, so the card lands instead of blinking.
	card.Size = UDim2.fromOffset(400, 296)
	local target = UDim2.fromOffset(430, 320)
	TweenService:Create(card, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = target,
	}):Play()

	--: The card's own cue, pitched up with rarity, and a stinger for the
	--: tiers worth standing up for. The world-level feedback around the card
	--: (shake, splash, floating value) is `client/effects.luau`, listening
	--: to the same CatchResult broadcast.
	local tierEntry = FishCatalog.rarityById[payload.rarity]
	local order = tierEntry and tierEntry.order or 1
	audio.sfx("tidebound.catch", { pitch = 0.85 + 0.03 * order })
	if order >= 4 then
		audio.sfx("tidebound.fanfare")
		glow.ImageTransparency = 0.7
		TweenService:Create(glow, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			ImageTransparency = 0.25,
		}):Play()
	end

	task.delay(9, function()
		if gui and card.Parent then
			CatchCard.hide()
		end
	end)
end

return CatchCard
