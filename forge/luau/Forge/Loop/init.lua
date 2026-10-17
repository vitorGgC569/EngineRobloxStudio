--!strict
--[[
	Loop — the degree between a primitive and a game.

	What was missing
	----------------

	This engine has 58 families of primitives and a shelf of finished games, and
	nothing in between. `Progression.CrateRoll` is correct weighted-draw
	arithmetic with a pity counter, and it is **0% of a loop**: it does not know
	when the first draw should land, what the reveal looks like, why a run of
	commons is where somebody closes the game, or that the collection is the
	reason to come back.

	The gap is not theoretical. Thirty-two retention modules were written and
	sixteen were never called by any game, because composing them by hand is
	work an agent does not do. Meanwhile the production pipeline grew a *second
	engine* rather than use this one, for exactly this reason: it needed things
	that were opinionated and composable, and a library that refuses to have
	opinions has neither.

	`Forge/init.lua` says it never writes gameplay, and that rule is right for
	a library a person reads. For an agent assembling a game alone it is the
	ceiling. A Loop is the resolution: it does not decide **what your game is**,
	it carries **what is already known about this shape of game** -- and the
	agent edits from there.

	What a Loop is, exactly
	-----------------------

	Four things, and it is not one unless it has all four:

	  1. the primitives, wired to each other;
	  2. **numbers that came from a measurement**, not from taste;
	  3. the moment -- what the player sees when it pays out;
	  4. **its own funnel, emitted by construction.**

	The fourth is the one that makes this more than a template. Two games are
	published from this repository and neither can say whether anybody stayed,
	because neither declares a funnel and nobody remembers to. A Loop declares
	its own, so a game built on one produces the drop-off report the moment it
	has players -- and `forge analytics` already reads exactly that shape.

	Where the numbers come from
	---------------------------

	`forge/kits/halo/salvage/docs/wiki/raw/retention/` holds the only real
	retention record here: a published game, fifty new players, a ten-step
	funnel with times. It is the source for every constant a Loop ships with,
	and each one names the observation it came from rather than a preference.

	Theme is not structure
	----------------------

	A Loop is parameterised on nouns. "Crack open pet eggs" and "crack open
	anime eggs" are the same loop with a different `noun`, which is the thing
	the factory has been unable to express -- nineteen generated games share
	one structure and differ only in an item list, which is the mirror image of
	the same mistake.
]]

local Loop = {}

--[[
	Siblings, resolved on the first thing that asks for one.

	One convention for the whole engine; see any other family index.
]]
return setmetatable(Loop, {
	__index = function(self, key: string): any
		local child = script:FindFirstChild(key)
		if not child or not child:IsA("ModuleScript") then
			return nil
		end
		local module = require(child) :: any
		rawset(self, key, module)
		return module
	end,
})
