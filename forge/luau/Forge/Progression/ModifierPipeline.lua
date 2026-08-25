--!strict
--[[
	ModifierPipeline — a number, and why it is that number.

	What this adds over `Save.StatsDeriver`
	---------------------------------------

	`StatsDeriver` resolves base + flats + percents in one fixed order, which
	is right for a stat block and wrong for everything shaped like a payout.
	A coin reward passes through a gamepass multiplier, a weekend event, a
	guild bonus, an enchant, and a hard cap — in that order, because the order
	changes the answer, and a cap applied before a multiplier is not a cap.

	Two things this has that a fixed order cannot:

	  **Named stages, each with its own combine rule.** `add`, `multiply`,
	  `override` and `cap` are different operations and a pipeline needs all
	  four. A cap is not a small multiplier.

	  **An audit trail.** Every contribution is labelled, so the output is not
	  just `47` but the list of things that made it 47. That is the difference
	  between a player asking "why is my damage 47" and being answered, and a
	  developer bisecting six systems to find out.

		Pipeline.define("coin_payout", { "base_bonus", "event", "cap" })
		Pipeline.provide("coin_payout", "event", function(context)
			return { amount = 2, label = "double_coins_weekend" }
		end)

		local total, why = Pipeline.resolve("coin_payout", 100, { player = id })
		--> 200, { { stage = "event", label = "double_coins_weekend", ... } }

	Why providers are functions
	---------------------------

	A modifier that is a number is a modifier that was true when somebody wrote
	it down. A gamepass bonus depends on who is asking, a weekend event on what
	day it is, a guild bonus on a roster that changes. Providers take the
	context and answer for that call, which is the only form that stays true.
]]

local ModifierPipeline = {}

export type Contribution = {
	amount: number,
	label: string,
}

export type Step = {
	stage: string,
	label: string,
	mode: string,
	amount: number,
	before: number,
	after: number,
}

type Stage = {
	name: string,
	mode: string,
}

type Definition = {
	stages: { Stage },
	providers: { [string]: { (context: any) -> any } },
}

local definitions: { [string]: Definition } = {}

--[[
	How each stage folds its contributions into the running value.

	`cap` is a floor on the *value*, not on the contribution: it takes the
	smaller of the two, which is what a maximum means. Getting that backwards
	produces a "cap" that raises small numbers, and it is the mistake that
	survives review because the word is right.
]]
local COMBINE: { [string]: (value: number, amount: number) -> number } = {
	add = function(value, amount)
		return value + amount
	end,
	multiply = function(value, amount)
		return value * amount
	end,
	override = function(_value, amount)
		return amount
	end,
	cap = function(value, amount)
		return math.min(value, amount)
	end,
	floor = function(value, amount)
		return math.max(value, amount)
	end,
}

-- ================================== define ==================================
--[[
	Declare a pipeline as an ordered list of stages.

	A stage is `"name"` for the default `add`, or `{ name, mode }`. Order is
	the declaration: stages run in the order given, and reordering them is a
	balance change rather than a refactor.
]]
function ModifierPipeline.define(id: string, stages: { any })
	local resolved: { Stage } = {}
	for _, entry in stages do
		if typeof(entry) == "string" then
			table.insert(resolved, { name = entry, mode = "add" })
		elseif typeof(entry) == "table" then
			local mode = tostring(entry[2] or entry.mode or "add")
			if not COMBINE[mode] then
				error(string.format(
					"[ModifierPipeline] '%s' is not a combine mode; use add, multiply, "
					.. "override, cap or floor", mode), 2)
			end
			table.insert(resolved, { name = tostring(entry[1] or entry.name), mode = mode })
		end
	end
	definitions[id] = { stages = resolved, providers = {} }
end

--[[
	Add something that contributes to a stage.

	Several providers may share a stage and all of them run; that is how a
	player with two gamepasses and an event bonus gets all three. A provider
	may return a number, one contribution, or a list of them.
]]
function ModifierPipeline.provide(id: string, stage: string, provider: (context: any) -> any)
	local definition = definitions[id]
	if not definition then
		error(string.format("[ModifierPipeline] no pipeline named '%s'", id), 2)
	end
	local found = false
	for _, declared in definition.stages do
		if declared.name == stage then
			found = true
			break
		end
	end
	if not found then
		-- Loud, because a provider on an undeclared stage never runs and looks
		-- exactly like a bonus that is not working.
		error(string.format(
			"[ModifierPipeline] '%s' has no stage '%s'", id, stage), 2)
	end

	local list = definition.providers[stage]
	if not list then
		list = {}
		definition.providers[stage] = list
	end
	table.insert(list, provider)
