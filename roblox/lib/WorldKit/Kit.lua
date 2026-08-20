--!strict
-- L3: modular kits.
--
-- The professional unit of work is the kit, not the part. Roblox's own
-- environmental-art curriculum is explicit about it: author a few modules
-- designed to combine, then build the whole environment from them, rather than
-- modelling every object individually. A world assembled that way is coherent
-- because the pieces were designed together; a world assembled part-by-part is
-- coherent only if whoever placed the parts happened to stay disciplined for
-- four hundred lines.
--
-- A kit here is data plus builders:
--
--   * a **cell** -- the module grid every piece snaps to, so pieces meet
--   * **modules** -- named builders with a declared footprint in cells
--   * **variants** -- seeded alternatives, so twenty of the same module do not
--     read as twenty copies of one object
--   * a **scale contract** -- validated against the token grammar *before*
--     anything is built, because a module that violates the grammar produces a
--     world that measures wrong everywhere it appears
--
-- Variation is seeded from the kit id, module id and cell coordinates. Two runs
-- of the same build produce the identical world, which is what makes a
-- screenshot diff mean something.

local Semantics = require(script.Parent.Semantics)
local Tokens = require(script.Parent.Tokens)

local Kit = {}

export type BuildContext = {
	parent: Instance,
	--- World transform of the cell centre, already oriented.
	cframe: CFrame,
	--- Footprint of this placement in world studs.
	size: Vector3,
	tokens: Tokens.TokenSet,
	--- Deterministic for a given (kit, module, cell). Use it for every choice.
	random: Random,
	variant: string,
	cell: Vector3,
	options: { [string]: any },
}

export type Module = {
	id: string,
	--- Footprint measured in cells, not studs. Integer, at least 1 on each axis.
	footprint: Vector3,
	--- Semantic classification emitted for every instance this module roots.
	visualType: string,
	build: (BuildContext) -> Instance,
	--- Named alternates. `build` receives the chosen name in `context.variant`.
	variants: { string }?,
	--- Height in cells; defaults to the footprint Y.
	description: string?,
}

export type KitDefinition = {
	id: string,
	cell: Vector3,
	modules: { [string]: Module },
	description: string?,
}

export type Kit = {
	id: string,
	cell: Vector3,
	modules: { [string]: Module },
	moduleIds: (self: Kit) -> { string },
	place: (self: Kit, parent: Instance, moduleId: string, cell: Vector3, options: { [string]: any }?) -> Instance,
	row: (self: Kit, parent: Instance, moduleId: string, from: Vector3, to: Vector3, options: { [string]: any }?) -> { Instance },
	rect: (self: Kit, parent: Instance, moduleId: string, from: Vector3, to: Vector3, options: { [string]: any }?) -> { Instance },
	ring: (self: Kit, parent: Instance, moduleId: string, from: Vector3, to: Vector3, options: { [string]: any }?) -> { Instance },
	toWorld: (self: Kit, cell: Vector3, origin: Vector3?) -> Vector3,
}

local function fail(message: string): never
	error("[WorldKit.Kit] " .. message, 3)
end

local function sortedKeys(map: { [string]: any }): { string }
	local keys = {}
	for key in pairs(map) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function isPositiveIntegerVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	for _, component in ipairs({ value.X, value.Y, value.Z }) do
		if component < 1 or component % 1 ~= 0 then
			return false
		end
	end
	return true
end

--- Deterministic seed for one placement.
---
--- Hashing the identifiers rather than using a global counter is what keeps the
--- world stable when a caller places modules in a different order: the cell
--- decides the variant, not the sequence of calls.
--- 32-bit multiply that stays exact.
---
--- `a * b` on a Luau number is double arithmetic, and with a 32-bit seed times
--- the FNV prime the product reaches 2^56 -- past the 2^53 a double represents
--- exactly. The result was still deterministic *within Luau*, so nothing looked
--- wrong, but it was not the FNV-1a it appears to be and it could not be
--- reproduced by exact integer arithmetic anywhere else. That surfaced when the
--- Python transcription in `rqe/world/composition.py` disagreed with it on
--- every cell.
---
--- Splitting into 16-bit halves keeps every intermediate under 2^53: the low
--- half's product is at most 65535 * 16777619, and the high half is reduced mod
--- 65536 before being shifted back up.
local function mul32(a: number, b: number): number
	local low = a % 65536
	local high = (a - low) / 65536
	return (((high * b) % 65536) * 65536 + low * b) % 4294967296
end

local function seedFor(kitId: string, moduleId: string, cell: Vector3): number
	local seed = 2166136261
	local function mix(value: number)
		seed = bit32.bxor(seed, value % 4294967296)
		seed = mul32(seed, 16777619)
	end
	for index = 1, #kitId do
		mix(string.byte(kitId, index))
	end
	for index = 1, #moduleId do
		mix(string.byte(moduleId, index))
	end
	mix(math.floor(cell.X) * 73856093)
	mix(math.floor(cell.Y) * 19349663)
	mix(math.floor(cell.Z) * 83492791)
	return seed
