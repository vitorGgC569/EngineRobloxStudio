--!strict
--[[
	StatsDeriver — derived player stats from base + equipment + perks.

	The vesteria lesson: never store derived numbers. Base stats, flat and
	percentual modifiers from equipment slots and perks compose in a
	fixed order (base + flats) * percents, with documented clamps — one
	function every system calls so no HUD ever invents its own math.
]]

local StatsDeriver = {}

export type Modifier = {
	stat: string,
	flat: number?,
	percent: number?, -- 0.1 = +10%
}

export type StatBlock = {
	base: { [string]: number },
	modifiers: { Modifier },
	min: number?,
	max: number?,
}

StatsDeriver.__index = StatsDeriver

function StatsDeriver.derive(block: StatBlock): { [string]: number }
	local flats: { [string]: number } = {}
	local percents: { [string]: number } = {}
	for _, modifier in block.modifiers do
		assert(modifier.stat and #modifier.stat > 0, "modifier needs stat")
		if modifier.flat then
			flats[modifier.stat] = (flats[modifier.stat] or 0) + modifier.flat
		end
		if modifier.percent then
			percents[modifier.stat] = (percents[modifier.stat] or 0) + modifier.percent
		end
	end

	local out: { [string]: number } = {}
	for stat, base in block.base do
		local value = (base + (flats[stat] or 0)) * (1 + (percents[stat] or 0))
		if block.min then
			value = math.max(block.min, value)
		end
		if block.max then
			value = math.min(block.max, value)
		end
		out[stat] = value
	end

	-- Modifiers referencing stats the base does not define still apply.
	for stat, _flat in flats do
		if out[stat] == nil then
			out[stat] = 0 + (flats[stat] or 0)
		end
	end
	return out
end

-- Convenience for equipment slots: collect modifiers from equipped items.
function StatsDeriver.collect(equipped: { { modifiers: { Modifier } }? }): { Modifier }
	local out: { Modifier } = {}
	for _, item in equipped do
		if item and type(item.modifiers) == "table" then
			for _, modifier in item.modifiers :: { Modifier } do
				table.insert(out, modifier)
			end
		end
	end
	return out
end

return StatsDeriver
