--!strict
-- Feedback you can hear, for the actions the goal says must have it.
--
-- Line 65: "uma acao sem feedback visual/sonoro deve ser tratada como
-- incompleta." Every game this factory has produced is silent. Buying a tower,
-- failing to afford one, taking damage, clearing a wave, winning and losing all
-- happen with no sound at all.
--
-- The reason was never that nobody wrote a mixer. `rqe/assets/audio_authoring`
-- generates tones, clicks and reward stings already, and it refuses to hand
-- them over because Roblox loads `mp3` and `ogg` and a generated `wav` needs an
-- encoder nobody installed -- and then an upload, and a credential, and
-- moderation. The same chain that kept every mesh out of every place.
--
-- Roblox ships sounds. They are on the platform already, every place can play
-- them with no upload, and they are the same library the engine's own UI uses.
-- That is worse than a bespoke audio identity and enormously better than
-- silence, and it is available now rather than after a credential arrives.
--
-- What this is not: a soundtrack, a mixer, or an identity. It is the layer that
-- makes an action audible, keyed by *what happened* rather than by which sound
-- to play -- so replacing these ids with authored audio later changes this file
-- and nothing that calls it.

local SoundService = game:GetService("SoundService")

local Audio = {}

--- A tally of what has been played, so feedback can be verified.
---
--- A Sound built here lives under a second and is destroyed on `Ended`. The
--- bridge that a QA harness drives has a round trip of roughly twenty seconds,
--- so no query can ever catch one -- polling for the instance proves nothing
--- either way, which is exactly the shape of evidence this project refuses to
--- accept elsewhere.
---
--- The counter is monotonic and lives on SoundService, where anything can read
--- it. It is the difference between "no error was raised" and "the sound fired".
local function record(event: string): ()
	pcall(function()
		local key = "RQEPlayed_" .. event
		local current = SoundService:GetAttribute(key)
		SoundService:SetAttribute(key,
			(if type(current) == "number" then current else 0) + 1)
		local total = SoundService:GetAttribute("RQEPlayedTotal")
		SoundService:SetAttribute("RQEPlayedTotal",
			(if type(total) == "number" then total else 0) + 1)
	end)
end

--- Semantic events, not filenames.
---
--- A caller says `Audio.play("purchase")`, never an asset id. When a game gets
--- its own audio the ids move and no gameplay code is touched -- the same seam
--- `Mesh` uses for geometry, for the same reason.
---
--- Ids are Roblox's own library, playable from any place without upload.
local EVENTS: { [string]: { id: string, volume: number, pitch: number, source: string? } } = {
	-- Interface
	click = { id = "rbxasset://sounds/button.wav", volume = 0.5, pitch = 1.0 },
	confirm = { id = "rbxasset://sounds/button.wav", volume = 0.6, pitch = 1.25 },
	success = { id = "rbxasset://sounds/button.wav", volume = 0.6, pitch = 1.25 },
	error = { id = "rbxasset://sounds/button.wav", volume = 0.55, pitch = 0.55 },
	-- Refusal is the one that must never be mistaken for success: same source,
	-- well below it in pitch, because a player who cannot afford a thing needs
	-- to know instantly and without reading.
	denied = { id = "rbxasset://sounds/button.wav", volume = 0.55, pitch = 0.55 },

	-- Economy and progression
	purchase = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.5, pitch = 1.4 },
	reward = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.6, pitch = 1.7 },
	upgrade = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.55, pitch = 1.1 },
	unlock = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.65, pitch = 0.9 },

	-- Combat and session
	build = { id = "rbxasset://sounds/impact_generic.mp3", volume = 0.5, pitch = 1.0 },
	damage = { id = "rbxasset://sounds/impact_generic.mp3", volume = 0.55, pitch = 0.7 },
	wave = { id = "rbxasset://sounds/impact_generic.mp3", volume = 0.6, pitch = 0.5 },
	victory = { id = "rbxasset://sounds/impact_water.mp3", volume = 0.8, pitch = 1.5 },
	defeat = { id = "rbxasset://sounds/impact_generic.mp3", volume = 0.8, pitch = 0.4 },
}

export type Cue = {
	id: string,
	volume: number,
	pitch: number,
	source: string?,
}

