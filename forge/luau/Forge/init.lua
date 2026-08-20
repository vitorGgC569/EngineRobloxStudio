--!strict
--[[
	Forge — the authoring half.

	The one rule
	------------
	Forge NEVER writes gameplay. It gives you primitives you write gameplay
	*with*. There is no `Forge.makeTycoon()`, no genre template, no code
	generator. The moment a module starts deciding what the game is, it has
	stopped being engine and started being a ceiling.

	The Quality Engine proves a game is correct. Forge is what you use to make
	one worth proving.

	Usage
	-----
		local Forge = require(ReplicatedStorage.Forge)
		local Net = Forge.Net
		local Anim = Forge.Anim

	Submodules load lazily, so requiring Forge on the client does not drag in
	server-only code.

	Layers
	------
	  Core    signal, trove, spring, rng, ease, sched   — no Roblox opinions
	  Data    schema-checked content tables             — where balance lives
	  Net     typed bus, validated, rate limited        — server-authoritative
	  Save    profiles, migration, autosave
	  Rig     characters authored in code
	  Anim    procedural animation, clips, markers      — game feel, part 1
	  Feel    shake, hitstop, impact, numbers           — game feel, part 2
	  Combat  damage pipeline, hitboxes, status, shots
	  Actor   AI state machines, perception, spawners
	  World   heightfield, biomes, scatter, structures
	  UI      theme tokens and widgets
	  Debug   state dump — how a validator reads semantics, not just geometry
]]

local Forge = {}

--[[
	The version, and what it promises.

	Semantic, with the pre-1.0 rule that the **minor** carries breaking changes
	and the patch does not. Breaking means exactly four things: removing or
	renaming a public function, changing what one returns, changing the meaning
	of a field a caller passes, or changing a string the engine matches on — a
	joint name, a clip name, an event name.

	Adding a function, adding an optional field, adding a module and retuning a
	number are not breaking. `forge/CHANGELOG.md` records every one of them.

	The promise is worth as much as its enforcement, so `Forge.require` below
	turns it into something a game can actually assert rather than a number in
	a file nobody reads.
]]
Forge.VERSION = "0.2.0"

local function parse(version: string): (number, number, number)
	local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
	return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

--[[
	Refuse to run against an engine that has moved out from under you.

		Forge.require("0.2.0")   -- at the top of your bootstrap

	Errors rather than warns. A game running on an engine whose contract it was
	not written against fails somewhere far from here, usually as a nil call in
	a system that looks innocent — this project has spent a whole session
	chasing exactly that shape of failure. Failing at the first line, naming
	both versions, is the cheapest possible version of that bug.
]]
function Forge.require(minimum: string)
	local wantMajor, wantMinor, wantPatch = parse(minimum)
	local haveMajor, haveMinor, havePatch = parse(Forge.VERSION)

	local ok
	if haveMajor ~= wantMajor then
		-- A different major is a different engine, in either direction.
		ok = false
	elseif haveMajor == 0 then
		-- Before 1.0 the minor is the breaking number, so it must match
		-- exactly; the patch may only go forward.
		ok = haveMinor == wantMinor and havePatch >= wantPatch
	else
		ok = haveMinor > wantMinor or (haveMinor == wantMinor and havePatch >= wantPatch)
	end

	if not ok then
		error(string.format(
			"[Forge] this game asks for %s and the engine is %s. Before 1.0 the "
			.. "minor number carries breaking changes; see forge/CHANGELOG.md.",
			minimum, Forge.VERSION), 2)
	end
end

local loaded: { [string]: any } = {}

setmetatable(Forge, {
	__index = function(self, key: string): any
		local cached = loaded[key]
		if cached ~= nil then
			return cached
		end
		local child = script:FindFirstChild(key)
		if not child then
			error(string.format("[Forge] no module named '%s'", tostring(key)), 2)
		end
		local module = require(child) :: any
		loaded[key] = module
		rawset(self, key, module)
		return module
	end,
})

return Forge
