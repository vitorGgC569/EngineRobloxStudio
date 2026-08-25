--!strict
--[[
	Audit — where the money comes from, where it goes, and how long it takes.

	The three questions nobody can answer about their own economy
	-------------------------------------------------------------

	  How long does it take a new player to afford the first upgrade?
	  How long does it take a player at hour twenty?
	  Is there anything to spend on at hour forty?

	Every economy is designed by writing prices and rewards into a table, and
	the table cannot be read for the answers. A price of 5,000 means nothing
	until you know that the thing next to it earns 40 a minute, at which point
	it means "two hours", at which point somebody says "that is too long" and
	the number changes. This is the module that turns the table into the
	sentence.

		Audit.faucet("kill", { amount = 12, perMinute = 4 })
		Audit.sink("sword", { price = 5000, tier = 1 })

		Audit.report()   --> earns 48/min, the first sink is 1h 44m away

	Faucets and sinks, because that is what an economy is
	----------------------------------------------------

	A faucet puts currency in, a sink takes it out. An economy where the
	faucets outrun the sinks inflates until the numbers are meaningless; one
	where the sinks outrun the faucets is a grind nobody finishes. Neither is
	visible from any single number, and both are obvious the moment they are
	listed side by side.

	The two failures it names
	------------------------

	**Nothing to spend on.** A player past the last sink is still earning and
	has nowhere to put it. That is the moment a game stops having a loop, and
	it is invisible in a spreadsheet sorted by price.

	**A wall.** One sink that takes ten times longer than the one before it.
	Players do not experience a curve, they experience the step — and a step
	past about three times the previous gap reads as "the game wants money".
]]

local Audit = {}

export type Faucet = {
	id: string,
	amount: number,
	perMinute: number,
	currency: string,
	note: string?,
}

export type Sink = {
	id: string,
	price: number,
	currency: string,
	tier: number,
	repeatable: boolean,
	note: string?,
}

local faucets: { Faucet } = {}
local sinks: { Sink } = {}

-- ================================= declaring ================================
--[[
	Something that produces currency.

	`perMinute` is how often it happens for a typical player, not how often it
	*can* happen. The distinction is the whole accuracy of the model: a chest
	that could be opened every thirty seconds but is found twice an hour is a
	faucet of two per hour.
]]
function Audit.faucet(id: string, spec: any)
	table.insert(faucets, {
		id = id,
		amount = tonumber(spec.amount) or 0,
		perMinute = tonumber(spec.perMinute) or 0,
		currency = tostring(spec.currency or "coin"),
		note = spec.note,
	})
end

--[[
	Something that consumes currency.

	`tier` is where in the progression it sits, so the report can walk them in
	the order a player meets them rather than by price — the two differ
	whenever a late cosmetic is cheaper than an early tool.
]]
function Audit.sink(id: string, spec: any)
	table.insert(sinks, {
		id = id,
		price = tonumber(spec.price) or 0,
		currency = tostring(spec.currency or "coin"),
		tier = tonumber(spec.tier) or 1,
		repeatable = spec.repeatable == true,
		note = spec.note,
	})
end

-- ================================= measuring ================================
--: What a player earns per minute of one currency, from every faucet at once.
function Audit.income(currency: string?): number
	local wanted = currency or "coin"
	local total = 0
	for _, faucet in faucets do
		if faucet.currency == wanted then
			total += faucet.amount * faucet.perMinute
		end
	end
	return total
end

--[[
	How long this sink takes to afford, in minutes.

	Infinite when nothing produces that currency, which is a real and common
	state — a shop priced in a currency the game does not yet award. Returning
	infinity rather than erroring means the report can say so rather than stop.
]]
function Audit.minutesFor(sink: Sink): number
	local rate = Audit.income(sink.currency)
	if rate <= 0 then
		return math.huge
	end
	return sink.price / rate
end