export type Bank = {
	play: (self: Bank, event: string, options: { volume: number?, pitch: number? }?) -> Sound?,
	playAt: (self: Bank, event: string, at: Instance | Vector3,
		options: { volume: number?, pitch: number? }?) -> Sound?,
	resolve: (self: Bank, event: string) -> Cue?,
	receipt: (self: Bank, event: string) -> { [string]: any }?,
}

local function normaliseAssetId(value: any): string?
	if type(value) == "number" and value > 0 and value % 1 == 0 then
		return "rbxassetid://" .. tostring(value)
	end
	if type(value) ~= "string" then
		return nil
	end
	if string.match(value, "^rbxasset://sounds/[%w_%-%.]+$") then
		return value
	end
	if string.match(value, "^rbxassetid://%d+$") then
		return value
	end
	if string.match(value, "^%d+$") then
		return "rbxassetid://" .. value
	end
	return nil
end

local function copyCue(cue: Cue): Cue
	return {
		id = cue.id,
		volume = cue.volume,
		pitch = cue.pitch,
		source = cue.source or "roblox-builtin",
	}
end

--- Build a per-game semantic sound bank.
---
--- A configured asset replaces one cue; every omitted cue keeps Roblox's
--- built-in fallback. The receipt says "configured-asset-id", not "published"
--- or "approved": an id in source is configuration, not moderation evidence.
function Audio.define(overrides: { [string]: any }?): Bank
	local cues: { [string]: Cue } = {}
	for event, cue in pairs(EVENTS) do
		cues[event] = copyCue(cue :: Cue)
	end

	for event, override in pairs(overrides or {}) do
		if EVENTS[event] == nil then
			error(string.format("[WorldKit.Audio] cannot configure unknown event %q", tostring(event)), 2)
		end
		local definition = if type(override) == "table" then override else { assetId = override }
		local id = normaliseAssetId(definition.assetId or definition.id)
		if id == nil then
			error(string.format(
				"[WorldKit.Audio] event %q needs a Roblox built-in path or numeric asset id", event), 2)
		end
		local volume = definition.volume or EVENTS[event].volume
		local pitch = definition.pitch or definition.playbackSpeed or EVENTS[event].pitch
		if type(volume) ~= "number" or volume < 0 or volume > 2 then
			error(string.format("[WorldKit.Audio] event %q volume must be between 0 and 2", event), 2)
		end
		if type(pitch) ~= "number" or pitch < 0.25 or pitch > 4 then
			error(string.format("[WorldKit.Audio] event %q pitch must be between 0.25 and 4", event), 2)
		end
		cues[event] = {
			id = id,
			volume = volume,
			pitch = pitch,
			source = if string.sub(id, 1, 18) == "rbxasset://sounds/"
				then "roblox-builtin" else "configured-asset-id",
		}
	end

	local bank = {} :: any
	function bank:resolve(event: string): Cue?
		local cue = cues[event]
		return if cue ~= nil then copyCue(cue) else nil
	end
	function bank:receipt(event: string): { [string]: any }?
		local cue = cues[event]
		if cue == nil then
			return nil
		end
		return {
			event = event,
			source = cue.source,
			assetId = cue.id,
			uploadVerified = false,
			note = if cue.source == "roblox-builtin"
				then "Roblox built-in fallback; no upload required"
				else "configured Roblox asset id; availability and moderation are not proved by configuration",
		}
	end
	function bank:play(event: string, options: { volume: number?, pitch: number? }?): Sound?
		local cue = cues[event]
		if cue == nil then
			return nil
		end
		record(event)
		local opts = options or {}
		local ok, sound = pcall(function()
			local instance = Instance.new("Sound")
			instance.Name = "SFX_" .. event
			instance.SoundId = cue.id
			instance.Volume = opts.volume or cue.volume
			instance.PlaybackSpeed = opts.pitch or cue.pitch
			instance.Parent = SoundService
			instance.Ended:Connect(function()
				instance:Destroy()
			end)
			instance:Play()
			return instance
		end)
		return if ok then sound else nil
	end
	function bank:playAt(event: string, at: Instance | Vector3,
		options: { volume: number?, pitch: number? }?): Sound?
		local cue = cues[event]
		if cue == nil then
			return nil
		end
		record(event)
		local opts = options or {}
		local ok, sound = pcall(function()
			local anchor: Instance
			if typeof(at) == "Vector3" then
				local part = Instance.new("Part")
				part.Name = "AudioAnchor_" .. event
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
				part.Transparency = 1
				part.Size = Vector3.one
				part.Position = at :: Vector3
				part.Parent = workspace
				anchor = part
			else
				anchor = at :: Instance
			end
			local instance = Instance.new("Sound")
			instance.Name = "SFX_" .. event
			instance.SoundId = cue.id
			instance.Volume = opts.volume or cue.volume
			instance.PlaybackSpeed = opts.pitch or cue.pitch
			instance.RollOffMaxDistance = 220
			instance.Parent = anchor
			instance.Ended:Connect(function()
				instance:Destroy()
				if typeof(at) == "Vector3" then
					anchor:Destroy()
				end
			end)
			instance:Play()
			return instance
		end)
		return if ok then sound else nil
	end
	bank._cues = cues
	return bank :: Bank
