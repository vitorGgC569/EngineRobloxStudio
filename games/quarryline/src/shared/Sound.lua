--!strict
--[[
	The sound bank.

	Why a table and not `Instance.new("Sound")` at each call site
	------------------------------------------------------------

	`Forge.Audio` already pools, groups, ducks and randomises pitch; what it
	never had was anything to play. This game shipped with **zero** sounds —
	no music, no click, no ambience — and silence reads as broken far faster
	than flat lighting does.

	Where these ids come from
	-------------------------

	Every one is from Roblox's own SFX library: the clips whose names end in
	`(SFX)`, free to use in any experience, and moderation-approved. Each was
	found through the toolbox search endpoint and then verified one at a time
	against Open Cloud — `assetType == "Audio"`, `moderationState == "Approved"`
	— before it was written here.

	That verification is the point. An invented asset id does not fail loudly:
	it fails as silence, which is indistinguishable from the bug it was meant
	to fix. Nothing in this table was typed from memory.

	Durations are recorded because they decide the shape of the cue. A 46-second
	refinery bed loops under a smelter; a 1-second coin does not, and a looped
	one-second clip is a machine gun.
]]

local Sound = {}

--[[
	Loops that belong to a machine, attached to its body.

	Rolled off steeply: forty of these on a busy server is a wall of noise, and
	a tycoon's soundscape should tell you *where* the work is, not that work
	exists somewhere.
]]
Sound.machines = {
	--: Mole Drilling Machine 6 (SFX) — 10s, the longest of that set and so the
	--: least obviously looped.
	drill = { id = "rbxassetid://9116948636", volume = 0.35, radius = 34 },

	--: Command Room Tone Deep Air Conditioning Hum (SFX) — 35s. A conveyor is
	--: a motor, and a motor is a hum; the literal "conveyor" clips in the
	--: library are game rips.
	belt = { id = "rbxassetid://9125446564", volume = 0.22, radius = 26 },

	--: Oil Refinery Ambience 4 (SFX) — 46s of industrial bed.
	smelter = { id = "rbxassetid://9112840253", volume = 0.30, radius = 38 },

	--: A depot is a place things arrive, not a machine that runs. It gets the
	--: sale cue below and no loop of its own, deliberately.
	depot = nil,
}

--: One-shots, played at a position.
Sound.cues = {
	--: Metal Pops Denting Car In Out 2 (SFX) — 2s.
	build = { id = "rbxassetid://9116771817", volume = 0.5, pitch = { 0.9, 1.1 } },
	--: Coin Large Metal Toss Dropped To Grass 1 (SFX) — 1s.
	sell = { id = "rbxassetid://9113848518", volume = 0.4, pitch = { 0.95, 1.15 } },
	--: Reused for the interface, pitched up so it reads as a click rather than
	--: as the same impact the machines make.
	click = { id = "rbxassetid://9116771817", volume = 0.25, pitch = { 1.5, 1.6 } },
}

--: Mountain Birds 1 (SFX) — 32s. An open-air quarry, not a cave.
Sound.ambience = { id = "rbxassetid://9112832288", volume = 0.18 }

--[[
	Registered into `Forge.Audio` under names the rest of the game uses.

	Called on both sides: the server plays positional cues that everyone hears,
	the client plays the interface and the ambience bed. Registering twice is
	harmless and simpler than deciding which half owns the table.
]]
function Sound.register(Audio: any)
	local defs: { [string]: any } = {}

	for machineId, spec in Sound.machines do
		if spec then
			defs["machine." .. machineId] = {
				id = spec.id,
				volume = spec.volume,
				looped = true,
				group = "sfx",
				rollOffMax = spec.radius,
			}
		end
	end

	for name, spec in Sound.cues do
		defs["cue." .. name] = {
			id = spec.id,
			volume = spec.volume,
			pitch = spec.pitch,
			group = name == "click" and "ui" or "sfx",
		}
	end

	defs["ambient.quarry"] = {
		id = Sound.ambience.id,
		volume = Sound.ambience.volume,
		looped = true,
		group = "ambient",
	}

	Audio.defineMany(defs)
	return defs
end

return Sound