end

--- Check a kit against the token grammar before a single part exists.
---
--- Every problem found here would otherwise appear once per placement, which is
--- how a single undersized module becomes forty findings in a report.
function Kit.validate(definition: KitDefinition, tokens: Tokens.TokenSet): { string }
	local problems: { string } = {}

	if type(definition.id) ~= "string" or definition.id == "" then
		table.insert(problems, "kit id must be a non-empty string")
	end
	if typeof(definition.cell) ~= "Vector3" then
		table.insert(problems, "kit cell must be a Vector3")
		return problems
	end
	if definition.cell.X <= 0 or definition.cell.Y <= 0 or definition.cell.Z <= 0 then
		table.insert(problems, "kit cell must be positive on every axis")
	end

	-- A cell shorter than a doorway cannot contain a doorway, and every module
	-- built on that grid will be too small for a character to use.
	local doorHeight = tokens:grammar("doorHeight")
	if definition.cell.Y < doorHeight then
		table.insert(problems, string.format(
			"kit cell height %.1f is below the token grammar doorHeight %.1f; nothing built on this grid is enterable",
			definition.cell.Y, doorHeight
		))
	end
	local doorWidth = tokens:grammar("doorWidth")
	if definition.cell.X < doorWidth or definition.cell.Z < doorWidth then
		table.insert(problems, string.format(
			"kit cell footprint %.1fx%.1f is narrower than the token grammar doorWidth %.1f",
			definition.cell.X, definition.cell.Z, doorWidth
		))
	end

	if type(definition.modules) ~= "table" or next(definition.modules) == nil then
		table.insert(problems, "kit must declare at least one module")
		return problems
	end

	for moduleId, module in pairs(definition.modules) do
		local label = string.format("module %q", moduleId)
		if type(module) ~= "table" then
			table.insert(problems, label .. " must be a table")
			continue
		end
		if type(module.build) ~= "function" then
			table.insert(problems, label .. " must supply a build function")
		end
		if not isPositiveIntegerVector(module.footprint) then
			table.insert(problems, label .. " footprint must be a Vector3 of positive integers (cells)")
		end
		if type(module.visualType) ~= "string" or module.visualType == "" then
			table.insert(problems, label .. " must declare a visualType")
		end
		if module.variants ~= nil then
			if type(module.variants) ~= "table" or #module.variants == 0 then
				table.insert(problems, label .. " variants must be a non-empty array when present")
			else
				local seen: { [string]: true } = {}
				for _, variant in ipairs(module.variants) do
					if type(variant) ~= "string" or variant == "" then
						table.insert(problems, label .. " variants must be non-empty strings")
					elseif seen[variant] then
						table.insert(problems, string.format("%s declares variant %q twice", label, variant))
					else
						seen[variant] = true
					end
				end
			end
		end
	end

	return problems
end