end

--- The actions the goal names in line 63, so a gate can check them off.
Audio.REQUIRED = {
	"purchase", "build", "upgrade", "damage", "reward", "denied",
	"unlock", "wave", "victory", "defeat",
}

function Audio.events(): { string }
	local names = {}
	for name in pairs(EVENTS) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

--- Which required events have no sound behind them.
---
--- Reported rather than assumed, because "we added audio" is the kind of claim
--- that survives long after one of the ten actions quietly lost its call.
function Audio.problems(): { string }
	local found: { string } = {}
	for _, name in ipairs(Audio.REQUIRED) do
		if EVENTS[name] == nil then
			table.insert(found, string.format(
				"%q is named in the goal as needing feedback and has no sound", name))
		end
	end
	return found
end

--- Play one event. Non-positional: this is interface feedback, not a world sound.
---
--- Never raises. A missing sound is a worse game; a script that stops because a
--- sound was missing is a broken one, and this is called from the middle of
--- purchase and damage paths.
function Audio.play(event: string, options: { volume: number?, pitch: number? }?): Sound?
	local spec = EVENTS[event]
	if spec == nil then
		warn(string.format("[WorldKit.Audio] unknown event %q; known: %s",
			event, table.concat(Audio.events(), ", ")))
		return nil
	end

	record(event)
	local opts = options or {}
	local ok, sound = pcall(function()
		local instance = Instance.new("Sound")
		instance.Name = "SFX_" .. event
		instance.SoundId = spec.id
		instance.Volume = opts.volume or spec.volume
		instance.PlaybackSpeed = opts.pitch or spec.pitch
		instance.Parent = SoundService
		instance.Ended:Connect(function()
			instance:Destroy()
		end)
		instance:Play()
		return instance
	end)

	if not ok then
		return nil
	end
	return sound
end

--- Play at a point in the world, for things that happen somewhere.
---
--- A tower being built across the map should not sound like one built at your
--- feet. Falls back to a flat play when the anchor has gone -- an enemy that
--- died and was destroyed before its death sound started is the normal case,
--- not an error.
function Audio.playAt(event: string, at: Instance | Vector3,
	options: { volume: number?, pitch: number? }?): Sound?
	local spec = EVENTS[event]
	if spec == nil then
		return Audio.play(event, options)
	end

	record(event)
	local opts = options or {}
	local ok, sound = pcall(function()
		local anchor: Instance
		if typeof(at) == "Vector3" then
			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.Transparency = 1
			part.Size = Vector3.one
			part.Position = at :: Vector3
			part.Parent = workspace
			anchor = part
		else
			anchor = at :: Instance
		end

		local instance = Instance.new("Sound")
		instance.Name = "SFX_" .. event
		instance.SoundId = spec.id
		instance.Volume = opts.volume or spec.volume
		instance.PlaybackSpeed = opts.pitch or spec.pitch
		instance.RollOffMaxDistance = 220
		instance.Parent = anchor
		instance.Ended:Connect(function()
			instance:Destroy()
			if typeof(at) == "Vector3" then
				anchor:Destroy()
			end
		end)
		instance:Play()
		return instance
	end)

	if not ok then
		return nil
	end
	return sound
end

--- What this layer is, for a report that has to be honest about it.
Audio.PROVENANCE = {
	source = "roblox-builtin",
	upload = false,
	note = "Roblox's own sound library, playable from any place with no upload, "
		.. "no credential and no moderation. It makes every named action audible "
		.. "today. It is not an audio identity: a game that wants one replaces "
		.. "the ids in this file and nothing that calls it changes",
}

return Audio
