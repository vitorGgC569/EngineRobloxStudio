--!strict
-- L0: design tokens.
--
-- Every art-direction number the SDK uses comes from here, and nothing else in
-- WorldKit is allowed to invent one. That is the whole point: a builder that
-- hardcodes "0.35 studs of trim" produces a world nobody can re-theme, and a
-- quality rule that hardcodes the same number produces a spec fitted to the
-- build it grades. One file feeds both sides, so neither can drift.
--
-- The token set is plain data (a JSON module), which means the identical file is
-- read by Luau here and by the Python quality engine. `define` is the gate: it
-- validates, resolves enums, and freezes, so a typo fails at load rather than
-- silently painting a wall grey.
--
--   local raw = require(ReplicatedStorage.Tokens.brickfarm)
--   local tokens = WorldKit.Tokens.define(raw)
--   local wall = tokens:swatch("structurePrimary")
--
-- No Studio-only API appears in this module on purpose: the same code has to run
-- in a plugin, in a published experience, and in an Open Cloud Luau task.

local Tokens = {}

export type Swatch = {
	color: Color3,
	material: Enum.Material,
	reflectance: number,
}

export type Role = {
	id: string,
	swatch: Swatch,
	tier: string,
	usage: string,
	minSurfaceCoverage: number?,
	maxSurfaceCoverage: number?,
}

export type Easing = {
	style: Enum.EasingStyle,
	direction: Enum.EasingDirection,
}

export type TokenSet = {
	id: string,
	revision: number,
	description: string,
	raw: { [string]: any },

	color: (self: TokenSet, role: string) -> Color3,
	material: (self: TokenSet, role: string) -> Enum.Material,
	swatch: (self: TokenSet, role: string) -> Swatch,
	role: (self: TokenSet, role: string) -> Role,
	roleIds: (self: TokenSet) -> { string },
	rolesByTier: (self: TokenSet, tier: string) -> { string },
	hasRole: (self: TokenSet, role: string) -> boolean,

	grammar: (self: TokenSet, metric: string) -> number,
	character: (self: TokenSet, metric: string) -> number,
	legibility: (self: TokenSet, metric: string) -> number,
	space: (self: TokenSet, step: string) -> number,
	text: (self: TokenSet, step: string) -> number,
	weight: (self: TokenSet, name: string) -> Enum.FontWeight,
	duration: (self: TokenSet, name: string) -> number,
	easing: (self: TokenSet, name: string) -> Easing,

	mood: (self: TokenSet, id: string) -> { [string]: any },
	moodIds: (self: TokenSet) -> { string },
	camera: (self: TokenSet, id: string) -> { [string]: any },
	cameraIds: (self: TokenSet) -> { string },
	bus: (self: TokenSet, id: string) -> { [string]: any },
	spatial: (self: TokenSet) -> { [string]: any },
}

local VALID_TIERS = table.freeze({ dominant = true, supporting = true, accent = true })

--- Sorted key list, so every error message and every derived ordering is stable.
local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in pairs(map) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function fail(message: string): never
	error("[WorldKit.Tokens] " .. message, 3)
end

--- Look a key up in a token map and refuse to guess.
---
--- Returning a default here would be the single most damaging convenience in the
--- library: a mistyped role would paint something plausible-but-wrong and the
--- mistake would only surface in a screenshot, if at all.
local function demand(map: { [string]: any }, key: string, what: string): any
	if type(key) ~= "string" or key == "" then
		fail(what .. " must be a non-empty string")
	end
	local value = map[key]
	if value == nil then
		fail(string.format("unknown %s %q; available: %s", what, key, table.concat(sortedKeys(map), ", ")))
	end
	return value
end

local function expectTable(container: { [string]: any }, key: string, context: string): { [string]: any }
	local value = container[key]
	if type(value) ~= "table" then
		fail(context .. "." .. key .. " must be a table")
	end
	return value
end

local function expectNumber(container: { [string]: any }, key: string, context: string): number
	local value = container[key]
	if type(value) ~= "number" then
		fail(context .. "." .. key .. " must be a number")
	end
	return value
end

local function expectString(container: { [string]: any }, key: string, context: string): string
	local value = container[key]
	if type(value) ~= "string" or value == "" then
		fail(context .. "." .. key .. " must be a non-empty string")
	end
	return value
end

--- JSON carries colours as [r, g, b] because that survives a round trip through
--- Python, a schema and a diff. Color3 is reconstructed once, at load.
local function toColor(triple: any, context: string): Color3
	if type(triple) ~= "table" or #triple ~= 3 then
		fail(context .. " must be an array of three integers")
	end
	for index = 1, 3 do
		local channel = triple[index]
		if type(channel) ~= "number" or channel < 0 or channel > 255 or channel % 1 ~= 0 then
			fail(context .. "[" .. index .. "] must be an integer 0..255")
		end
	end
	return Color3.fromRGB(triple[1], triple[2], triple[3])
end

local function toMaterial(name: string, context: string): Enum.Material
	local material = (Enum.Material :: any)[name]
	if typeof(material) ~= "EnumItem" then
		fail(context .. " names an unknown Enum.Material: " .. name)
	end
	return material
