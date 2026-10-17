--!strict
--[[
	Luck — shifting the odds toward the rare end, without breaking the economy.

	`Progression.CrateRoll` rolls a weighted table and guarantees a rare after
	enough failures. Luck is the other half of every gacha economy: the
	temporary or purchased multiplier that makes rare outcomes more likely
	while it lasts.

		local multiplier = Luck.best({
			{ active = hasGamepass, multiplier = 2, source = "gamepass" },
			{ active = potionActive, multiplier = 3, source = "potion" },
		})

		local drops = Luck.apply(crate.drops, multiplier, 3)

	Two decisions from a shipped simulator, both of which exist because the
	obvious version broke something.

	Luck does not stack. It arbitrates.
	-----------------------------------

	A player with a luck gamepass, a luck potion and a lucky player standing in
	their server does **not** get 2 x 3 x 2. They get the best single source.

	Multiplying is the obvious implementation and it is how gacha economies
	die: sources are added over a game's life, each one reasonable on its own,
	and their product eventually makes the rarest tier common. Taking the
	maximum means a new source can never do more than the strongest existing
	one, so the ceiling is a number somebody chose rather than a number that
	emerged.

	Luck earned by progress is measured by *coverage*, not by volume
	---------------------------------------------------------------

	If a game pays luck for collecting things, pay it for the **fraction of the
	collection discovered**, never for the raw number of rolls. The shipped
	game's note on this is blunt: not raw count, index -- so that parking on one
	source and grinding it forever stops paying luck.

	A count-based bonus rewards the exact behaviour a collection game does not
	want, which is a player farming the single cheapest source until the
	numbers get large. A coverage-based one pays for breadth, which is the
	behaviour the collection exists to encourage.

	What luck does to the table
	---------------------------

	It multiplies the weight of everything at or above a rarity threshold, then
	the roll renormalises as it always would. Common outcomes are not made rarer
	directly; they shrink because the rare end grew. This keeps a luck
	multiplier readable -- "twice as likely to see a legendary" is true -- and it
	cannot ever remove an outcome from the table.
]]

local Luck = {}

export type Source = {
	active: boolean?,
	multiplier: number?,
	source: string?,
}

--[[
	The strongest active source, and which one it was.

	Returns 1 and nil when nothing applies, so the result is always safe to
	multiply by. Sources at or below 1 are ignored rather than allowed to
	reduce luck -- an "unlucky" mechanic is a different thing and should not
	arrive by way of a misconfigured bonus.
]]
function Luck.best(sources: { Source }): (number, string?)
	local best = 1
	local from: string? = nil
	for _, source in sources do
		if source.active ~= false then
			local value = source.multiplier or 1
			-- math.huge is greater than every finite multiplier, so it
			-- wins and the returned multiplier is infinite. NaN is not
			-- greater than best either, but it must not be stored.
			if type(value) == "number" and value == value and value > best and value < math.huge then
				best = value
				from = source.source
			end
		end
	end
	return best, from
end

--[[
	Luck earned from how much of a collection has been found.

	`discovered / obtainable` scaled to `maxBonus`, returned as a multiplier.
	A player who has found none of it gets 1; one who has found all of it gets
	`1 + maxBonus`.

	`obtainable` is the count a player can actually still get -- not everything
	that has ever existed. Counting retired or event-limited entries in the
	denominator means the bonus can never be completed, and a bonus that cannot
	be completed stops motivating the moment players work that out.
]]
function Luck.fromCompletion(discovered: number, obtainable: number, maxBonus: number?): number
	-- NaN is not <= 0, so the old check divided by it and returned NaN.
	-- A missing type, a NaN, a count that is not above 0, or an infinite
	-- count is not a collection that can be completed.
	if type(obtainable) ~= "number" or obtainable ~= obtainable or not (obtainable > 0) or not (obtainable < math.huge) then
		return 1
	end
	-- A NaN discovered count divides to NaN and the multiplier stays NaN.
	-- A missing type, a NaN, a negative, or an infinite count is none found.
	local found = discovered
	if type(found) ~= "number" or found ~= found or found < 0 or not (found < math.huge) then
		found = 0
	end
	local fraction = math.clamp(found / obtainable, 0, 1)
	-- math.huge is truthy, so `or 1` kept it and a full collection
	-- returned infinity. A missing, non-numeric, NaN, negative, or
	-- infinite bonus is the same default of 1.
	local bonus = maxBonus
	if type(bonus) ~= "number" or bonus ~= bonus or bonus < 0 or not (bonus < math.huge) then
		bonus = 1
	end
	return 1 + fraction * bonus
end

--[[
	Reweight a drop table by a luck multiplier.

	`minRarity` is the lowest rarity luck touches; anything below it keeps its
	weight. Returns a new table -- the caller's drops are configuration and
	must not be mutated by a roll, or two players with different luck would
	fight over the same numbers.

	Weights, not probabilities: the roll normalises, so this never has to
	produce something summing to one and never has to decide what to take away
	from the common outcomes.
]]
function Luck.apply(drops: { any }, multiplier: number, minRarity: number?): { any }
	local threshold = minRarity or 1
	local out = {}
	for _, drop in drops do
		local weight = drop.weight
		-- math.huge is greater than 1, so it used to scale the rare weight
		-- to infinity. NaN must not scale either.
		if type(multiplier) == "number" and multiplier == multiplier and multiplier > 1 and multiplier < math.huge and (drop.rarity or 0) >= threshold then
			weight *= multiplier
		end
		table.insert(out, {
			id = drop.id,
			weight = weight,
			rarity = drop.rarity,
		})
	end
	return out
end

--[[
	The chance of each outcome, as a fraction, for a UI that shows odds.

	Worth having in the library rather than in each game's UI: a displayed odds
	table computed separately from the roll is a displayed odds table that will
	eventually disagree with it, and players notice that faster than they
	notice anything else.
]]
function Luck.odds(drops: { any }): { [string]: number }
	-- math.huge makes the total infinite, so a real weight divided by it
	-- is 0. A missing type, a NaN, a negative, or an infinite weight is
	-- not a chance.
	local function usable(weight: any): number?
		if type(weight) == "number" and weight == weight and weight >= 0 and weight < math.huge then
			return weight
		end
		return nil
	end
	local total = 0
	for _, drop in drops do
		local weight = usable(drop.weight)
		if weight ~= nil then
			total += weight
		end
	end
	local out: { [string]: number } = {}
	if total <= 0 then
		return out
	end
	for _, drop in drops do
		local weight = usable(drop.weight)
		if weight ~= nil then
			out[drop.id] = weight / total
		end
	end
	return out
end

--[[
	How much luck actually changed a given outcome's odds.

	For the "your luck makes this 2.4x more likely" line. Computed from the two
	tables rather than from the multiplier, because the multiplier is not the
	answer: renormalisation means a 2x weight on one of several rare outcomes
	is less than 2x on the final chance.
]]
function Luck.effect(base: { any }, lucky: { any }, id: string): number
	local before = Luck.odds(base)[id]
	local after = Luck.odds(lucky)[id]
	if not before or before <= 0 or not after then
		return 1
	end
	return after / before
end

function Luck.describe(): { [string]: any }
	return {
		stacking = "best-of, never multiplied",
		completionBasis = "fraction of obtainable entries, never raw count",
	}
end

return Luck
