--!strict
--- Rooms that sound like rooms.
---
--- `Sound` has a mixer, buses and the ability to insert effects, and every
--- place built with it sounded identical everywhere. A cathedral and a
--- corridor and the open hillside outside it all shared one reverb, which is
--- the audio equivalent of lighting a whole game with one flat ambient.
---
--- Acoustics is the cheapest signal a player never consciously notices. Walk
--- into a cave and hear the tail lengthen and you know you are inside before
--- you have looked at anything. Nothing on screen has to change.
---
--- **The hard part is not the reverb, it is the boundary.** A player standing
--- on the edge of a zone crosses it several times a second, and switching
--- reverb on every crossing produces a stutter that is far worse than having no
--- zones at all. So a zone change has to be *held* before it is believed: the
--- listener must be inside the new space for a few consecutive samples. That is
--- hysteresis, and it is the whole reason this module exists rather than a
--- three-line `Touched` handler.
---
--- **Zones are volumes, not parts.** A region is data, so a zone can be
--- declared before the geometry exists and does not care whether the room was
--- built from parts, terrain or a mesh.

local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Acoustics = {}

--- Resolve a reverb by name, lazily, and say which name was wrong when it is.
---
--- Two lessons are baked into this one function.
---
--- `Enum.ReverbType.Concerthall` -- the real spelling is `ConcertHall` -- took
--- the whole module down with "Requested module experienced an error while
--- loading", which names neither the enum nor the line. Indexing a missing enum
--- member raises, so one character of casing costs every function in the file.
--- Hence resolving by string and naming every valid option on failure.
---
--- But the first version of *that* fix resolved at module load, and the
--- headless SDK harness has no `Enum.ReverbType` at all: `attempt to index nil
--- with 'GetEnumItems'`. Loading a module must not depend on the engine's enum
--- table -- that is exactly the property the harness exists to check, and
--- breaking it took `WorldKit.Threat` off the public surface as collateral.
---
--- So the table below holds names, and this resolves on first use and caches.
local resolved: { [string]: any } = {}

local function reverb(name: string): any
	local cached = resolved[name]
	if cached ~= nil then
		return cached
	end
	local kind = (Enum :: any).ReverbType
	if kind == nil then
		return nil
	end
	for _, item in ipairs(kind:GetEnumItems()) do
		if item.Name == name then
			resolved[name] = item
			return item
		end
	end
	local names = {}
	for _, item in ipairs(kind:GetEnumItems()) do
		table.insert(names, item.Name)
	end
	error(("no Enum.ReverbType.%s; have %s"):format(name, table.concat(names, ", ")), 0)
end

--- Named spaces: a reverb *name*, and how loud the space's own voice is.
---
--- The names are architectural rather than technical on purpose. A caller
--- describing a scene knows they are writing a cave; they do not know they want
--- `Enum.ReverbType.Cave` with a 0.55 wet mix.
local SPACES: { [string]: { reverb: string, weight: number, note: string } } = {
	outdoors = { reverb = "NoReverb", weight = 0,
		note = "open air: no tail, nothing to reflect off" },
	forest = { reverb = "Forest", weight = 0.2,
		note = "soft, absorbed, slightly close" },
	room = { reverb = "Room", weight = 0.3,
		note = "domestic: short tail, present" },
	hall = { reverb = "Hallway", weight = 0.45,
		note = "corridors: narrow and reflective" },
	stone = { reverb = "StoneCorridor", weight = 0.55,
		note = "hard surfaces, long slap" },
	cave = { reverb = "Cave", weight = 0.6,
		note = "deep and irregular; the one that reads as underground" },
	cathedral = { reverb = "ConcertHall", weight = 0.7,
		note = "very long tail; makes a space feel tall" },
	underwater = { reverb = "UnderWater", weight = 0.8,
		note = "muffled and enclosing" },
	arena = { reverb = "Arena", weight = 0.5,
		note = "large, open, hard-walled" },
	sewer = { reverb = "SewerPipe", weight = 0.65,
		note = "tight, tubular, unpleasant on purpose" },
}

export type Zone = {
	name: string,
	space: string,
	centre: Vector3,
	size: Vector3,
	--- Larger wins where zones overlap. A cave inside a forest needs to beat it.
	priority: number,
}

type State = {
	zones: { Zone },
	default: string,
	current: string,
	candidate: string?,
	held: number,
	connection: RBXScriptConnection?,
	accumulator: number,
	changes: number,
}

local state: State? = nil

--- How many consecutive samples a new space must win before it is applied.
---
--- At the 5Hz sample rate below this is about half a second of commitment. Less
--- and a player leaning through a doorway makes the room flicker; more and
--- walking into a cave takes a noticeable beat to be heard.
local HOLD_SAMPLES = 3

local SAMPLE_INTERVAL = 0.2

function Acoustics.spaces(): { [string]: any }
	local out: { [string]: any } = {}
	for name, space in pairs(SPACES) do
		out[name] = { reverb = space.reverb, weight = space.weight, note = space.note }
	end
	return out
end