end

-- ================================== resolve =================================
--[[
	Accept a number, a single contribution, or a list of them.

	Providers are written by whoever owns the bonus, and insisting on one shape
	means half of them wrap a number in a table for no reason.
]]
local function contributionsOf(raw: any): { Contribution }
	if raw == nil then
		return {}
	end
	if typeof(raw) == "number" then
		return { { amount = raw, label = "unlabelled" } }
	end
	if typeof(raw) ~= "table" then
		return {}
	end
	if raw.amount ~= nil then
		return { { amount = tonumber(raw.amount) or 0, label = tostring(raw.label or "unlabelled") } }
	end

	local out: { Contribution } = {}
	for _, entry in raw do
		if typeof(entry) == "number" then
			table.insert(out, { amount = entry, label = "unlabelled" })
		elseif typeof(entry) == "table" and entry.amount ~= nil then
			table.insert(out, {
				amount = tonumber(entry.amount) or 0,
				label = tostring(entry.label or "unlabelled"),
			})
		end
	end
	return out
end

--[[
	Run the pipeline, and return both the number and the story.

	The second return is the reason this module exists. It is a list of steps,
	each naming the stage, the label, what the value was and what it became —
	which is an answer to "why", written at the moment the answer was true.

	A provider that errors is skipped with a warning rather than taking the
	payout down. A broken guild bonus should cost the guild bonus, not the
	player's coins.
]]
function ModifierPipeline.resolve(id: string, base: number, context: any?): (number, { Step })
	local definition = definitions[id]
	if not definition then
		error(string.format("[ModifierPipeline] no pipeline named '%s'", id), 2)
	end

	local value = base
	local steps: { Step } = {}

	for _, stage in definition.stages do
		local combine = COMBINE[stage.mode]
		for _, provider in definition.providers[stage.name] or {} do
			local ok, raw = pcall(provider, context)
			if not ok then
				warn(string.format(
					"[ModifierPipeline] a provider on %s.%s errored: %s",
					id, stage.name, tostring(raw)))
				continue
			end
			for _, contribution in contributionsOf(raw) do
				local before = value
				value = combine(value, contribution.amount)
				table.insert(steps, {
					stage = stage.name,
					label = contribution.label,
					mode = stage.mode,
					amount = contribution.amount,
					before = before,
					after = value,
				})
			end
		end
	end

	return value, steps
end

--[[
	The same answer, as sentences.

	For a debug seam, a support ticket, or an agent trying to work out why a
	number moved. A table of steps is machine-readable and a person reading it
	still has to do the arithmetic in their head.
]]
function ModifierPipeline.explain(id: string, base: number, context: any?): { string }
	local total, steps = ModifierPipeline.resolve(id, base, context)
	local lines = { string.format("%s starts at %.4g", id, base) }
	for _, step in steps do
		if step.mode == "multiply" then
			lines[#lines + 1] = string.format(
				"  x%.4g from %s (%s) -> %.4g", step.amount, step.label, step.stage, step.after)
		elseif step.mode == "add" then
			lines[#lines + 1] = string.format(
				"  %+.4g from %s (%s) -> %.4g", step.amount, step.label, step.stage, step.after)
		elseif step.mode == "cap" and step.after < step.before then
			lines[#lines + 1] = string.format(
				"  capped at %.4g by %s (%s)", step.amount, step.label, step.stage)
		elseif step.mode == "floor" and step.after > step.before then
			lines[#lines + 1] = string.format(
				"  raised to %.4g by %s (%s)", step.amount, step.label, step.stage)
		elseif step.mode == "override" then
			lines[#lines + 1] = string.format(
				"  set to %.4g by %s (%s)", step.amount, step.label, step.stage)
		end
	end
	lines[#lines + 1] = string.format("  = %.4g", total)
	return lines
end

function ModifierPipeline.describe(): { [string]: any }
	local out = {}
	for id, definition in definitions do
		local stages = {}
		for _, stage in definition.stages do
			table.insert(stages, {
				stage = stage.name,
				mode = stage.mode,
				providers = #(definition.providers[stage.name] or {}),
			})
		end
		out[id] = stages
	end
	return out
end

function ModifierPipeline.reset()
	table.clear(definitions)
end

return ModifierPipeline
