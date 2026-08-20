--!strict
-- L5: audio graph.
--
-- Roblox's audio API is a routed node graph -- players, faders, filters,
-- emitters and listeners joined by `Wire` instances, the same mental model as a
-- mixing desk. That matters far more here than it looks, because this platform
-- is bottlenecked on *uploaded* audio: every source sound needs an ID-verified
-- account and has to clear moderation with unbounded latency.
--
-- A routing graph is the multiplier. One footstep sample through a fader, a
-- pitch shift and a reverb becomes footsteps on stone, in a cave and in a hall.
-- Building the mixer costs nothing and raises the value of each asset that does
-- get through moderation.
--
-- Bus gains come from the token set, in decibels, because that is the unit the
-- decision is actually made in. The conversion to the engine's linear volume
-- happens once, here.
--
-- The classic `Sound` path is kept as a declared fallback rather than as a
-- silent one: an engine build without `AudioPlayer` still gets audio, and the
-- returned mixer says which path it took.

local SoundService = game:GetService("SoundService")

local Tokens = require(script.Parent.Tokens)

local Sound = {}

local OWNED = "WorldKitAudio"

export type Mixer = {
	--- "audio-api" or "classic". Never guess which one is live; read this.
	backend: string,
	root: Instance,
	buses: { [string]: Instance },
	output: Instance?,
	tokenSetId: string,
}

export type PlayOptions = {
	looping: boolean?,
	volumeTrim: number?,
	playbackSpeed: number?,
	autoPlay: boolean?,
}

local function fail(message: string): never
	error("[WorldKit.Sound] " .. message, 3)
end

--- Decibels are how a mixing decision is expressed; the engine wants amplitude.
local function decibelsToLinear(decibels: number): number
	return 10 ^ (decibels / 20)
end

local function classCreatable(className: string): boolean
	local ok, instance = pcall(Instance.new, className)
	if ok and instance then
		instance:Destroy()
		return true
	end
	return false
end

local audioApiAvailable: boolean? = nil

function Sound.hasAudioApi(): boolean
	if audioApiAvailable == nil then
		audioApiAvailable = classCreatable("AudioPlayer")
			and classCreatable("AudioEmitter")
			and classCreatable("Wire")
			and classCreatable("AudioDeviceOutput")
	end
	return audioApiAvailable :: boolean
end

function Sound._resetCapabilities()
	audioApiAvailable = nil
end

local function wire(source: Instance, target: Instance, parent: Instance): Instance
	-- Cast once into a local rather than at each assignment. `;(x :: any).y = z`
	-- is legal Luau in some positions and a parse error in others, and a module
	-- that compiles today because of statement adjacency is a trap.
	local link: any = Instance.new("Wire")
	link.SourceInstance = source
	link.TargetInstance = target
	link:SetAttribute(OWNED, true)
	link.Parent = parent
	return link
end

--- Build the mixer: one fader per declared bus, wired to the device output.
---
--- Idempotent by teardown, like `Mood.apply`: a second call replaces the graph
--- rather than layering a second full mix under the first.
function Sound.mixer(tokens: Tokens.TokenSet, parent: Instance?): Mixer
	local host = parent or SoundService
	for _, child in ipairs(host:GetChildren()) do
		if child:GetAttribute(OWNED) == true and child.Name == "WorldKitMixer" then
			child:Destroy()
		end
	end

	local root = Instance.new("Folder")
	root.Name = "WorldKitMixer"
	root:SetAttribute(OWNED, true)
	root.Parent = host

	local busIds: { string } = {}
	for busId in pairs(tokens.raw.audio.buses) do
		table.insert(busIds, busId)
	end
	table.sort(busIds)

	if not Sound.hasAudioApi() then
		-- Classic path: a SoundGroup per bus. Less capable, honestly labelled.
		local buses: { [string]: Instance } = {}
		for _, busId in ipairs(busIds) do
			local group = Instance.new("SoundGroup")
			group.Name = busId
			group.Volume = decibelsToLinear(tokens:bus(busId).gainDb)
			group:SetAttribute(OWNED, true)
			group.Parent = root
			buses[busId] = group
		end
		root:SetAttribute("AudioBackend", "classic")
		return {
			backend = "classic",
			root = root,
			buses = buses,
			output = nil,
			tokenSetId = tokens.id,
		}
	end

	local output = Instance.new("AudioDeviceOutput")
	output.Name = "Output"
	output:SetAttribute(OWNED, true)
	output.Parent = root

	local buses: { [string]: Instance } = {}
	for _, busId in ipairs(busIds) do
		local definition = tokens:bus(busId)
		local fader: any = Instance.new("AudioFader")
		fader.Name = busId
		fader.Volume = decibelsToLinear(definition.gainDb)
		fader:SetAttribute(OWNED, true)
		fader:SetAttribute("Routing", definition.routing)
		fader:SetAttribute("GainDb", definition.gainDb)
		fader.Parent = root
		buses[busId] = fader

		-- Only non-spatial buses reach the device directly. A bus routed through
		-- emitters must not also play flat, or every world sound is heard twice:
		-- once positioned and once glued to the player's head.
		if definition.routing == "device" then
			wire(fader, output, root)
		end
	end

	root:SetAttribute("AudioBackend", "audio-api")
	return {
		backend = "audio-api",
		root = root,
		buses = buses,
		output = output,
		tokenSetId = tokens.id,
	}
