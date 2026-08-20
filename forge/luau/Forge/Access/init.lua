--!strict
--[[
	Access — the game is playable by people this engine had not considered.

	Forge had none of this. Not a colour-blind palette, not a subtitle, not a
	way to make text bigger. On a platform whose audience is mostly young and
	mostly on a phone held at arm's length, that is not a nice-to-have that can
	wait for version three.

	Three things, in the order they matter:

	  **Colour.** Roughly one man in twelve cannot reliably separate red from
	  green, and this engine's damage numbers are red, its health bar is red,
	  and its "good" is green. A palette swap fixes all of it at once because
	  every colour in `UI.theme` is a token rather than a literal — which is
	  the reason tokens were worth the trouble.

	  **Subtitles.** Every audio cue that carries information — a boss
	  telegraph, a warning, a line of dialogue — is information a deaf player
	  does not get. `Audio` already names its cues; a subtitle is a caption on
	  a name that already exists.

	  **Text size.** A HUD readable on a monitor is not readable on a phone at
	  arm's length, and Roblox's own accessibility setting is something a game
	  has to honour deliberately.

		Access.palette("deuteranopia")
		Access.caption("boss.telegraph", "The Hollowed King raises its arm")
		Access.textScale(1.25)

	--- Why this is not a settings menu -------------------------------------

	Because a setting nobody finds is a setting nobody uses. Everything here is
	applied by the engine to things the engine already owns: `UI` colours, an
	`Audio` cue, a `TextLabel`'s size. A game gets it by using the engine
	normally, and a game that wants a menu builds one over `Access.set`.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local Signal = require(script.Parent.Core).Signal

local Access = {}

Access.changed = Signal.new() -- (setting, value)

Access.settings = {
	palette = "default",
	textScale = 1,
	captions = true,
	--: Reduces shake, flashes and screen tint. Motion sickness is common and
	--: this engine's `Feel` is deliberately aggressive.
	reducedMotion = false,
	--: Larger touch targets, beyond the 44px floor `Platform` checks.
	largeTargets = false,
}

-- ================================= palettes =================================
--[[
	Palettes as *replacements* for the theme's semantic colours.

	The names are semantic — danger, good, warning — which is what makes this
	work: nothing in the engine says "red", it says "danger", so swapping what
	danger means changes every damage number, health bar and refusal at once.

	The three named forms cover the overwhelming majority of colour vision
	deficiency. Each keeps the *meaning* separable rather than merely looking
	different: danger and good must be distinguishable at a glance by someone
	who cannot use hue to tell them apart, so they differ in brightness too.
]]
Access.palettes = {
	default = {},

	-- Red-blind. Red reads as dark yellow-brown, so danger moves to a hue that
	-- survives and gains brightness contrast against good.
	protanopia = {
		danger = Color3.fromRGB(230, 120, 20),
		good = Color3.fromRGB(60, 130, 240),
		warning = Color3.fromRGB(240, 200, 60),
		gold = Color3.fromRGB(245, 215, 130),
	},

	-- Green-blind, the most common. Same problem from the other side.
	deuteranopia = {
		danger = Color3.fromRGB(235, 110, 40),
		good = Color3.fromRGB(70, 140, 250),
		warning = Color3.fromRGB(245, 205, 70),
		gold = Color3.fromRGB(248, 220, 140),
	},

	-- Blue-blind, rare. Blue and yellow collapse, so good moves to a red that
	-- is safe here precisely because red is unaffected.
	tritanopia = {
		danger = Color3.fromRGB(220, 60, 70),
		good = Color3.fromRGB(60, 180, 120),
		warning = Color3.fromRGB(230, 120, 160),
		mana = Color3.fromRGB(180, 90, 200),
	},

	--[[
		Maximum contrast, for low vision rather than colour blindness.

		Not a hue change but a brightness one: everything important becomes
		near-white or near-black against its background. Ugly on purpose —
		somebody choosing this is choosing legibility over looks.
	]]
	highContrast = {
		text = Color3.fromRGB(255, 255, 255),
		textDim = Color3.fromRGB(220, 220, 220),
		danger = Color3.fromRGB(255, 80, 80),
		good = Color3.fromRGB(120, 255, 120),
		warning = Color3.fromRGB(255, 230, 60),
		panel = Color3.fromRGB(10, 10, 12),
		bg = Color3.fromRGB(0, 0, 0),
		stroke = Color3.fromRGB(255, 255, 255),
	},
}

local originalTheme: { [string]: Color3 } | nil = nil

--[[
	Apply a palette to the engine's theme.

	The original is captured on the first call so a return to `default` is a
	real restore rather than a second guess at what the colours were.
]]
function Access.palette(name: string): boolean
	local palette = Access.palettes[name]
	if not palette then
		warn(string.format("[Access] no palette named '%s'", tostring(name)))
		return false
	end

	local UI = require(script.Parent.UI)
	if not originalTheme then
		originalTheme = table.clone(UI.theme.color)
	end

	for key, colour in originalTheme :: { [string]: Color3 } do
		UI.theme.color[key] = colour
	end
	for key, colour in palette do
		UI.theme.color[key] = colour
	end

	Access.settings.palette = name
	Access.changed:Fire("palette", name)
	return true
end

-- ================================= captions =================================
local captions: { [string]: string } = {}
local captionShown = Signal.new() -- (text, seconds)

Access.captionShown = captionShown

--[[
	Give an audio cue a caption.

	Keyed by the cue name `Audio` already uses, so a game that has named its
	sounds well has already done most of this work. A cue with no caption
	simply produces none — silence is the right default for a footstep.
]]
function Access.caption(cue: string, text: string)
	captions[cue] = text
end

function Access.captionsFor(table_: { [string]: string })
	for cue, text in table_ do
		captions[cue] = text
	end
end

--[[
	Announce a cue, if it has a caption and captions are on.

	`Audio` calls this on every play. The engine doing it means a game gets
	subtitles by naming its sounds, rather than by remembering to caption each
	one at each call site — which is how half of them end up uncaptioned.
]]
function Access.announce(cue: string, seconds: number?): boolean
	if not Access.settings.captions then
		return false
	end
	local text = captions[cue]
	if not text then
		return false
	end
	captionShown:Fire(text, seconds or 2.5)
	return true
end

function Access.captionFor(cue: string): string?
	return captions[cue]
end

-- ================================== text ====================================
--[[
	Scale every piece of text the engine renders.

	Applied to `UI.theme.text` rather than to individual labels, so it reaches
	widgets built before the setting changed as well as after. Clamped because
	a scale of four is a HUD that covers the game.
]]
function Access.textScale(scale: number): boolean
	local clamped = math.clamp(scale, 0.75, 2)
	local UI = require(script.Parent.UI)

	local base = Access._baseText
	if not base then
		base = table.clone(UI.theme.text)
		Access._baseText = base
	end

	for key, size in base do
		UI.theme.text[key] = math.floor(size * clamped + 0.5)
	end

	Access.settings.textScale = clamped
	Access.changed:Fire("textScale", clamped)
	return true
end

--[[
	Roblox's own accessibility preference, honoured.

	`GuiService.PreferredTextSize` is a system setting the player already
	chose. A game that ignores it makes them choose twice, and most never find
	the second one.
]]
function Access.followSystem(): boolean
	local ok, preferred = pcall(function()
		return GuiService.PreferredTextSize
	end)
	if not ok then
		return false
	end

	local scale = 1
	if preferred == Enum.PreferredTextSize.Large then
		scale = 1.25
	elseif preferred == Enum.PreferredTextSize.Larger then
		scale = 1.5
	elseif preferred == Enum.PreferredTextSize.Largest then
		scale = 1.75
	end
	return Access.textScale(scale)
end

-- ================================== motion ==================================
--[[
	Turn the engine's own aggression down.

	`Feel` shakes the screen, tints it and stops time on a hit, and all three
	are causes of motion sickness. Read by `Feel` rather than enforced here,
	because a module that reaches into another to disable it is a module the
	next reader cannot follow.
]]
function Access.reducedMotion(on: boolean)
	Access.settings.reducedMotion = on == true
	Access.changed:Fire("reducedMotion", Access.settings.reducedMotion)
end

--: What `Feel` should multiply its intensity by. One call, one number.
function Access.motionScale(): number
	return Access.settings.reducedMotion and 0.25 or 1
end

-- ================================== apply ===================================
function Access.set(setting: string, value: any): boolean
	if setting == "palette" then
		return Access.palette(tostring(value))
	elseif setting == "textScale" then
		return Access.textScale(tonumber(value) or 1)
	elseif setting == "captions" then
		Access.settings.captions = value == true
		Access.changed:Fire("captions", Access.settings.captions)
		return true
	elseif setting == "reducedMotion" then
		Access.reducedMotion(value == true)
		return true
	elseif setting == "largeTargets" then
		Access.settings.largeTargets = value == true
		Access.changed:Fire("largeTargets", Access.settings.largeTargets)
		return true
	end
	warn(string.format("[Access] '%s' is not a setting", tostring(setting)))
	return false
end

function Access.serialize(): { [string]: any }
	return table.clone(Access.settings)
end

--[[
	Restore a player's choices.

	Accessibility settings belong in the save profile, not in a client-side
	preference: a player who set them up once should not do it again on their
	next device, and they are the settings a player is least willing to
	re-discover.
]]
function Access.deserialize(data: any)
	if typeof(data) ~= "table" then
		return
	end
	for key, value in data do
		if Access.settings[key] ~= nil then
			Access.set(key, value)
		end
	end
end

function Access.describe(): { [string]: any }
	local captioned = 0
	for _ in captions do
		captioned += 1
	end
	return {
		context = RunService:IsServer() and "server" or "client",
		settings = table.clone(Access.settings),
		palettes = (function()
			local names = {}
			for name in Access.palettes do
				table.insert(names, name)
			end
			table.sort(names)
			return names
		end)(),
		captionedCues = captioned,
	}
end

return Access
