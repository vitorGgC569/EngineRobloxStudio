--!strict
-- Theming for generated worlds.
--
-- Colour and material live together because they are one decision: "weathered
-- copper" is a hue *and* a Metal surface, and splitting them is how generated
-- worlds end up looking like flat plastic. A theme is data, so a game swaps its
-- whole look without touching a single builder call.

local Palette = {}

export type Swatch = {
	color: Color3,
	material: Enum.Material,
}

export type Theme = {
	name: string,
	swatches: { [string]: Swatch },
	skyColor: Color3,
	fogColor: Color3,
}

local function swatch(r: number, g: number, b: number, material: Enum.Material): Swatch
	return { color = Color3.fromRGB(r, g, b), material = material }
end

--- Bright brick-built: flat saturated colours, studded plastic, blue sky.
---
--- The look most Roblox collectors use, and for good reason: high saturation
--- and low material complexity read instantly at any distance, on any device,
--- and never turn muddy. Everything is Plastic or SmoothPlastic on purpose --
--- rough PBR materials fight the flat colours and drag the frame rate down for
--- nothing.
Palette.BrickFarm = {
	name = "BrickFarm",
	skyColor = Color3.fromRGB(126, 200, 245),
	fogColor = Color3.fromRGB(190, 224, 245),
	swatches = {
		-- ground and paths
		grass = swatch(115, 198, 88, Enum.Material.Plastic),
		grassDark = swatch(88, 170, 68, Enum.Material.Plastic),
		pathRed = swatch(226, 92, 82, Enum.Material.Plastic),
		pathWhite = swatch(240, 240, 236, Enum.Material.Plastic),
		pathTrim = swatch(248, 208, 74, Enum.Material.Plastic),
		pavement = swatch(214, 214, 208, Enum.Material.Plastic),

		-- structure
		brick = swatch(206, 176, 138, Enum.Material.Plastic),
		brickDark = swatch(150, 120, 92, Enum.Material.Plastic),
		wood = swatch(160, 116, 76, Enum.Material.Plastic),
		woodDark = swatch(112, 80, 52, Enum.Material.Plastic),
		stone = swatch(178, 182, 190, Enum.Material.Plastic),
		stoneDark = swatch(126, 130, 140, Enum.Material.Plastic),
		slate = swatch(88, 92, 104, Enum.Material.Plastic),
		ink = swatch(44, 46, 56, Enum.Material.Plastic),
		metal = swatch(158, 164, 174, Enum.Material.Plastic),
		metalDark = swatch(74, 78, 88, Enum.Material.Plastic),

		-- accents, used sparingly and loudly
		green = swatch(96, 214, 96, Enum.Material.Plastic),
		greenBright = swatch(126, 240, 118, Enum.Material.Plastic),
		blueSign = swatch(108, 178, 255, Enum.Material.Plastic),
		cyan = swatch(92, 214, 236, Enum.Material.Plastic),
		cyanBright = swatch(120, 236, 255, Enum.Material.Plastic),
		gold = swatch(250, 206, 80, Enum.Material.Plastic),
		goldBright = swatch(255, 224, 120, Enum.Material.Plastic),
		pink = swatch(240, 118, 190, Enum.Material.Plastic),
		purple = swatch(168, 118, 240, Enum.Material.Plastic),
		orange = swatch(248, 152, 72, Enum.Material.Plastic),
		red = swatch(232, 88, 84, Enum.Material.Plastic),

		white = swatch(246, 248, 250, Enum.Material.Plastic),
		muted = swatch(178, 184, 194, Enum.Material.Plastic),

		-- nature
		leaf = swatch(104, 196, 88, Enum.Material.Plastic),
		leafDark = swatch(74, 158, 66, Enum.Material.Plastic),
		bark = swatch(146, 104, 68, Enum.Material.Plastic),
		rock = swatch(174, 172, 186, Enum.Material.Plastic),
		rockDark = swatch(132, 130, 146, Enum.Material.Plastic),

		-- aliases so existing call sites keep working
		ground = swatch(115, 198, 88, Enum.Material.Plastic),
		groundDark = swatch(88, 170, 68, Enum.Material.Plastic),
		road = swatch(226, 92, 82, Enum.Material.Plastic),
		copper = swatch(248, 152, 72, Enum.Material.Plastic),
		copperLight = swatch(250, 206, 80, Enum.Material.Plastic),
		teal = swatch(198, 202, 210, Enum.Material.Plastic),
		tealDark = swatch(150, 156, 166, Enum.Material.Plastic),
		ore = swatch(126, 240, 118, Enum.Material.Plastic),
		glass = swatch(196, 230, 245, Enum.Material.Glass),
		accent = swatch(250, 206, 80, Enum.Material.Plastic),
	},
} :: Theme

--- Industrial mining: cold slate, warm copper, teal ore glow.
Palette.MinersRidge = {
	name = "MinersRidge",
	skyColor = Color3.fromRGB(126, 173, 200),
	fogColor = Color3.fromRGB(96, 128, 150),
	swatches = {
		ground = swatch(58, 78, 66, Enum.Material.Grass),
		groundDark = swatch(41, 56, 50, Enum.Material.LeafyGrass),
		rock = swatch(96, 104, 112, Enum.Material.Rock),
		rockDark = swatch(62, 70, 78, Enum.Material.Slate),
		stone = swatch(126, 132, 138, Enum.Material.Concrete),
		pavement = swatch(88, 94, 102, Enum.Material.Pavement),
		road = swatch(64, 68, 74, Enum.Material.Asphalt),
		slate = swatch(46, 58, 72, Enum.Material.Slate),
		ink = swatch(24, 32, 42, Enum.Material.Metal),
		metal = swatch(112, 120, 130, Enum.Material.Metal),
		metalDark = swatch(58, 66, 76, Enum.Material.DiamondPlate),
		copper = swatch(184, 104, 51, Enum.Material.CorrodedMetal),
		copperLight = swatch(233, 156, 76, Enum.Material.Metal),
		gold = swatch(242, 193, 83, Enum.Material.Metal),
		wood = swatch(122, 84, 56, Enum.Material.WoodPlanks),
		woodDark = swatch(84, 58, 40, Enum.Material.Wood),
		teal = swatch(55, 196, 181, Enum.Material.Neon),
		tealDark = swatch(26, 112, 111, Enum.Material.Metal),
		ore = swatch(61, 213, 185, Enum.Material.Neon),
		glass = swatch(180, 214, 226, Enum.Material.Glass),
		leaf = swatch(74, 143, 91, Enum.Material.Grass),
		leafDark = swatch(52, 104, 68, Enum.Material.LeafyGrass),
		bark = swatch(91, 61, 46, Enum.Material.Wood),
		white = swatch(238, 240, 234, Enum.Material.SmoothPlastic),
		accent = swatch(242, 193, 83, Enum.Material.Neon),
	},
} :: Theme

--- Look up a swatch, failing loudly rather than silently rendering grey.
function Palette.get(theme: Theme, key: string): Swatch
	local found = theme.swatches[key]
	if found == nil then
		error(string.format("theme '%s' has no swatch '%s'", theme.name, key), 2)
	end
	return found
end

--- Nudge a colour's brightness, for cheap variation without new swatches.
function Palette.shade(color: Color3, amount: number): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, math.clamp(s, 0, 1), math.clamp(v + amount, 0, 1))
end

return Palette
