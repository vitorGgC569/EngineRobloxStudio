--!strict
-- Stable instance references.
--
-- `GetFullName()` is not unique: four sibling parts all named "PlotBorder"
-- share one path, so a path-addressed command silently acts on whichever one
-- FindFirstChild returned. Any agent reasoning about "these four objects" needs
-- identifiers that actually distinguish them.
--
-- Every instance the bridge reports therefore carries a `ref`, and any command
-- that takes a path also accepts "ref:<id>".

local Refs = {}
local HttpService = game:GetService("HttpService")

-- Strong references, bounded.
--
-- Weak values are the obvious choice and the wrong one: an Instance lives in
-- the DataModel, not in Lua, so nothing else holds the Lua wrapper and the GC
-- drops the mapping between two commands. Measured -- a ref issued by dm.find
-- failed on the very next world.bounds. Liveness is checked on read instead,
-- and the registry is capped so a long session cannot grow without bound.
local MAX_ENTRIES = 20000

local registry: { [string]: Instance } = {}
local order: { string } = {}
local ids: { [Instance]: string } = setmetatable({}, { __mode = "k" }) :: any
local first = 1

--- Register an instance and return its stable id for this Studio session.
function Refs.of(instance: Instance): string
	local id = ids[instance]
	if not id or registry[id] ~= instance then
		id = HttpService:GenerateGUID(false)
		ids[instance] = id
	end
	if registry[id] == nil then
		table.insert(order, id)
		if #order - first + 1 > MAX_ENTRIES then
			local oldest = order[first]
			first += 1
			if oldest then
				local expired = registry[oldest]
				if expired then ids[expired] = nil end
				registry[oldest] = nil
			end
		end
		if first > MAX_ENTRIES then
			local kept = {}
			for index = first, #order do table.insert(kept, order[index]) end
			order, first = kept, 1
		end
	end
	registry[id] = instance
	return id
end

--- Resolve a previously issued ref. Returns nil if it was never issued or the
--- instance has since been destroyed.
function Refs.get(id: string): Instance?
	local instance = registry[id]
	if instance == nil then
		return nil
	end
	-- A destroyed instance is still a live Lua value; treat it as gone.
	if instance.Parent == nil and instance ~= game then
		local ok, isDescendant = pcall(function()
			return instance:IsDescendantOf(game)
		end)
		if ok and not isDescendant then
			return nil
		end
	end
	return instance
end

function Refs.size(): number
	return #order - first + 1
end

--- Drop everything. Called when the DataModel changes underneath us, since
--- refs are only meaningful within one world.
function Refs.clear()
	registry = {}
	order = {}
	ids = setmetatable({}, { __mode = "k" }) :: any
	first = 1
end

return Refs
