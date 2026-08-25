--!strict
--[[
	WinResolver — ordered criteria cascade for ending a match.

	Match end is never one comparison: king tower dead means instant win,
	then crowns, then score, then overtime tiebreakers, then a draw. Each
	criterion decides "a", "b", "tie" or stays undecided ("nil"), and the
	first decisive answer wins. The cascade lives here so games stop
	handing-roll five nested ifs at end-of-match.
]]

local WinResolver = {}

export type Side = "a" | "b"
export type Decision = Side | "tie"

export type Criterion<T> = {
	name: string,
	decide: (ctx: T) -> Decision?,
}

export type Outcome = {
	outcome: Decision,
	decidedBy: string,
}

type Self = {
	criteria: { Criterion<any> },
}

WinResolver.__index = WinResolver

function WinResolver.new(criteria: { Criterion<any> }): Self
	assert(#criteria > 0, "WinResolver needs at least one criterion")
	return setmetatable({ criteria = criteria }, WinResolver)
end

function WinResolver.resolve<T>(self: Self, ctx: T): Outcome
	for _, criterion in self.criteria do
		local decision = criterion.decide(ctx)
		if decision ~= nil then
			return { outcome = decision :: Decision, decidedBy = criterion.name }
		end
	end
	return { outcome = "tie", decidedBy = "default" }
end

return WinResolver
