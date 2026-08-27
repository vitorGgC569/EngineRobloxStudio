--!strict
--[[
	The sound bank.

	A game with no audio does not read as a quiet game, it reads as a broken
	one — faster than flat lighting does, and much faster than bad geometry.
	`brownout` is played mostly in the dark, which makes it worse: sound is the
	only channel left when the light is gone.

	Where these ids come from
	-------------------------

	Every one is from Roblox's own licensed SFX library — the clips whose names
	end in `(SFX)`, uploaded by **ProSoundEffects**, free to use in any
	experience. That constraint is not taste, it is the only audio that
	reliably plays: Roblox's audio privacy rules make almost all user-uploaded
	sound private to its uploader, so an id lifted from a search result is
	overwhelmingly likely to be silence in somebody else's place.

	Each was found through the toolbox search endpoint and then **verified one
	at a time** through `MarketplaceService:GetProductInfo` in a live session:
	`AssetTypeId == 3` and the creator's name read back. Nothing in this table
	was typed from memory.

	That verification is the whole point. An invented or private asset id does
	not fail loudly — it fails as silence, which is indistinguishable from the
	bug it was supposed to fix.

	What each cue is for
	--------------------

	The soundscape has one job beyond atmosphere: **tell the player where the
	light is**. The generator has a bed you can hear from inside the lit ring
	and not from outside it, so a player lost in the dark can turn until it
	gets louder. That is the audio half of the beacon.
]]

local Sound = {}

--[[
	Beds. Looped, non-positional, one at a time per layer.

	Two layers rather than one: wind everywhere, dread on top. Splitting them
	means the dread layer can duck at dawn while the wind keeps going, which is
	most of what makes dawn feel like relief.
]]
Sound.beds = {
	--: Eerie Ambience 2 (SFX) — the night. Low, wide, no melody to loop-spot.
	night = { id = "rbxassetid://9112775414", volume = 0.20 },
	--: Desert Wind Whistley Light Gusts 2 (SFX) — the basin is open ground.
	wind = { id = "rbxassetid://9114057128", volume = 0.13 },
}

--[[
	Positional loops, attached to a body in the world.

	Rolled off deliberately short. The generator's bed is a navigation aid, and
	an aid you can hear from four hundred studs tells you nothing.
]]
Sound.machines = {
	--: Oil Refinery Ambience 4 (SFX) — 46s of industrial bed under the plant.
	--: Its roll-off is set from the lit radius at runtime, so the sound of the
	--: outpost literally shrinks as the lights go out.
	generator = { id = "rbxassetid://9112840253", volume = 0.34, radius = 150 },
	--: Command Room Tone Deep Air Conditioning Hum (SFX) — a lamp is a
	--: ballast, and a ballast hums. Only the inner ring gets one: forty
	--: looping sounds is a mixer, not a soundscape.
	lamp = { id = "rbxassetid://9125446564", volume = 0.11, radius = 30 },
}

--: One-shots.
Sound.cues = {
	--: Metal Pops Denting Car In Out 2 (SFX) — a canister coming off the ground.
	lift = { id = "rbxassetid://9116771817", volume = 0.45, pitch = { 0.88, 1.02 } },
	--: Coin Large Metal Toss Dropped To Grass 1 (SFX) — the cell going in and
	--: the watts landing, which are the same moment and deserve one sound.
	deposit = { id = "rbxassetid://9113848518", volume = 0.5, pitch = { 0.95, 1.12 } },
	--: Hollow Rumble 1 (SFX) — the lights going out.
	blackout = { id = "rbxassetid://9112795463", volume = 0.75 },
	--: Hollow Rumble 3 (SFX), pitched up — the reserve catching.
	reserve = { id = "rbxassetid://9112795583", volume = 0.6, pitch = { 1.15, 1.15 } },
	--: The lift cue pitched hard up, so the interface is recognisably the same
	--: material as the world without being the same sound.
	click = { id = "rbxassetid://9116771817", volume = 0.22, pitch = { 1.55, 1.65 } },
	--: Mole Drilling Machine 6 (SFX), short and low — dawn.
	dawn = { id = "rbxassetid://9116948636", volume = 0.4, pitch = { 0.75, 0.75 } },
}

--[[
	Registered into `Forge.Audio` under the names the rest of the game uses.

	Called on both sides. The server plays positional cues everyone hears; the
	client plays the interface and the beds. Registering twice is harmless and
	simpler than deciding which half owns the table.
]]
function Sound.register(Audio: any)
	local defs: { [string]: any } = {}

	for name, spec in Sound.beds do
		defs["bed." .. name] = {
			id = spec.id,
			volume = spec.volume,
			looped = true,
			group = "ambient",
		}
	end

	for name, spec in Sound.machines do
		defs["machine." .. name] = {
			id = spec.id,
			volume = spec.volume,
			looped = true,
			group = "sfx",
			rollOffMax = spec.radius,
		}
	end

	for name, spec in Sound.cues do
		defs["cue." .. name] = {
			id = spec.id,
			volume = spec.volume,
			pitch = spec.pitch,
			group = name == "click" and "ui" or "sfx",
			--: A deposit from four players at once is one sound, not four.
			cooldown = if name == "deposit" then 0.08 else nil,
		}
	end

	Audio.defineMany(defs)
	return defs
end

return Sound
