--!strict
--[[
	Audio — sound as data, pooled, grouped and ducked.

	`Feel` was built on the argument that impact is where "functional" becomes
	"professional", and then shipped only the half you can see. A hit with a
	particle and no sound has no weight; a hit with a sound and no particle
	still lands.

		Audio.define("hit.blade", {
			id = "rbxassetid://9118823103",
			volume = 0.6,
			pitch = { 0.92, 1.08 },     -- randomised per play
			group = "sfx",
		})

		Audio.playAt("hit.blade", position)
		Audio.music("combat", { fade = 1.5 })
		Audio.duck(0.35, 0.8)           -- pull music down for a stinger

	Three things that separate this from `Instance.new("Sound")` at the call site:

	  * **Pitch variation by default.** The same sample at the same pitch twelve
	    times in five seconds is the single most fatiguing thing in a game, and
	    a two-element range fixes it forever.
	  * **Pooling.** Creating and destroying a Sound per hit allocates during
	    exactly the moment the frame is busiest.
	  * **Groups.** Master/music/sfx/ui/ambient exist from the start, so a
	    settings slider is one line and never has to be retrofitted.
]]

local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Signal = require(script.Parent.Core.Signal)

local Access = require(script.Parent.Access)

local Audio = {}

Audio.missing = Signal.new() -- (id)

export type Spec = {
	id: string | { string }, -- one asset, or a set to pick from
	volume: number?,
	pitch: (number | { number })?,
	group: string?,
	rollOffMin: number?,
	rollOffMax: number?,
	looped: boolean?,
	cooldown: number?, -- minimum seconds between plays of this cue
	[string]: any,
}

local specs: { [string]: Spec } = {}
local groups: { [string]: SoundGroup } = {}
local pool: { Sound } = {}
local lastPlayed: { [string]: number } = {}
local warned: { [string]: boolean } = {}
local musicTrack: Sound? = nil
local musicName: string? = nil
local duckTween: Tween? = nil
local stats = { played = 0, pooled = 0, missing = 0 }

Audio.config = {
	poolSize = 48,
	defaultRollOffMin = 12,
	defaultRollOffMax = 140,
	musicVolume = 0.35,
	enabled = true,
}

-- ================================= groups ===================================
local GROUP_NAMES = { "master", "music", "sfx", "ui", "ambient" }

local function ensureGroups()
	if groups.master then
		return
	end
	local master = SoundService:FindFirstChild("master") :: SoundGroup?
	if not master then
		master = Instance.new("SoundGroup")
		master.Name = "master"
		master.Volume = 1
		master.Parent = SoundService
	end
	groups.master = master

	for _, name in GROUP_NAMES do
		if name == "master" then
			continue
		end
		local existing = master:FindFirstChild(name) :: SoundGroup?
		if not existing then
			existing = Instance.new("SoundGroup")
			existing.Name = name
			existing.Volume = 1
			existing.Parent = master
		end
		groups[name] = existing
	end
end

function Audio.setVolume(group: string, volume: number)
	ensureGroups()
	local target = groups[group]
	if target then
		target.Volume = math.clamp(volume, 0, 1)
	end
end

function Audio.volume(group: string): number
	ensureGroups()
	return groups[group] and groups[group].Volume or 1
end

-- ================================ definition ================================
function Audio.define(name: string, spec: Spec)
	specs[name] = spec
end

function Audio.defineMany(table_: { [string]: Spec })
	for name, spec in table_ do
		Audio.define(name, spec)
	end
end

function Audio.defined(name: string): boolean
	return specs[name] ~= nil
end

function Audio.names(): { string }
	local out = {}
	for name in specs do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- ================================= pooling ==================================
local function take(): Sound
	local sound = table.remove(pool)
	if sound then
		stats.pooled += 1
		return sound
	end
	return Instance.new("Sound")
end

local function give(sound: Sound)
	if #pool >= Audio.config.poolSize then
		sound:Destroy()
		return
	end
	sound.Parent = nil
	sound.SoundGroup = nil
	sound.PlaybackSpeed = 1
	sound.Volume = 0.5
	sound.Looped = false
	table.insert(pool, sound)
end

