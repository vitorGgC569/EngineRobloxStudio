--!strict
--[[
	ReelUI — the fight, drawn.

	The math lives in Shared.ReelMath; this file is only the picture. The
	controller steps the state each frame and hands it here:

	  safe band: where the fish is pulling (the target)
	  marker:    where the player's tension is (the finger)
	  two bars:  how close the fish is to the boat, and how much line is left

	The chrome is part of the fight: the track's frame tightens when the
	pull sits inside the band, so the state is readable from the frame
	alone, and the hint under the bars warms to accent while the drag is
	in your hands.

	Built fresh on each bite and destroyed on each landing, because a fight
	that leaves its UI behind teaches players to distrust the screen.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local UI = Forge.UI

local Skin = require(script.Parent.Skin)

local audio = require(script.Parent.Parent.audio)

local Reel = {}

local T = UI.theme

local gui: ScreenGui? = nil
local root: GuiObject? = nil
local track: GuiObject? = nil
local trackStroke: UIStroke? = nil
local band: Frame? = nil
local marker: Frame? = nil
local progressBar: any = nil
local integrityBar: any = nil
local timerLabel: TextLabel? = nil
local hintLabel: TextLabel? = nil
local flash: Frame? = nil

function Reel.show()
	Reel.dismiss()

	gui = UI.mount("TideboundReel", { displayOrder = 30 })

	root = UI.panel(gui, {
		name = "Reel",
		size = UDim2.fromOffset(480, 190),
		pos = UDim2.new(0.5, 0, 1, -40),
		anchor = Vector2.new(0.5, 1),
		radius = T.radius.lg,
	})
	Skin.wash(root, T.color.panelAlt:Lerp(T.color.panel, 0.55), T.color.panel)
	Skin.strip(root, T.color.accent)

	UI.label(root, "SOMETHING IS PULLING", {
		name = "Title",
		font = T.font.title,
		size = T.text.sm,
		color = T.color.accent,
		pos = UDim2.fromOffset(18, 12),
		frameSize = UDim2.new(1, -36, 0, 18),
	})

	--: The track is the fight. The band is the fish; the marker is you.
	track = UI.panel(root, {
		name = "Track",
		size = UDim2.new(1, -36, 0, 34),
		pos = UDim2.fromOffset(18, 36),
		transparency = 0.3,
	})
	trackStroke = track:FindFirstChildOfClass("UIStroke")

	--: A hairline at dead centre: the neutral point the band drifts around.
	local centre = Instance.new("Frame")
	centre.Name = "Centre"
	centre.BackgroundColor3 = T.color.stroke
	centre.BackgroundTransparency = 0.55
	centre.BorderSizePixel = 0
	centre.Size = UDim2.new(0, 1, 1, -12)
	centre.Position = UDim2.fromScale(0.5, 0.5)
	centre.AnchorPoint = Vector2.new(0.5, 0.5)
	centre.ZIndex = 2
	centre.Parent = track

	band = Instance.new("Frame")
	band.Name = "Band"
	band.BackgroundColor3 = T.color.accent
	band.BackgroundTransparency = 0.55
	band.BorderSizePixel = 0
	band.Size = UDim2.new(0.2, 0, 1, -8)
	band.Position = UDim2.new(0.4, 0, 0, 4)
	band.Parent = track
	UI.corner(band, 6)

	marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.BackgroundColor3 = T.color.gold
	marker.BorderSizePixel = 0
	marker.Size = UDim2.new(0, 6, 1, 10)
	marker.Position = UDim2.fromScale(0.35, 0.5)
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Parent = track
	UI.corner(marker, 2)

	local glow = Instance.new("ImageLabel")
	glow.Image = "rbxasset://textures/particles/sparkles_main.dds"
	glow.ImageTransparency = 0.6
	glow.BackgroundTransparency = 1
	glow.Size = UDim2.fromOffset(40, 40)
	glow.Position = UDim2.fromScale(0.5, 0.5)
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Parent = marker

	progressBar = UI.bar(root, {
		name = "Progress",
		color = T.color.gold,
		size = UDim2.new(0.5, -24, 0, 14),
		pos = UDim2.fromOffset(18, 90),
		radius = T.radius.pill,
	})
	UI.label(root, "FISH", {
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.fromOffset(18, 76),
		frameSize = UDim2.new(0, 100, 0, 12),
	})

	integrityBar = UI.bar(root, {
		name = "Integrity",
		color = T.color.good,
		size = UDim2.new(0.5, -24, 0, 14),
		pos = UDim2.new(0.5, 6, 0, 90),
		radius = T.radius.pill,
	})
	--: The caption stays put; the label beside it counts down, so the row
	--: reads "LINE ... 42s" instead of repeating the word every frame.
	timerLabel = UI.label(root, "", {
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.new(0.5, 6, 0, 76),
		frameSize = UDim2.new(0.5, -24, 0, 12),
		align = Enum.TextXAlignment.Right,
	})
	UI.label(root, "LINE", {
		size = T.text.xs,
		color = T.color.textDim,
		pos = UDim2.new(0.5, 6, 0, 76),
		frameSize = UDim2.new(0, 100, 0, 12),
	})

	Skin.divider(root, 122)

	hintLabel = UI.label(root, "Hold the mouse to pull", {
		size = T.text.sm,
		color = T.color.textDim,
		pos = UDim2.new(0, 0, 1, -32),
		anchor = Vector2.new(0, 0),
		frameSize = UDim2.new(1, 0, 0, 16),
		align = Enum.TextXAlignment.Center,
	})

	flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.BackgroundColor3 = T.color.danger
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 4
	flash.Parent = track
	UI.corner(flash, 8)
end

--: One frame of the fight. All numbers, no state of its own.
function Reel.draw(view: any)
	if not track then
		return
	end
	local half = view.half
	band.Size = UDim2.new(half * 2, 0, 1, -8)
	band.Position = UDim2.new(math.clamp(view.centre - half, 0, 1), 0, 0, 4)
	marker.Position = UDim2.new(math.clamp(view.marker, 0, 1), 0, 0.5, 0)

	local inBand = math.abs(view.marker - view.centre) <= half
	band.BackgroundColor3 = if inBand then T.color.good else T.color.accent
	if trackStroke then
		--: The frame tightens around a clean pull; strain lets it loose.
		trackStroke.Transparency = if inBand then 0.3 else 0.65
	end
	if flash then
		--: Strain shows as the track going red-warm, not as a number.
		flash.BackgroundTransparency = 1 - math.clamp((1 - view.integrity) * 0.35, 0, 0.35)
	end

	--[[
		The fight you can hear: clicks while the pull is in the band, a low
		strain tick while it is not, and a creak once the line is nearly
		gone. Cooldowns live on the specs in `client/audio.luau`, so calling
		these every frame costs a table lookup and cannot machine-gun -- and
		the snap that ends a lost fight plays from `client/effects.luau`,
		which is the listener for `CastEnd`.
	]]
	if view.hold then
		audio.sfx(if inBand then "tidebound.reel" else "tidebound.strain")
	end
	if view.integrity < 0.35 then
		audio.sfx("tidebound.tension")
	end

	progressBar:set(view.progress)
	integrityBar:set(view.integrity)
	integrityBar.fill.BackgroundColor3 = if view.integrity < 0.3
		then T.color.danger
		elseif view.integrity < 0.6 then T.color.warning
		else T.color.good

	if timerLabel then
		timerLabel.Text = string.format("%.0fs", math.max(view.remaining, 0))
	end
	if hintLabel then
		hintLabel.Text = if view.hold
			then "Pulling -- don't fight the drag"
			else "Hold the mouse to pull"
		hintLabel.TextColor3 = if view.hold then T.color.accent else T.color.textDim
	end
end

function Reel.dismiss()
	if gui then
		gui:Destroy()
	end
	gui, root, track, trackStroke, band, marker = nil, nil, nil, nil, nil, nil
	progressBar, integrityBar, timerLabel, hintLabel, flash = nil, nil, nil, nil, nil
end

function Reel.active(): boolean
	return gui ~= nil and gui.Parent ~= nil
end

return Reel