--- Build a kit, refusing to return one that violates its own contract.
function Kit.define(definition: KitDefinition, tokens: Tokens.TokenSet): Kit
	local problems = Kit.validate(definition, tokens)
	if #problems > 0 then
		fail("kit is invalid:\n- " .. table.concat(problems, "\n- "))
	end

	local kit = {} :: any
	kit.id = definition.id
	kit.cell = definition.cell
	kit.modules = definition.modules

	function kit:moduleIds(): { string }
		return sortedKeys(definition.modules)
	end

	function kit:toWorld(cell: Vector3, origin: Vector3?): Vector3
		local base = origin or Vector3.zero
		return base + Vector3.new(
			cell.X * definition.cell.X,
			cell.Y * definition.cell.Y,
			cell.Z * definition.cell.Z
		)
	end

	function kit:place(parent: Instance, moduleId: string, cell: Vector3, options: { [string]: any }?): Instance
		local module = definition.modules[moduleId]
		if module == nil then
			fail(string.format(
				"unknown module %q in kit %q; available: %s",
				tostring(moduleId), definition.id, table.concat(sortedKeys(definition.modules), ", ")
			))
		end
		if typeof(cell) ~= "Vector3" then
			fail("cell must be a Vector3")
		end

		local opts = options or {}
		local random = Random.new(seedFor(definition.id, moduleId, cell))

		local variant = "default"
		if module.variants ~= nil and #module.variants > 0 then
			variant = opts.variant or module.variants[random:NextInteger(1, #module.variants)]
		elseif opts.variant ~= nil then
			fail(string.format("module %q declares no variants but one was requested", moduleId))
		end

		local size = Vector3.new(
			definition.cell.X * module.footprint.X,
			definition.cell.Y * module.footprint.Y,
			definition.cell.Z * module.footprint.Z
		)
		-- A module wider than one cell straddles cells, so its centre sits half a
		-- cell further along each axis than the anchor cell. Getting this wrong
		-- is what makes multi-cell pieces overlap their neighbours.
		local origin = opts.origin or Vector3.zero
		local centre = origin
			+ Vector3.new(
				(cell.X + (module.footprint.X - 1) / 2) * definition.cell.X,
				(cell.Y + (module.footprint.Y - 1) / 2) * definition.cell.Y,
				(cell.Z + (module.footprint.Z - 1) / 2) * definition.cell.Z
			)

		local rotation = opts.rotation
		local cframe = CFrame.new(centre)
		if rotation ~= nil then
			if type(rotation) ~= "number" then
				fail("rotation must be a number of degrees")
			end
			cframe = CFrame.new(centre) * CFrame.Angles(0, math.rad(rotation), 0)
		end

		local context: BuildContext = {
			parent = parent,
			cframe = cframe,
			size = size,
			tokens = tokens,
			random = random,
			variant = variant,
			cell = cell,
			options = opts,
		}

		local instance = module.build(context)
		if typeof(instance) ~= "Instance" then
			fail(string.format("module %q build did not return an Instance", moduleId))
		end
		if instance.Parent == nil then
			instance.Parent = parent
		end
		Semantics.root(instance, module.visualType, string.format("%s.%s.%s", definition.id, moduleId, variant))
		instance:SetAttribute("KitId", definition.id)
		instance:SetAttribute("KitModule", moduleId)
		instance:SetAttribute("KitVariant", variant)
		return instance
	end

	local function span(from: Vector3, to: Vector3): (Vector3, Vector3)
		return
			Vector3.new(math.min(from.X, to.X), math.min(from.Y, to.Y), math.min(from.Z, to.Z)),
			Vector3.new(math.max(from.X, to.X), math.max(from.Y, to.Y), math.max(from.Z, to.Z))
	end

	function kit:row(parent: Instance, moduleId: string, from: Vector3, to: Vector3, options: { [string]: any }?): { Instance }
		local low, high = span(from, to)
		local delta = high - low
		local axes = 0
		for _, component in ipairs({ delta.X, delta.Y, delta.Z }) do
			if component > 0 then
				axes += 1
			end
		end
		if axes > 1 then
			fail("Kit.row needs a straight line; use Kit.rect for an area")
		end
		local placed: { Instance } = {}
		for x = low.X, high.X do
			for y = low.Y, high.Y do
				for z = low.Z, high.Z do
					table.insert(placed, kit:place(parent, moduleId, Vector3.new(x, y, z), options))
				end
			end
		end
		return placed
	end

	function kit:rect(parent: Instance, moduleId: string, from: Vector3, to: Vector3, options: { [string]: any }?): { Instance }
		local low, high = span(from, to)
		local placed: { Instance } = {}
		for x = low.X, high.X do
			for y = low.Y, high.Y do
				for z = low.Z, high.Z do
					table.insert(placed, kit:place(parent, moduleId, Vector3.new(x, y, z), options))
				end
			end
		end
		return placed
	end

	--- The perimeter of a rectangle, which is what walls and fences actually are.
	function kit:ring(parent: Instance, moduleId: string, from: Vector3, to: Vector3, options: { [string]: any }?): { Instance }
		local low, high = span(from, to)
		local placed: { Instance } = {}
		local y = low.Y
		for x = low.X, high.X do
			for z = low.Z, high.Z do
				local onEdge = x == low.X or x == high.X or z == low.Z or z == high.Z
				if onEdge then
					-- Faces outward, so a module with a front and a back is
					-- oriented correctly without the caller computing angles.
					local rotation = 0
					if z == low.Z then
						rotation = 180
					elseif x == low.X then
						rotation = 90
					elseif x == high.X then
						rotation = 270
					end
					local placementOptions = if options then table.clone(options) else {}
					if placementOptions.rotation == nil then
						placementOptions.rotation = rotation
					end
					table.insert(placed, kit:place(parent, moduleId, Vector3.new(x, y, z), placementOptions))
				end
			end
		end
		return placed
	end

	return table.freeze(kit) :: Kit
end

--- How many distinct variants a run of placements actually used.
---
--- Repetition is the difference between a kit and a stamp. A caller can assert
--- on this instead of discovering from a screenshot that forty identical houses
--- got built.
function Kit.variantSpread(instances: { Instance }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, instance in ipairs(instances) do
		local variant = instance:GetAttribute("KitVariant")
		if type(variant) == "string" then
			counts[variant] = (counts[variant] or 0) + 1
		end
	end
	return counts
end

--- The placement seed, exposed so the contract can be checked across languages.
---
--- `rqe/world/composition.py` transcribes this function to compute placements
--- engine-side, and a second placement algorithm that merely looked
--- deterministic would be worse than none: stable within itself and disagreeing
--- with the SDK that ships in the game. Exporting it is what lets a test run
--- both on the same cells and assert they agree.
Kit.seedFor = seedFor

return Kit