end

--- Declared before every use on purpose. A helper referenced above its own
--- definition is the exact defect that once killed an entire HUD in this
--- repository with no error anywhere: the lookup happens at call time, so it
--- works until the day something calls it during module load.
local function routedToDevice(mixer: Mixer, busId: string): boolean
	local bus = mixer.buses[busId]
	return bus ~= nil and bus:GetAttribute("Routing") == "device"
end

local function requireBus(mixer: Mixer, busId: string): Instance
	local bus = mixer.buses[busId]
	if bus == nil then
		local available = {}
		for id in pairs(mixer.buses) do
			table.insert(available, id)
		end
		table.sort(available)
		fail(string.format("unknown audio bus %q; available: %s", tostring(busId), table.concat(available, ", ")))
	end
	return bus
end

--- Play a non-spatial sound on a bus. Music, UI, stingers.
function Sound.play(mixer: Mixer, busId: string, assetId: string, options: PlayOptions?): Instance
	local bus = requireBus(mixer, busId)
	local opts = options or {}

	if mixer.backend == "classic" then
		local sound = Instance.new("Sound")
		sound.SoundId = assetId
		sound.Looped = opts.looping == true
		sound.PlaybackSpeed = opts.playbackSpeed or 1
		sound.Volume = opts.volumeTrim or 1
		sound.SoundGroup = bus :: SoundGroup
		sound:SetAttribute(OWNED, true)
		sound.Parent = mixer.root
		if opts.autoPlay ~= false then
			sound:Play()
		end
		return sound
	end

	local player: any = Instance.new("AudioPlayer")
	player.AssetId = assetId
	player.Looping = opts.looping == true
	player.PlaybackSpeed = opts.playbackSpeed or 1
	if opts.volumeTrim ~= nil then
		player.Volume = opts.volumeTrim
	end
	player:SetAttribute(OWNED, true)
	player.Parent = mixer.root
	wire(player, bus, mixer.root)
	if opts.autoPlay ~= false then
		player:Play()
	end
	return player
end

--- Play a positioned sound from a part. Machines, ambience, footsteps.
function Sound.emit(mixer: Mixer, busId: string, host: BasePart, assetId: string, options: PlayOptions?): Instance
	local bus = requireBus(mixer, busId)
	local opts = options or {}

	if mixer.backend == "classic" then
		local sound = Instance.new("Sound")
		sound.SoundId = assetId
		sound.Looped = opts.looping == true
		sound.PlaybackSpeed = opts.playbackSpeed or 1
		sound.Volume = opts.volumeTrim or 1
		sound.SoundGroup = bus :: SoundGroup
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound:SetAttribute(OWNED, true)
		sound.Parent = host
		if opts.autoPlay ~= false then
			sound:Play()
		end
		return sound
	end

	local player: any = Instance.new("AudioPlayer")
	player.AssetId = assetId
	player.Looping = opts.looping == true
	player.PlaybackSpeed = opts.playbackSpeed or 1
	player:SetAttribute(OWNED, true)
	player.Parent = host

	local emitter = host:FindFirstChildOfClass("AudioEmitter")
	if emitter == nil then
		emitter = Instance.new("AudioEmitter")
		emitter.Name = "Emitter"
		emitter:SetAttribute(OWNED, true)
		emitter.Parent = host
	end

	wire(player, bus, host)
	wire(bus, emitter :: Instance, host)
	if opts.autoPlay ~= false then
		player:Play()
	end
	return player
end

--- Put a listener on the thing that hears. Without one, emitters are silent.
function Sound.listener(mixer: Mixer, host: Instance): Instance?
	if mixer.backend == "classic" then
		return nil
	end
	local existing = host:FindFirstChildOfClass("AudioListener")
	if existing ~= nil then
		return existing
	end
	local listener = Instance.new("AudioListener")
	listener.Name = "Listener"
	listener:SetAttribute(OWNED, true)
	listener.Parent = host
	if mixer.output ~= nil then
		wire(listener, mixer.output, host)
	end
	return listener
end

--- Insert an effect between a bus and everything downstream of it.
---
--- The reason the mixer exists: one uploaded sample plus a filter chain covers
--- several distinct-sounding cues, which is what makes a moderation-limited
--- audio budget survivable.
function Sound.insert(mixer: Mixer, busId: string, className: string, properties: { [string]: any }?): Instance?
	if mixer.backend == "classic" then
		return nil
	end
	local bus = requireBus(mixer, busId)
	if not classCreatable(className) then
		return nil
	end
	local effect = Instance.new(className)
	effect:SetAttribute(OWNED, true)
	for property, value in pairs(properties or {}) do
		pcall(function()
			(effect :: any)[property] = value
		end)
	end
	effect.Parent = mixer.root
	wire(bus, effect, mixer.root)
	if mixer.output ~= nil and routedToDevice(mixer, busId) then
		wire(effect, mixer.output, mixer.root)
	end
	return effect
end

--- Tear the whole graph down.
function Sound.clear(mixer: Mixer): number
	local removed = 0
	for _, descendant in ipairs(mixer.root:GetDescendants()) do
		if descendant:GetAttribute(OWNED) == true then
			removed += 1
		end
	end
	mixer.root:Destroy()
	return removed
end

return Sound
