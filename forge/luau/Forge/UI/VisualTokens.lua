--!strict
--[[
	VisualKit.Tokens — semantic roles from an M3 scheme, as pure data.

	The vendored Material 3 science (roblox/lib/Vendor/M3/Theme/Scheme)
	produces a SchemeData table of role -> ARGB int from one seed color.
	This module converts it into Color3 roles plus the elevation ladder,
	with zero engine dependencies so tokens are testable headless and
	identical for builder and grader.

	local m3 = require(Vendor.M3.Theme.Scheme)
	local data = m3.Scheme.dark(0xFF6750A4):toJSON()
	local roles = VisualTokens.fromSchemeData(data, "dark")
]]

local VisualTokens = {}

export type SchemeType = "light" | "dark"

export type SchemeData = { [string]: number }

local ROLE_KEYS = {
	"primary", "onPrimary", "primaryContainer", "onPrimaryContainer",
	"secondary", "onSecondary", "secondaryContainer", "onSecondaryContainer",
	"tertiary", "onTertiary", "error", "onError",
	"background", "onBackground", "surface", "onSurface",
	"surfaceVariant", "onSurfaceVariant", "outline", "outlineVariant",
}

local function argbToColor(value: number): { r: number, g: number, b: number }
	return {
		r = bit32.band(bit32.rshift(value, 16), 0xFF) / 255,
		g = bit32.band(bit32.rshift(value, 8), 0xFF) / 255,
		b = bit32.band(value, 0xFF) / 255,
	}
end

function VisualTokens.fromSchemeData(data: SchemeData, schemeType: SchemeType): { [string]: any }
	local out: { [string]: any } = {}
	for _, key in ROLE_KEYS do
		if data[key] then
			out[key] = argbToColor(data[key])
		end
	end
	out.schemeType = schemeType

	-- Elevation ladder per Material 3: surface tinted toward PRIMARY with
	-- alpha stepping per elevation level (dp1/2/3 ≈ .05/.08/.11/.14), not a
	-- linear white lift. Tint direction flips for light schemes.
	local base = out.surface or { r = 1, g = 1, b = 1 }
	local primary = out.primary or out.onBackground or { r = 0, g = 0, b = 0 }
	local alphas: { number } = if schemeType == "dark"
		then { [0] = 0, 0.05, 0.08, 0.11, 0.14 }
		else { [0] = 0, -0.03, -0.05, -0.08, -0.11 }

	out.elevation = {}
	for level = 0, 4 do
		local a = math.clamp(alphas[level], -1, 1)
		out.elevation["level" .. tostring(level)] = {
			r = math.clamp(base.r + (primary.r - base.r) * a, 0, 1),
			g = math.clamp(base.g + (primary.g - base.g) * a, 0, 1),
			b = math.clamp(base.b + (primary.b - base.b) * a, 0, 1),
		}
	end
	return out
end

-- Single-step tint for any surface at an arbitrary dp level.
function VisualTokens.elevated(surfaceColor: { r: number, g: number, b: number }, primaryColor: { r: number, g: number, b: number }, levelDp: number, schemeType: SchemeType): { r: number, g: number, b: number }
	local sign = if schemeType == "dark" then 1 else -1
	local alpha = math.clamp(sign * math.min(levelDp, 24) * 0.006, 0, 0.35)
	return {
		r = math.clamp(surfaceColor.r + (primaryColor.r - surfaceColor.r) * alpha, 0, 1),
		g = math.clamp(surfaceColor.g + (primaryColor.g - surfaceColor.g) * alpha, 0, 1),
		b = math.clamp(surfaceColor.b + (primaryColor.b - surfaceColor.b) * alpha, 0, 1),
	}
end

-- Typography scale (M3-like); sizes already include the density factor.
VisualTokens.Typography = {
	displayLarge = { size = 57, lineHeight = 64, weight = 400 },
	headlineMedium = { size = 28, lineHeight = 36, weight = 400 },
	titleLarge = { size = 22, lineHeight = 28, weight = 400 },
	bodyLarge = { size = 16, lineHeight = 24, weight = 400 },
	bodyMedium = { size = 14, lineHeight = 20, weight = 400 },
	labelLarge = { size = 14, lineHeight = 20, weight = 500 },
	labelSmall = { size = 11, lineHeight = 16, weight = 500 },
}

-- Radii vocabulary shared by every component.
VisualTokens.Radius = { Panel = 12, Control = 8, Chip = 100 }

return VisualTokens
