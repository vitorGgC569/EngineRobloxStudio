--!strict
--[[
	The sound bank, built entirely from what ships with the Roblox client.

	Not a stylistic choice. The publishing account behind this repository is
	moderated, so every `rbxassetid://` — including the engine's own published
	catalogues and sounds that loaded yesterday — answers HTTP 403 on *read*.
	`rbxasset://` files are part of the client install and are fetched from
	disk, so they are the only audio this build can rely on.

	Six of them exist and were verified by loading one in a live session. Four
	are used here; the other two are a falling loop and a water impact, and
	neither is a sorting line.

	A game with no audio reads as broken faster than a flat-lit one does, and
	this game is a rhythm of clicks and clunks — so four sounds, used
	deliberately, is worth more than silence waiting for a catalogue.
]]

local Sound = {}

Sound.cues = {
	--: The lever. A UI click is exactly what a lever throw sounds like from
	--: three studs away, and it is the sound the player hears most.
	lever = { id = "rbxasset://sounds/volume_slider.ogg", volume = 0.45, pitch = { 0.92, 1.06 } },

	--: A crate landing in the chute. The jump-land thud, pitched down, is a
	--: wooden box hitting a metal floor.
	sort = { id = "rbxasset://sounds/action_jump_land.mp3", volume = 0.4, pitch = { 0.72, 0.82 } },

	--: A mistake. Roblox's own `oof` is instantly legible to every player on
	--: the platform, which for a negative cue is worth more than fidelity.
	strike = { id = "rbxasset://sounds/oof.ogg", volume = 0.55, pitch = { 0.9, 1.0 } },

	--: End of shift. The explosion pitched right down is a factory horn.
	horn = { id = "rbxasset://sounds/impact_explosion_03.mp3", volume = 0.6, pitch = { 0.35, 0.35 } },
}

--[[
	Registered into `Forge.Audio` under the names the rest of the game uses.

	Called on both sides. `Audio.define` is per-VM exactly like `Net.define`, so
	the server registering the bank does not make it exist on the client.
]]
function Sound.register(Audio: any)
	local defs: { [string]: any } = {}
	for name, spec in Sound.cues do
		defs["cue." .. name] = {
			id = spec.id,
			volume = spec.volume,
			pitch = spec.pitch,
			group = if name == "lever" then "ui" else "sfx",
			--: Four crates resolving in the same tick is one clunk, not four.
			cooldown = if name == "sort" then 0.06 else nil,
		}
	end
	Audio.defineMany(defs)
	return defs
end

return Sound
