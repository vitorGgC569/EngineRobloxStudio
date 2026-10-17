--!strict
--[[
	audio — the whole audible layer: cues, ambience that follows the weather,
	and a music framework that is wired but silent until a track is uploaded.

	Every id comes from one of exactly two places:

	  * `Audio.Bank` — Roblox's own clips, resolved at runtime instead of
	    copied here. An id typed from memory is silence, not an error, which
	    is the worst way for an asset to fail (Bank.lua:10-14), and the
	    doctor refuses an id that has never been loaded.
	  * `rbxasset://sounds/...` engine-shipped files that are already in the
	    asset verification registry.

	Three things this module owns that call sites should not:

	  * **The sea is a loop.** The bank's `world.water` spec is a one-shot,
	    and `Audio.attach` schedules non-looped sounds for cleanup when their
	    clip ends — so the old sea cue was a splash that played once and
	    left. The tidebound specs here set `looped = true`, which is the flag
	    `Audio.attach` respects.
	  * **Weather and proximity move the mix.** `setWeather` takes the phase
	    the AmbienceController already receives and drives the wind and rain
	    loops; the sea follows how close the body is to the waterline.
	  * **Music is a framework, not a file.** `MusicSpecs` ships EMPTY: an id
	    there can only be a real upload through the authenticated account,
	    and until one exists `setMusic` is a no-op. The Settings slider still
	    moves the `music` group, so the day an id lands the slider works.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Audio = Forge.Audio

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local audio = {}

local SEA = Config.waterLevel

audio.ready = false

--: Mirrors the defaults in the save template (DataService.luau:50), so a
--: player whose profile has not arrived yet still hears a sane mix.
audio.settings = { music = 0.6, sfx = 0.8 }

--[[
	Music — empty on purpose.

	Fill an `id` ("rbxassetid://...") and `setMusic` picks the cue up with no
	other change. It is empty because engine uploads are private by default
	(Bank.lua:10-14): a guessed id here fails as silence.
]]
audio.MusicSpecs = {
	calm = { id = "", volume = 0.30 },
	harbour = { id = "", volume = 0.28 },
	bite = { id = "", volume = 0.34 },
}

-- ============================== local specs =================================
--: Bank roles are resolved here rather than copied, so the bank stays the one
--: place an id is written down.
local function bankId(role: string, index: number): string?
	local entries = Audio.Bank.forRole(role)
	local entry = entries[index]
	if not entry or entry.id == nil or entry.id == "" then
		return nil
	end
	return "rbxassetid://" .. tostring(entry.id)
end

--: Engine-shipped and already in the verification registry.
local SPLASH_ID = "rbxasset://sounds/impact_water.mp3"

local function localSpecs(): { [string]: any }
	local specs: { [string]: any } = {}
	local function add(name: string, id: string?, spec: any)
		if id ~= nil and id ~= "" then
			spec.id = id
			specs[name] = spec
		end
	end

	--: Loops. `looped = true` is the flag `Audio.attach` respects; without it
	--: the sound is cleaned up when its clip ends -- which is what made the
	--: old sea cue a one-shot.
	add("tidebound.sea", bankId("world.water", 1),
		{ volume = 0.22, pitch = 0.78, group = "ambient", looped = true, rollOffMin = 8, rollOffMax = 90 })
	add("tidebound.wash", bankId("world.water", 2),
		{ volume = 0.10, pitch = { 0.9, 1.05 }, group = "ambient", looped = true, rollOffMin = 6, rollOffMax = 60 })
	add("tidebound.wind", bankId("ui.open", 2),
		{ volume = 0.0, pitch = 0.85, group = "ambient", looped = true, rollOffMin = 8, rollOffMax = 90 })
	--: No engine rain loop exists in the bank; rain is synthesized from the
	--: constant-drips clip at a raised pitch and scaled by the weather mix.
	add("tidebound.rain", bankId("world.water", 2),
		{ volume = 0.0, pitch = 1.35, group = "ambient", looped = true, rollOffMin = 6, rollOffMax = 70 })

	--: The fishing loop, one cue per beat.
	add("tidebound.cast", bankId("ui.open", 1), { volume = 0.4, pitch = { 0.92, 1.02 }, group = "sfx" })
	add("tidebound.bite", bankId("world.water", 2), { volume = 0.6, pitch = { 1.15, 1.35 }, group = "sfx" })
	add("tidebound.splash", SPLASH_ID, { volume = 0.5, pitch = { 0.9, 1.05 }, group = "sfx" })
	add("tidebound.reel", bankId("machine.clank", 1),
		{ volume = 0.16, pitch = { 1.5, 1.7 }, group = "sfx", cooldown = 0.16 })
	add("tidebound.strain", bankId("machine.clank", 2),
		{ volume = 0.12, pitch = { 1.05, 1.15 }, group = "sfx", cooldown = 0.45 })
	add("tidebound.tension", bankId("machine.loop", 1),
		{ volume = 0.2, pitch = { 1.3, 1.45 }, group = "sfx", cooldown = 1.6 })
	add("tidebound.snap", bankId("combat.hit", 1), { volume = 0.5, pitch = { 1.25, 1.4 }, group = "sfx" })
	add("tidebound.sell", bankId("reward.coin", 1), { volume = 0.55, pitch = { 0.95, 1.1 }, group = "sfx" })
	add("tidebound.coins", bankId("reward.coin", 2), { volume = 0.5, pitch = { 1.1, 1.25 }, group = "sfx" })
	--: Deliberately NOT `ui.success`/`reward.pickup`: the bootstrap already
	--: plays those on LevelUp and CatchResult, and the same clip on the same
	--: frame reads as a flam, not as emphasis.
	add("tidebound.catch", bankId("ui.open", 3), { volume = 0.45, pitch = { 0.8, 0.9 }, group = "sfx" })
	add("tidebound.fanfare", bankId("machine.clank", 3), { volume = 0.5, pitch = { 1.15, 1.3 }, group = "sfx" })

	return specs
end

-- ============================== playback ====================================
function audio.sfx(name: string, options: any?): Sound?
	if not audio.ready then
		audio.start()
	end
	local ok, sound = pcall(function()
		return Audio.play(name, options)
	end)
	return ok and sound or nil
end

--: 3D variant, for anything that happened at a place in the world.
function audio.sfxAt(name: string, position: Vector3, options: any?): Sound?
	if not audio.ready then
		audio.start()
	end
	local ok, sound = pcall(function()
		return Audio.playAt(name, position, options)
	end)
	return ok and sound or nil
end

--: How loud the sea is, by how far the listener is above the waterline.
function audio.proximityScale(heightAboveWater: number): number
	return math.clamp(1 - heightAboveWater / 60, 0.25, 1)
end

-- ============================== ambience ====================================
local ambienceHost: BasePart? = nil
local ambienceSounds: { [string]: Sound } = {}

local LOOP_CUES = {
	sea = "tidebound.sea",
	wash = "tidebound.wash",
	wind = "tidebound.wind",
	rain = "tidebound.rain",
}

local WEATHER_MIX = {
	clear = { wind = 0.10, rain = 0.0, sea = 1.0 },
	breeze = { wind = 0.35, rain = 0.0, sea = 1.0 },
	overcast = { wind = 0.28, rain = 0.0, sea = 1.0 },
	rain = { wind = 0.45, rain = 0.55, sea = 1.0 },
	storm = { wind = 0.80, rain = 1.0, sea = 1.15 },
	snow = { wind = 0.22, rain = 0.0, sea = 1.0 },
}
local mix = { wind = 0.15, rain = 0.0, sea = 1.0 }

local function updateAmbience()
	local host = ambienceHost
	if not host or not host.Parent then
		return
	end
	local proximity = audio.proximityScale(host.Position.Y - SEA)
	local targets = {
		sea = 0.22 * mix.sea * proximity,
		wash = 0.10 * mix.sea * proximity,
		wind = 0.30 * mix.wind,
		rain = 0.30 * mix.rain,
	}
	for key, target in targets do
		local sound = ambienceSounds[key]
		if sound and sound.Parent then
			--: Approach instead of snap, so a respawn fades the sea back in
			--: and a storm arrives like weather rather than like a switch.
			sound.Volume += (target - sound.Volume) * 0.3
		end
	end
end

local function detachAmbience()
	for _, sound in ambienceSounds do
		pcall(function()
			sound:Stop()
			sound:Destroy()
		end)
	end
	ambienceSounds = {}
	ambienceHost = nil
end

--[[
	The sea, following the player.

	Idempotent on purpose: this used to be called on every `state.changed`,
	and each call attached another copy. Now the same live body is a no-op and
	a new one replaces the old cleanly. A body that is destroyed takes its
	sounds with it (they are parented to it); the next attach rebuilds.
]]
function audio.water(body: Instance)
	if not audio.ready then
		audio.start()
	end
	local host: BasePart? = nil
	if body:IsA("BasePart") then
		host = body
	elseif body:IsA("Model") then
		host = body.PrimaryPart or body:FindFirstChildWhichIsA("BasePart")
	end
	if not host then
		return
	end
	if ambienceHost == host and host.Parent then
		updateAmbience()
		return
	end

	detachAmbience()
	local attached: { [string]: Sound } = {}
	for key, cue in LOOP_CUES do
		local ok, sound = pcall(function()
			return Audio.attach(cue, host, { volume = 0 })
		end)
		if ok and sound then
			attached[key] = sound
		end
	end
	ambienceSounds = attached
	ambienceHost = host
	updateAmbience()
end

--: The phase arrives on `WeatherSync`; an unknown phase gets a neutral bed
--: rather than silence.
function audio.setWeather(phase: string?)
	local entry = if phase then WEATHER_MIX[phase] else nil
	entry = entry or { wind = 0.15, rain = 0.0, sea = 1.0 }
	mix.wind, mix.rain, mix.sea = entry.wind, entry.rain, entry.sea
	if ambienceHost then
		updateAmbience()
	end
end

-- =============================== volumes ====================================
--: The Settings panel sends one number per slider (Panels.luau:654,
--: Wire.luau:47, EconomyService.luau:312). "Master music" moves the music
--: group; "Master sound" moves every non-music group, so UI clicks and the
--: world's ambience answer it too.
function audio.setVolumes(settings: any)
	if not settings then
		return
	end
	if not audio.ready then
		audio.start()
	end
	local music = math.clamp(tonumber(settings.music) or audio.settings.music, 0, 1)
	local sfx = math.clamp(tonumber(settings.sfx) or audio.settings.sfx, 0, 1)
	audio.settings.music, audio.settings.sfx = music, sfx
	pcall(function()
		Audio.setVolume("music", music)
		Audio.setVolume("sfx", sfx)
		Audio.setVolume("ui", sfx)
		Audio.setVolume("ambient", sfx)
	end)
end

-- ================================ music =====================================
--[[
	Bring a named track up, crossfading whatever was playing.

	With the empty `MusicSpecs` this is a graceful no-op: an unknown or
	unfilled name plays nothing and errors nowhere. `nil` stops the music.
]]
function audio.setMusic(name: string?)
	if not audio.ready then
		audio.start()
	end
	return pcall(function()
		if name == nil then
			Audio.music(nil, { fade = 1.0 })
			return
		end
		local cue = "music." .. name
		if Audio.defined(cue) then
			Audio.music(cue, { fade = 1.6 })
		end
	end)
end

-- ================================ start =====================================
--: Defined last so the ambience locals above are in scope for the updater --
--: a `local` used before its declaration resolves to a global that is always
--: nil, silently, which is the exact failure ENGINE-FACTS warns about.
function audio.start()
	if audio.ready then
		return
	end
	Audio.defineMany(Audio.Bank.specs())
	Audio.defineMany(localSpecs())
	for name, music in audio.MusicSpecs do
		if music.id ~= "" then
			Audio.define("music." .. name, {
				id = music.id,
				volume = music.volume,
				group = "music",
				looped = true,
			})
		end
	end
	audio.ready = true

	--: One slow updater drives the ambience mix: weather changes, proximity to
	--: the waterline and the approach to a target volume. 4Hz is imperceptible
	--: for a bed that fades, and one coroutine is cheaper than a tween graph.
	task.spawn(function()
		while true do
			task.wait(0.25)
			if ambienceHost then
				updateAmbience()
			end
		end
	end)
end

return audio