end

--- Freeze a tree, tolerating shared references.
---
--- `table.freeze` errors when handed an already-frozen table, so a naive
--- recursion breaks the moment two branches share a subtable -- which they do
--- here, because several roles legitimately reference the same material value.
--- The guard also makes the function idempotent, so freezing twice is harmless.
local function deepFreeze(value: any): any
	if type(value) ~= "table" or table.isfrozen(value) then
		return value
	end
	for _, entry in pairs(value) do
		deepFreeze(entry)
	end
	return table.freeze(value)
end

--- Validate a raw token table and return the usable token set.
function Tokens.define(raw: { [string]: any }): TokenSet
	if type(raw) ~= "table" then
		fail("token set must be a table")
	end
	if raw.schemaVersion ~= 1 then
		fail("unsupported token schemaVersion; this SDK reads version 1")
	end

	local id = expectString(raw, "tokenSetId", "tokens")
	local revision = expectNumber(raw, "revision", "tokens")
	local description = expectString(raw, "description", "tokens")

	-- palette ------------------------------------------------------------
	local paletteRaw = expectTable(raw, "palette", "tokens")
	local rolesRaw = expectTable(paletteRaw, "roles", "palette")
	local roles: { [string]: Role } = {}
	local tierIndex: { [string]: { string } } = { dominant = {}, supporting = {}, accent = {} }

	for roleId, definition in pairs(rolesRaw) do
		local context = "palette.roles." .. roleId
		if type(definition) ~= "table" then
			fail(context .. " must be a table")
		end
		local tier = expectString(definition, "tier", context)
		if not VALID_TIERS[tier] then
			fail(context .. ".tier must be dominant, supporting or accent")
		end
		local reflectance = definition.reflectance
		if reflectance ~= nil and type(reflectance) ~= "number" then
			fail(context .. ".reflectance must be a number")
		end
		roles[roleId] = {
			id = roleId,
			swatch = {
				color = toColor(definition.srgb, context .. ".srgb"),
				material = toMaterial(expectString(definition, "material", context), context .. ".material"),
				reflectance = (reflectance :: number?) or 0,
			},
			tier = tier,
			usage = expectString(definition, "usage", context),
			minSurfaceCoverage = definition.minSurfaceCoverage,
			maxSurfaceCoverage = definition.maxSurfaceCoverage,
		}
		table.insert(tierIndex[tier], roleId)
	end
	if next(roles) == nil then
		fail("palette.roles must not be empty")
	end
	for _, list in pairs(tierIndex) do
		table.sort(list)
	end

	-- scale --------------------------------------------------------------
	local scaleRaw = expectTable(raw, "scale", "tokens")
	local characterRaw = expectTable(scaleRaw, "character", "scale")
	local grammarRaw = expectTable(scaleRaw, "grammar", "scale")
	local legibilityRaw = expectTable(scaleRaw, "legibility", "scale")

	-- A stair a character cannot climb is not a stair. Catching it here costs
	-- nothing; catching it from a pathfinding failure costs a whole run.
	local maxStepUp = expectNumber(characterRaw, "maxStepUp", "scale.character")
	local stairRise = expectNumber(grammarRaw, "stairRise", "scale.grammar")
	if stairRise > maxStepUp then
		fail(string.format(
			"scale.grammar.stairRise (%.2f) exceeds scale.character.maxStepUp (%.2f); the stairs would be unclimbable",
			stairRise, maxStepUp
		))
	end
	local doorHeight = expectNumber(grammarRaw, "doorHeight", "scale.grammar")
	local characterHeight = expectNumber(characterRaw, "height", "scale.character")
	if doorHeight <= characterHeight then
		fail(string.format(
			"scale.grammar.doorHeight (%.2f) must exceed scale.character.height (%.2f)",
			doorHeight, characterHeight
		))
	end
	local ceilingHeight = expectNumber(grammarRaw, "ceilingHeight", "scale.grammar")
	if ceilingHeight < doorHeight then
		fail("scale.grammar.ceilingHeight must be at least doorHeight")
	end

	-- spacing, typography, motion ----------------------------------------
	local spacingRaw = expectTable(raw, "spacing", "tokens")
	local spacingSteps = expectTable(spacingRaw, "steps", "spacing")
	local typographyRaw = expectTable(raw, "typography", "tokens")
	local typeSteps = expectTable(typographyRaw, "steps", "typography")
	local weightsRaw = expectTable(typographyRaw, "weights", "typography")
	local motionRaw = expectTable(raw, "motion", "tokens")
	local durationsRaw = expectTable(motionRaw, "durations", "motion")
	local easingsRaw = expectTable(motionRaw, "easings", "motion")

	local easings: { [string]: Easing } = {}
	for name, definition in pairs(easingsRaw) do
		local context = "motion.easings." .. name
		if type(definition) ~= "table" then
			fail(context .. " must be a table")
		end
		local styleName = expectString(definition, "style", context)
		local directionName = expectString(definition, "direction", context)
		local style = (Enum.EasingStyle :: any)[styleName]
		local direction = (Enum.EasingDirection :: any)[directionName]
		if typeof(style) ~= "EnumItem" then
			fail(context .. ".style names an unknown Enum.EasingStyle: " .. styleName)
		end
		if typeof(direction) ~= "EnumItem" then
			fail(context .. ".direction names an unknown Enum.EasingDirection: " .. directionName)
		end
		easings[name] = { style = style, direction = direction }
	end

	local weights: { [string]: Enum.FontWeight } = {}
	for name, weightName in pairs(weightsRaw) do
		if type(weightName) ~= "string" then
			fail("typography.weights." .. name .. " must be a string")
		end
		local weight = (Enum.FontWeight :: any)[weightName]
		if typeof(weight) ~= "EnumItem" then
			fail("typography.weights." .. name .. " names an unknown Enum.FontWeight: " .. weightName)
		end
		weights[name] = weight
	end

	-- moods, cameras, audio ----------------------------------------------
	local moodsRaw = expectTable(raw, "moods", "tokens")
	if next(moodsRaw) == nil then
		fail("tokens.moods must not be empty")
	end
	local camerasRaw = expectTable(raw, "cameras", "tokens")
	if next(camerasRaw) == nil then
		fail("tokens.cameras must not be empty")
	end
	local audioRaw = expectTable(raw, "audio", "tokens")
	local busesRaw = expectTable(audioRaw, "buses", "audio")
	local spatialRaw = expectTable(audioRaw, "spatial", "audio")

	local set = {} :: any
	set.id = id
	set.revision = revision
	set.description = description
	set.raw = raw

	function set:color(roleId: string): Color3
		return (demand(roles, roleId, "palette role") :: Role).swatch.color
	end

	function set:material(roleId: string): Enum.Material
		return (demand(roles, roleId, "palette role") :: Role).swatch.material
	end

	function set:swatch(roleId: string): Swatch
		return (demand(roles, roleId, "palette role") :: Role).swatch
	end

	function set:role(roleId: string): Role
		return demand(roles, roleId, "palette role")
	end

	function set:hasRole(roleId: string): boolean
		return roles[roleId] ~= nil
	end

	function set:roleIds(): { string }
		return sortedKeys(roles)
	end

	function set:rolesByTier(tier: string): { string }
		local list = tierIndex[tier]
		if list == nil then
			fail("unknown palette tier " .. tostring(tier))
		end
		return table.clone(list)
	end

	function set:grammar(metric: string): number
		return demand(grammarRaw, metric, "scale.grammar metric")
	end

	function set:character(metric: string): number
		return demand(characterRaw, metric, "scale.character metric")
	end

	function set:legibility(metric: string): number
		return demand(legibilityRaw, metric, "scale.legibility metric")
	end

	function set:space(step: string): number
		return demand(spacingSteps, step, "spacing step")
	end

	function set:text(step: string): number
		return demand(typeSteps, step, "typography step")
	end

	function set:weight(name: string): Enum.FontWeight
		return demand(weights, name, "typography weight")
	end

	function set:duration(name: string): number
		return demand(durationsRaw, name, "motion duration")
	end

	function set:easing(name: string): Easing
		return demand(easings, name, "motion easing")
	end

	function set:mood(moodId: string): { [string]: any }
		return demand(moodsRaw, moodId, "mood")
	end

	function set:moodIds(): { string }
		return sortedKeys(moodsRaw)
	end

	function set:camera(cameraId: string): { [string]: any }
		return demand(camerasRaw, cameraId, "camera profile")
	end

	function set:cameraIds(): { string }
		return sortedKeys(camerasRaw)
	end

	function set:bus(busId: string): { [string]: any }
		return demand(busesRaw, busId, "audio bus")
	end

	function set:spatial(): { [string]: any }
		return spatialRaw
	end

	deepFreeze(roles)
	deepFreeze(tierIndex)
	deepFreeze(easings)
	return table.freeze(set) :: TokenSet
