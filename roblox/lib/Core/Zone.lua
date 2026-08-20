--!strict
--- Volumes that know who is inside them.
---
--- Written with `Touched` by almost everyone, and `Touched` is the wrong tool:
--- it fires on the physics thread, fires repeatedly while something rests
--- against the part, does not fire at all for a part that spawns already
--- inside, and has no exit event that can be trusted. Every "you left the safe
--- zone" bug in Roblox traces back to it.
---
--- A zone here polls the region on a shared beat and reports **entered** and
--- **left** by difference. That gives correct enter/exit, correct membership at
--- any moment, and it works for a player who teleports in, spawns in, or is
--- standing there when the zone is created.

local Signal = require(script.Parent.Signal)
local Timer = require(script.Parent.Timer)
local Trove = require(script.Parent.Trove)

local Players = game:GetService("Players")

local Zone = {}
Zone.__index = Zone

export type Class = {
	entered: any,
	left: any,
	occupants: (Class) -> { Instance },
	contains: (Class, Instance) -> boolean,
	count: (Class) -> number,
	pause: (Class) -> (),
	resume: (Class) -> (),
	destroy: (Class) -> (),
}

--- How often membership is recomputed, in seconds.
---
--- Ten times a second: fast enough that walking through a doorway registers
--- before the player is through it, cheap enough that fifty zones cost nothing.
--- A zone that needs frame accuracy is a collision problem, not a zone.
local BEAT = 0.1

local function partsOf(model: Instance): { BasePart }
	local parts = {}
	if model:IsA("BasePart") then
		table.insert(parts, model)
	end
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("BasePart") then
			table.insert(parts, item)
		end
	end
	return parts
end

--- Watch a box. `subject` decides what counts as "inside": by default the
--- characters of players, but any predicate works.
function Zone.new(centre: Vector3, size: Vector3, options: { [string]: any }?): Class
	local opts = options or {}

	local self = setmetatable({
		_centre = centre,
		_size = size,
		_inside = {},
		_paused = false,
		_trove = Trove.new(),
		_players = opts.players ~= false,
		_filter = opts.filter,
		entered = Signal.new("Zone.entered"),
		left = Signal.new("Zone.left"),
	}, Zone)

	self._trove:add(self.entered)
	self._trove:add(self.left)

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = opts.ignore or {}
	params.MaxParts = tonumber(opts.maxParts) or 200
	self._params = params

	local handle = Timer.every(tonumber(opts.beat) or BEAT, function()
		self:_sweep()
	end, "Zone")
	self._trove:add(function()
		handle:cancel()
	end)

	return (self :: any) :: Class
end

--- Watch an existing part, following it if it moves.
function Zone.fromPart(part: BasePart, options: { [string]: any }?): Class
	local opts = table.clone(options or {})
	opts.ignore = opts.ignore or { part }
	local zone = Zone.new(part.Position, part.Size, opts)
	;(zone :: any)._follow = part
	return zone
end

function Zone._sweep(self)
	if self._paused then
		return
	end

	local follow = self._follow
	if follow ~= nil then
		if follow.Parent == nil then
			self:destroy()
			return
		end
		self._centre = follow.Position
		self._size = follow.Size
	end

	local found: { [Instance]: boolean } = {}
	local ok, parts = pcall(function()
		return workspace:GetPartBoundsInBox(
			CFrame.new(self._centre), self._size, self._params)
	end)
	if not ok then
		return
	end

	for _, part in ipairs(parts) do
		-- A player is their character, not the fifteen parts of it -- otherwise
		-- one person walking in fires fifteen `entered` events.
		local subject: Instance? = nil
		if self._players then
			local character = part:FindFirstAncestorOfClass("Model")
			if character ~= nil and character:FindFirstChildOfClass("Humanoid") ~= nil then
				subject = character
			end
		else
			subject = part:FindFirstAncestorOfClass("Model") or part
		end
		if subject ~= nil then
			if self._filter == nil or self._filter(subject) then
				found[subject] = true
			end
		end
	end

	for subject in pairs(found) do
		if not self._inside[subject] then
			self._inside[subject] = true
			self.entered:fire(subject, Players:GetPlayerFromCharacter(subject))
		end
	end
	for subject in pairs(self._inside) do
		if not found[subject] or subject.Parent == nil then
			self._inside[subject] = nil
			self.left:fire(subject, Players:GetPlayerFromCharacter(subject))
		end
	end
end

function Zone.occupants(self): { Instance }
	local out = {}
	for subject in pairs(self._inside) do
		table.insert(out, subject)
	end
	return out
end

function Zone.contains(self, subject: Instance): boolean
	return self._inside[subject] == true
end

function Zone.count(self): number
	local total = 0
	for _ in pairs(self._inside) do
		total += 1
	end
	return total
end

function Zone.pause(self)
	self._paused = true
end

function Zone.resume(self)
	self._paused = false
end

function Zone.destroy(self)
	self._trove:clean()
	table.clear(self._inside)
end

return Zone
