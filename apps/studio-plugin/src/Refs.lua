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

--- Register an instance and return its stable id for this Studio session.
function Refs.of(instance: Instance): string
	local ok, id = pcall(function()
		return instance:GetDebugId(24)
	end)
	if not ok or type(id) ~= "string" then
		-- GetDebugId is plugin-only; fall back to the path so a ref field is
		-- always present even if the API is unavailable in this context.
		id = instance:GetFullName()
	end
	if registry[id] == nil then
		table.insert(order, id)
		if #order > MAX_ENTRIES then
			local oldest = table.remove(order, 1)
			if oldest then
				registry[oldest] = nil
			end
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
	return #order
end

--- Drop everything. Called when the DataModel changes underneath us, since
--- refs are only meaningful within one world.
function Refs.clear()
	registry = {}
	order = {}
end

return Refs