end

--- Adapt a token set to the legacy `Palette.Theme` shape.
---
--- Migration path, not a permanent API. Existing builders take a Theme; this
--- lets them keep working while call sites move to roles one at a time, instead
--- of requiring one enormous rewrite that nothing can validate.
function Tokens.toTheme(tokens: TokenSet, moodId: string): { [string]: any }
	local mood = tokens:mood(moodId)
	local atmosphere = mood.atmosphere
	local lighting = mood.lighting
	local swatches: { [string]: any } = {}
	for _, roleId in ipairs(tokens:roleIds()) do
		swatches[roleId] = tokens:swatch(roleId)
	end
	return {
		name = tokens.id,
		swatches = swatches,
		skyColor = toColor(lighting.colorShiftTop or { 255, 255, 255 }, "mood.lighting.colorShiftTop"),
		fogColor = toColor(atmosphere.color or { 255, 255, 255 }, "mood.atmosphere.color"),
	}
end

--- Total declared accent coverage, for checking the palette against its own
--- harmony budget before a single part exists.
function Tokens.accentBudget(tokens: TokenSet): number
	local total = 0
	for _, roleId in ipairs(tokens:rolesByTier("accent")) do
		total += tokens:role(roleId).maxSurfaceCoverage or 0
	end
	return total
end

return Tokens