--- Everything wrong with a set of zones, before any of it is heard.
function Acoustics.problems(zones: { Zone }, default: string?): { string }
	local found = {}
	if default ~= nil and SPACES[default] == nil then
		local names = {}
		for name in pairs(SPACES) do table.insert(names, name) end
		table.sort(names)
		table.insert(found, ("default space %q is not one of %s"):format(
			tostring(default), table.concat(names, ", ")))
	end
	local seen: { [string]: boolean } = {}
	for index, zone in ipairs(zones) do
		local label = tostring(zone.name or ("zone " .. index))
		if type(zone.name) ~= "string" or zone.name == "" then
			table.insert(found, ("zone %d has no name"):format(index))
		elseif seen[zone.name] then
			table.insert(found, ("two zones are called %q"):format(zone.name))
		else
			seen[zone.name] = true
		end
		if SPACES[zone.space] == nil then
			local names = {}
			for name in pairs(SPACES) do table.insert(names, name) end
			table.sort(names)
			table.insert(found, ("%s: no space %q; have %s"):format(
				label, tostring(zone.space), table.concat(names, ", ")))
		end
		if typeof(zone.size) ~= "Vector3" or zone.size.X <= 0
			or zone.size.Y <= 0 or zone.size.Z <= 0 then
			table.insert(found, label .. ": size must be positive on all three axes")
		end
	end
	return found
end

local function contains(zone: Zone, point: Vector3): boolean
	local half = zone.size * 0.5
	local delta = point - zone.centre
	return math.abs(delta.X) <= half.X
		and math.abs(delta.Y) <= half.Y
		and math.abs(delta.Z) <= half.Z
end

--- Which space the listener is standing in right now, ignoring hysteresis.
function Acoustics.spaceAt(point: Vector3): string
	local live = state
	if live == nil then
		return "outdoors"
	end
	local best, bestPriority = live.default, -math.huge
	for _, zone in ipairs(live.zones) do
		if zone.priority > bestPriority and contains(zone, point) then
			best, bestPriority = zone.space, zone.priority
		end
	end
	return best
end

local function apply(space: string)
	local entry = SPACES[space]
	if entry == nil then
		return
	end
	local kind = reverb(entry.reverb)
	if kind ~= nil then
		SoundService.AmbientReverb = kind
	end
	local live = state
	if live ~= nil then
		live.current = space
		live.changes += 1
	end
end

local function listenerPosition(): Vector3?
	-- The local player on a client; on the server there is no single listener,
	-- which is why this only does anything client-side and says so.
	local player = Players.LocalPlayer
	if player == nil then
		return nil
	end
	local character = player.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function sample()
	local live = state
	if live == nil then
		return
	end
	local point = listenerPosition()
	if point == nil then
		return
	end
	local wanted = Acoustics.spaceAt(point)
	if wanted == live.current then
		live.candidate, live.held = nil, 0
		return
	end
	if wanted == live.candidate then
		live.held += 1
		-- Held long enough to be a real move rather than a lean through a
		-- doorway.
		if live.held >= HOLD_SAMPLES then
			apply(wanted)
			live.candidate, live.held = nil, 0
		end
	else
		live.candidate, live.held = wanted, 1
	end
end

--- Install a set of zones and start following the listener.
---
--- Client-side: reverb is a property of what one person hears, and a server has
--- no single listener. Called on the server it installs the zones and reports
--- that nothing will follow, rather than silently doing nothing.
function Acoustics.install(zones: { Zone }, default: string?): (boolean, { string })
	local found = Acoustics.problems(zones, default)
	if #found > 0 then
		return false, found
	end

	Acoustics.clear()

	local live: State = {
		zones = zones,
		default = default or "outdoors",
		current = "",
		candidate = nil,
		held = 0,
		connection = nil,
		accumulator = 0,
		changes = 0,
	}
	state = live
	apply(live.default)

	if RunService:IsClient() then
		live.connection = RunService.Heartbeat:Connect(function(delta)
			live.accumulator += delta
			if live.accumulator < SAMPLE_INTERVAL then
				return
			end
			live.accumulator = 0
			local ok, err = pcall(sample)
			if not ok then
				warn("[Acoustics] " .. tostring(err))
			end
		end)
		return true, {}
	end

	return true, { "installed on the server, where there is no listener to "
		.. "follow -- run this on the client for zones to take effect" }
end

function Acoustics.clear()
	local live = state
	if live ~= nil and live.connection ~= nil then
		live.connection:Disconnect()
	end
	state = nil
	local silence = reverb("NoReverb")
	if silence ~= nil then
		SoundService.AmbientReverb = silence
	end
end

function Acoustics.report(): { [string]: any }
	local live = state
	if live == nil then
		return {
			installed = false,
			ambientReverb = tostring(SoundService.AmbientReverb),
		}
	end
	local names = {}
	for _, zone in ipairs(live.zones) do
		table.insert(names, zone.name .. ":" .. zone.space)
	end
	table.sort(names)
	return {
		installed = true,
		zones = names,
		default = live.default,
		current = live.current,
		ambientReverb = tostring(SoundService.AmbientReverb),
		changes = live.changes,
		following = live.connection ~= nil,
		holdSamples = HOLD_SAMPLES,
	}
end

return Acoustics