local function resolve(spec: Spec): (string, number)
	local id = spec.id
	if type(id) == "table" then
		id = id[math.random(1, #id)]
	end

	local pitch = 1
	if type(spec.pitch) == "number" then
		pitch = spec.pitch :: number
	elseif type(spec.pitch) == "table" then
		local range = spec.pitch :: { number }
		pitch = range[1] + math.random() * (range[2] - range[1])
	end
	return id :: string, pitch
end

local function configure(sound: Sound, spec: Spec)
	ensureGroups()
	local id, pitch = resolve(spec)
	sound.SoundId = id
	sound.Volume = spec.volume or 0.5
	sound.PlaybackSpeed = pitch
	sound.Looped = spec.looped == true
	sound.RollOffMinDistance = spec.rollOffMin or Audio.config.defaultRollOffMin
	sound.RollOffMaxDistance = spec.rollOffMax or Audio.config.defaultRollOffMax
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.SoundGroup = groups[spec.group or "sfx"]
end

local function gate(name: string, spec: Spec): boolean
	if not Audio.config.enabled then
		return false
	end
	if not spec.cooldown then
		return true
	end
	local now = os.clock()
	if now - (lastPlayed[name] or -math.huge) < spec.cooldown then
		return false
	end
	lastPlayed[name] = now
	return true
end

local function lookup(name: string): Spec?
	local spec = specs[name]
	if not spec then
		if not warned[name] then
			warned[name] = true
			-- Loud once, never again: a missing cue in a hot loop must not
			-- become the thing that fills the output window.
			warn(string.format("[Audio] no cue named '%s'", name))
		end
		stats.missing += 1
		Audio.missing:Fire(name)
	end
	return spec
end

-- ================================ playback ==================================
-- 2D: UI, stingers, anything not in the world.
function Audio.play(name: string, options: any?): Sound?
	local spec = lookup(name)
	if not spec or not gate(name, spec) then
		return nil
	end

	--[[
		Caption it, if it has one.

		Every cue here already has a name; a subtitle is a caption on a name
		that exists. Doing it in the engine rather than at each call site is
		what stops half a game's sounds from going uncaptioned — nobody
		remembers at the eightieth `Audio.play`.
	]]
	Access.announce(name)
	local opts = options or {}

	local sound = take()
	configure(sound, spec)
	if opts.volume then
		sound.Volume = opts.volume
	end
	if opts.pitch then
		sound.PlaybackSpeed = opts.pitch
	end
	sound.Parent = SoundService
	sound:Play()
	stats.played += 1

	if not sound.Looped then
		task.delay(math.max(sound.TimeLength, 0.2) + 0.3, function()
			sound:Stop()
			give(sound)
		end)
	end
	return sound
end

-- 3D: attached to a throwaway part at a position.
function Audio.playAt(name: string, position: Vector3, options: any?): Sound?
	local spec = lookup(name)
	if not spec or not gate(name, spec) then
		return nil
	end
	local opts = options or {}

	local anchor = Instance.new("Part")
	anchor.Size = Vector3.one * 0.1
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace

	local sound = Instance.new("Sound")
	configure(sound, spec)
	if opts.volume then
		sound.Volume = opts.volume
	end
	sound.Parent = anchor
	sound:Play()
	stats.played += 1

	Debris:AddItem(anchor, math.max(sound.TimeLength, 0.3) + 0.5)
	return sound
end

-- 3D and moving: follows an instance for as long as it lives.
function Audio.attach(name: string, instance: Instance, options: any?): Sound?
	local spec = lookup(name)
	if not spec or not gate(name, spec) then
		return nil
	end
	local host = instance:IsA("BasePart") and instance
		or (instance:IsA("Model") and (instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")))
	if not host then
		return nil
	end

	local sound = Instance.new("Sound")
	configure(sound, spec)
	if options and options.volume then
		sound.Volume = options.volume
	end
	sound.Parent = host
	sound:Play()
	stats.played += 1

	if not sound.Looped then
		Debris:AddItem(sound, math.max(sound.TimeLength, 0.3) + 0.5)
	end
	return sound
end

-- ================================== music ===================================
--[[
	Crossfade between named tracks. Calling it with the track already playing is
	a no-op, so a system can assert its music every frame without restarting it —
	which is exactly how music restarts get shipped.
]]
function Audio.music(name: string?, options: any?)
	local opts = options or {}
	local fade = opts.fade or 1.5

	if name == musicName then
		return
	end
	musicName = name

	local previous = musicTrack
	if previous then
		local out = TweenService:Create(previous, TweenInfo.new(fade), { Volume = 0 })
		out.Completed:Connect(function()
			previous:Stop()
			previous:Destroy()
		end)
		out:Play()
		musicTrack = nil
	end

	if not name then
		return
	end
	local spec = lookup(name)
	if not spec then
		return
	end

	ensureGroups()
	local sound = Instance.new("Sound")
	configure(sound, spec)
	sound.Looped = true
	sound.SoundGroup = groups.music
	local target = opts.volume or spec.volume or Audio.config.musicVolume
	sound.Volume = 0
	sound.Parent = SoundService
	sound:Play()
	TweenService:Create(sound, TweenInfo.new(fade), { Volume = target }):Play()
	musicTrack = sound
end

function Audio.playingMusic(): string?
	return musicName
end

--[[
	Pull music down so something else can be heard, then bring it back.
	A level-up, a boss line, a death — anything that must land over the mix.
]]
function Audio.duck(amount: number, seconds: number?)
	ensureGroups()
	local music = groups.music
	if not music then
		return
	end
	if duckTween then
		duckTween:Cancel()
	end
	local restore = 1
	music.Volume = math.clamp(amount, 0, 1)
	duckTween = TweenService:Create(music, TweenInfo.new(seconds or 0.8), { Volume = restore })
	;(duckTween :: Tween):Play()
end

function Audio.stopAll()
	Audio.music(nil, { fade = 0.2 })
	for _, sound in pool do
		sound:Stop()
	end
end

function Audio.describe(): { [string]: any }
	if not RunService:IsClient() then
		-- Sound is defined and played client-side. An empty server-side report
		-- reads as "no audio in this game", which is the opposite of the truth.
		return { context = "client-only", appliesHere = false }
	end
	ensureGroups()
	local volumes: { [string]: number } = {}
	for name, group in groups do
		volumes[name] = group.Volume
	end

	-- A cue defined and never played through a whole session is usually a cue
	-- whose trigger never fires.
	local unused = {}
	for name in specs do
		if lastPlayed[name] == nil then
			table.insert(unused, name)
		end
	end
	table.sort(unused)

	return {
		cues = #Audio.names(),
		played = stats.played,
		fromPool = stats.pooled,
		missing = stats.missing,
		pooled = #pool,
		music = musicName,
		volumes = volumes,
		neverPlayed = unused,
	}
end

return Audio