--[[
	The progression, in the order a player meets it, with the gaps between.

	`gap` is the interesting column: not how long the sink takes from zero, but
	how long it takes *after the previous one*. That is what the player
	actually experiences, and it is the number a price table never shows.
]]
function Audit.curve(currency: string?): { any }
	local wanted = currency or "coin"
	local relevant = {}
	for _, sink in sinks do
		if sink.currency == wanted and not sink.repeatable then
			table.insert(relevant, sink)
		end
	end
	table.sort(relevant, function(a, b)
		if a.tier ~= b.tier then
			return a.tier < b.tier
		end
		return a.price < b.price
	end)

	local out = {}
	local previous = 0
	for _, sink in relevant do
		local minutes = Audit.minutesFor(sink)
		table.insert(out, {
			id = sink.id,
			tier = sink.tier,
			price = sink.price,
			minutes = minutes,
			gapMinutes = minutes - previous,
			--[[
				How much steeper this step is than the one before it.

				The wall detector. A ratio around one is a smooth curve; past
				about three the player feels the game asking for money rather
				than time.
			]]
			steepness = previous > 0 and (minutes - previous) / previous or 1,
		})
		previous = minutes
	end
	return out
end

-- ================================== report ==================================
--[[
	The economy as sentences, with the problems named.

	Deliberately the same shape as `Reference.check`: numbers are not the
	output, findings are. An agent handed "income 48/min" learns nothing; one
	handed "there is nothing to spend on past hour six" has a task.
]]
function Audit.report(currency: string?): { [string]: any }
	local wanted = currency or "coin"
	local income = Audit.income(wanted)
	local curve = Audit.curve(wanted)
	local notes: { string } = {}

	if income <= 0 then
		notes[#notes + 1] = string.format(
			"nothing produces '%s', so every price in it is unreachable", wanted)
	end

	if #curve == 0 and income > 0 then
		notes[#notes + 1] = string.format(
			"'%s' is earned at %.0f a minute and there is nothing to spend it on",
			wanted, income)
	end

	for index, step in curve do
		if step.steepness > 3 and index > 1 then
			notes[#notes + 1] = string.format(
				"'%s' takes %.1fx longer than the step before it (%.0f minutes after %.0f); "
				.. "players read a jump that size as the game asking for money rather than time",
				step.id, step.steepness, step.gapMinutes, curve[index - 1].minutes)
		end
		if step.minutes > 60 * 40 then
			notes[#notes + 1] = string.format(
				"'%s' is %.0f hours of play away, which is past where almost anybody is still here",
				step.id, step.minutes / 60)
		end
	end

	local last = curve[#curve]
	if last and income > 0 then
		notes[#notes + 1] = string.format(
			"the last sink is reached at %.1f hours; after that a player earns %.0f a minute "
			.. "with nowhere to put it", last.minutes / 60, income)
	end

	local repeatables = 0
	for _, sink in sinks do
		if sink.currency == wanted and sink.repeatable then
			repeatables += 1
		end
	end
	if repeatables == 0 and #curve > 0 then
		notes[#notes + 1] =
			"there is no repeatable sink, so the economy has an end rather than a floor"
	end

	return {
		currency = wanted,
		incomePerMinute = income,
		incomePerHour = income * 60,
		faucets = #faucets,
		sinks = #sinks,
		repeatableSinks = repeatables,
		curve = curve,
		notes = notes,
	}
end

--: The report as lines, for a debug seam or a log.
function Audit.explain(currency: string?): { string }
	local report = Audit.report(currency)
	local lines = {
		string.format("%s: %.0f/min (%.0f/hour) from %d faucets, %d sinks",
			report.currency, report.incomePerMinute, report.incomePerHour,
			report.faucets, report.sinks),
	}
	for _, step in report.curve do
		lines[#lines + 1] = string.format(
			"  tier %d  %-20s %8.0f  %6.1f min  (+%.1f)",
			step.tier, step.id, step.price, step.minutes, step.gapMinutes)
	end
	for _, note in report.notes do
		lines[#lines + 1] = "  - " .. note
	end
	return lines
end

function Audit.describe(): { [string]: any }
	local currencies: { [string]: boolean } = {}
	for _, faucet in faucets do
		currencies[faucet.currency] = true
	end
	for _, sink in sinks do
		currencies[sink.currency] = true
	end
	local list = {}
	for currency in currencies do
		table.insert(list, currency)
	end
	table.sort(list)
	return { currencies = list, faucets = #faucets, sinks = #sinks }
end

function Audit.reset()
	table.clear(faucets)
	table.clear(sinks)
end

return Audit
