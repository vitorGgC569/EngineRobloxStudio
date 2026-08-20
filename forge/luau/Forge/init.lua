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

Forge.VERSION = "0.1.0"

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
