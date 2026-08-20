--!strict
-- L4b: dressing a blockout with a kit.
--
-- The step between "the level plays" and "the level looks like something". It is
-- a separate pass on purpose: layout defects and art defects are different
-- problems, and when they arrive together in one findings list neither can be
-- fixed without re-litigating the other. That is exactly what happened here the
-- first time -- "the plot is broken" and "the yellow glare is too strong" were
-- reported as one complaint about one build.
--
-- `apply` takes a built blockout, a kit, and a plan mapping region *kinds* to
-- kit modules. Region kinds rather than region ids, so a plan written once
-- dresses four plots or forty without being edited.
--
-- The receipt is the important output. A region with no rule stays grey and is
-- **named**, because a half-dressed world that reports success is worse than one
-- that reports what it skipped.

local Blockout = require(script.Parent.Blockout)
local Kit = require(script.Parent.Kit)
local Semantics = require(script.Parent.Semantics)
local Tokens = require(script.Parent.Tokens)

local Dress = {}

export type Rule = {
	--- Module placed across the interior cells.
	fill: string?,
	--- Module placed around the perimeter, facing outward.
	edge: string?,
	--- Module placed once at the region centre.
	feature: string?,
	--- Keep the blockout slab underneath as a floor. Default true: removing it
	--- is how a dressed region ends up with nothing to stand on.
	keepGround: boolean?,
	options: { [string]: any }?,
}

export type Plan = { [string]: Rule }

export type Receipt = {
	dressed: { string },
	--- Regions whose kind had no rule. These are still grey.
	undressed: { string },
	placed: number,
	byModule: { [string]: number },
	--- Distinct variants used per module, so a stamped-out world is visible.
	variantSpread: { [string]: { [string]: number } },
	clean: boolean,
}

local function fail(message: string): never
	error("[WorldKit.Dress] " .. message, 3)
end

--- Cell extents covering a region footprint, in kit-cell coordinates.
---
--- Rounded inward. A kit that overhangs its region reaches into the neighbouring
--- one, and two regions dressed independently then overlap -- the exact defect
--- the blockout validator was written to prevent, reintroduced one layer up.
local function cellSpan(region: Blockout.Region, cell: Vector3): (Vector3, Vector3, Vector3)
	local countX = math.max(math.floor(region.size.X / cell.X), 1)
	local countZ = math.max(math.floor(region.size.Y / cell.Z), 1)
	local originX = region.centre.X - (countX * cell.X) / 2 + cell.X / 2
	local originZ = region.centre.Z - (countZ * cell.Z) / 2 + cell.Z / 2
	local origin = Vector3.new(originX, region.centre.Y + (region.elevation or 0), originZ)
	return origin, Vector3.new(0, 0, 0), Vector3.new(countX - 1, 0, countZ - 1)
end

--- Dress a built blockout.
function Dress.apply(
	spec: Blockout.Spec,
	built: Blockout.BuildResult,
	kit: Kit.Kit,
	tokens: Tokens.TokenSet,
	plan: Plan
): Receipt
	if type(plan) ~= "table" or next(plan) == nil then
		fail("a dressing plan must map at least one region kind to modules")
	end

	local moduleIds: { [string]: true } = {}
	for _, id in ipairs(kit:moduleIds()) do
		moduleIds[id] = true
	end
	for kind, rule in pairs(plan) do
		for _, slot in ipairs({ "fill", "edge", "feature" }) do
			local moduleId = (rule :: any)[slot]
			if moduleId ~= nil and not moduleIds[moduleId] then
				fail(string.format(
					"plan for region kind %q names unknown kit module %q in %s",
					kind, tostring(moduleId), slot
				))
			end
		end
	end

	local receipt: Receipt = {
		dressed = {},
		undressed = {},
		placed = 0,
		byModule = {},
		variantSpread = {},
		clean = true,
	}

	local function record(moduleId: string, instances: { Instance })
		receipt.placed += #instances
		receipt.byModule[moduleId] = (receipt.byModule[moduleId] or 0) + #instances
		local spread = receipt.variantSpread[moduleId] or {}
		for variant, count in pairs(Kit.variantSpread(instances)) do
			spread[variant] = (spread[variant] or 0) + count
		end
		receipt.variantSpread[moduleId] = spread
	end

	for _, region in ipairs(spec.regions) do
		local rule = plan[region.kind]
		if rule == nil then
			table.insert(receipt.undressed, region.id)
			receipt.clean = false
			continue
		end

		local model = built.regions[region.id]
		if model == nil then
			table.insert(receipt.undressed, region.id)
			receipt.clean = false
			continue
		end

		local origin, low, high = cellSpan(region, kit.cell)
		local options = table.clone(rule.options or {})
		options.origin = origin

		if rule.edge ~= nil then
			record(rule.edge, kit:ring(model, rule.edge, low, high, options))
		end

		if rule.fill ~= nil then
			-- Interior only when an edge was placed, or the perimeter is dressed
			-- twice and every corner z-fights with itself.
			local interiorLow = if rule.edge ~= nil then low + Vector3.new(1, 0, 1) else low
			local interiorHigh = if rule.edge ~= nil then high - Vector3.new(1, 0, 1) else high
			if interiorHigh.X >= interiorLow.X and interiorHigh.Z >= interiorLow.Z then
				record(rule.fill, kit:rect(model, rule.fill, interiorLow, interiorHigh, options))
			end
		end

		if rule.feature ~= nil then
			local centre = Vector3.new(
				math.floor((low.X + high.X) / 2),
				low.Y,
				math.floor((low.Z + high.Z) / 2)
			)
			record(rule.feature, { kit:place(model, rule.feature, centre, options) })
		end

		if rule.keepGround == false then
			local ground = model:FindFirstChild("Ground")
			if ground ~= nil then
				ground:Destroy()
			end
		end

		model:SetAttribute("DressedBy", kit.id)
		table.insert(receipt.dressed, region.id)
	end

	table.sort(receipt.dressed)
	table.sort(receipt.undressed)
	built.root:SetAttribute("DressedKit", kit.id)
	built.root:SetAttribute("DressedRegions", #receipt.dressed)
	built.root:SetAttribute("UndressedRegions", #receipt.undressed)
	return receipt
end

--- Complaints about a dressing pass, as a policy rather than a dump.
function Dress.problems(receipt: Receipt, policy: { [string]: any }?): { string }
	local rules = policy or {}
	local minimumVariants = rules.minimumVariantsPerModule or 2
	local minimumPlacements = rules.minimumPlacementsBeforeVarietyMatters or 8

	local problems: { string } = {}
	if #receipt.undressed > 0 then
		table.insert(problems, string.format(
			"%d region(s) were left grey because no rule covers their kind: %s",
			#receipt.undressed, table.concat(receipt.undressed, ", ")
		))
	end
	for moduleId, spread in pairs(receipt.variantSpread) do
		local distinct = 0
		for _ in pairs(spread) do
			distinct += 1
		end
		local placements = receipt.byModule[moduleId] or 0
		if placements >= minimumPlacements and distinct < minimumVariants then
			table.insert(problems, string.format(
				"module %q was placed %d times with %d variant(s); at that count it reads as a stamp rather than a kit",
				moduleId, placements, distinct
			))
		end
	end
	table.sort(problems)
	return problems
end

return Dress
