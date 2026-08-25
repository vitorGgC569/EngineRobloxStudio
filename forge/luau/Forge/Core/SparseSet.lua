--!strict
--[[
	SparseSet — add, remove and iterate a set of ids, all in constant time.

	The problem with the obvious structure
	--------------------------------------

	A set of entity ids is usually a table keyed by id: `has[id] = true`.
	Lookup is fast and everything else is wrong.

	  **Iteration allocates and wanders.** `pairs` over a hash walks buckets in
	  memory order, which is cache-hostile, and in Luau it costs an iterator.
	  Ten thousand entities iterated every frame is a measurable share of the
	  budget spent on pointer chasing.

	  **Removal leaves holes.** Setting a key to nil does not shrink the table,
	  so a set that churns grows and never gives the memory back, and every
	  later iteration walks the empty space.

	A sparse set fixes both with two arrays:

	  `dense`   the ids, packed with no gaps. This is what you iterate: a plain
	            array walk, in order, no allocation.
	  `sparse`  id -> where it sits in `dense`. This is what you look up.

	Removal is the trick worth knowing: swap the removed element with the last
	one and shorten by one. Constant time, no hole, no shuffle. The cost is
	that **order is not stable** — which is fine for a set, and is the reason
	this is a set rather than a list.

		local set = SparseSet.new()
		SparseSet.add(set, 42)
		for _, id in SparseSet.ids(set) do ... end   -- packed, ordered walk

	Where the technique comes from
	------------------------------

	Every serious ECS is built on it, because "all entities with this
	component" is exactly this problem asked ten thousand times a frame.
	`Entity` gives you the framework; this is the structure underneath, exposed
	on its own because plenty of things want a churning set without wanting an
	entity system — visible players, active projectiles, loaded chunks, anything
	tracked by a tag.
]]

local SparseSet = {}

export type Set = {
	dense: { number },
	sparse: { [number]: number },
	count: number,
}

function SparseSet.new(): Set
	return { dense = {}, sparse = {}, count = 0 }
end

-- ================================== writing =================================
--[[
	Add an id. Adding one already present does nothing.

	Returns whether it was new, which saves the caller a `has` first — and the
	two-call version is where double-counting bugs come from.
]]
function SparseSet.add(set: Set, id: number): boolean
	if set.sparse[id] then
		return false
	end
	local index = set.count + 1
	set.count = index
	set.dense[index] = id
	set.sparse[id] = index
	return true
end

--[[
	Remove an id, in constant time.

	The swap-remove: the last element moves into the hole and the array
	shortens. Its `sparse` entry has to move with it, which is the line
	everybody forgets — and forgetting it leaves a stale index that reads a
	different entity's data, silently.
]]
function SparseSet.remove(set: Set, id: number): boolean
	local index = set.sparse[id]
	if not index then
		return false
	end

	local last = set.count
	local lastId = set.dense[last]

	set.dense[index] = lastId
	set.sparse[lastId] = index

	set.dense[last] = nil
	set.sparse[id] = nil
	set.count = last - 1
	return true
end

function SparseSet.clear(set: Set)
	table.clear(set.dense)
	table.clear(set.sparse)
	set.count = 0
end

-- ================================== reading =================================
function SparseSet.has(set: Set, id: number): boolean
	return set.sparse[id] ~= nil
end

function SparseSet.size(set: Set): number
	return set.count
end

--[[
	The packed array of ids.

	Returned directly rather than copied, because copying it every frame would
	undo the whole point. **Do not add or remove while iterating it** — a
	swap-remove moves an element you have not visited into a slot you already
	passed, and that element is silently skipped.

	`SparseSet.drain` is the safe form when the loop mutates.
]]
function SparseSet.ids(set: Set): { number }
	return set.dense
end

--[[
	Iterate a stable copy, for a loop that removes as it goes.

	The copy costs an allocation and buys correctness. Worth it exactly when
	the body can remove — expiring projectiles, despawning enemies — and worth
	avoiding when it cannot.
]]
function SparseSet.drain(set: Set): { number }
	return table.move(set.dense, 1, set.count, 1, table.create(set.count))
end

--[[
	The ids in `a` that are also in `b`, smallest set first.

	The join every ECS query is: iterate the smaller set and test membership in
	the larger, which is O(smaller) rather than O(either). Iterating the wrong
	one is the difference between checking twelve projectiles against ten
	thousand entities and the reverse.
]]
function SparseSet.intersect(a: Set, b: Set): { number }
	local small, large = a, b
	if b.count < a.count then
		small, large = b, a
	end

	local out = table.create(small.count)
	local found = 0
	for index = 1, small.count do
		local id = small.dense[index]
		if large.sparse[id] then
			found += 1
			out[found] = id
		end
	end
	return table.move(out, 1, found, 1, table.create(found))
end

function SparseSet.describe(set: Set): { [string]: any }
	return {
		count = set.count,
		--[[
			Whether the two halves still agree.

			A sparse set can only be corrupted one way — an index that does not
			point back at its own id — and that corruption is invisible until
			something reads the wrong entity's data. Cheap to check in a test,
			too expensive to check every frame, which is why it lives here and
			not in `remove`.
		]]
		consistent = (function()
			for index = 1, set.count do
				if set.sparse[set.dense[index]] ~= index then
					return false
				end
			end
			return true
		end)(),
	}
end

return SparseSet
