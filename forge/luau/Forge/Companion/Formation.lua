--!strict
--[[
	Formation — where each follower stands, relative to whoever it follows.

	Generalised from a shipped pet system
	-------------------------------------

	This is the slot maths from a live simulator's follow system, with the pets
	taken out. A follower is anything that trails a leader in a readable group:
	pets, drones, hired workers, a squad of guards. The rules are the same and
	none of them are obvious.

	What the shipped version knows that a first attempt does not:

	  * **Small in front, large behind.** Sorting by footprint stops a huge
	    follower from eclipsing the three small ones and from shouldering them
	    out of frame. Gaps scale with each neighbour's radius rather than being
	    a constant, because a constant that suits a rabbit hides an ent.

	  * **Formation is a shape, not a queue.** `conga` reads as a train,
	    `risers` as a marching block, `arc` as a cradle around the leader.
	    Which one is right depends on how many there are and how wide they are,
	    which is why the shape is chosen per call rather than configured once.

	  * **Height needs a per-size correction.** A follower scaled up keeps the
	    flat formation height, so large ones end up hovering and a few tall
	    ones sink as they bob. The shipped config carries a class default of
	    -1.5 studs for large followers and per-species overrides on top -- one
	    tall model needed +2 rather than a drop.

	Nothing here touches an Instance. It answers "where should follower `i` of
	`n` stand", and the driver moves things.
]]

local Formation = {}

export type Slot = {
	--: Offset in the leader's own space: +X right, +Y up, -Z forward.
	x: number,
	y: number,
	z: number,
	index: number,
}

export type Follower = {
	id: string,
	--: The widest the model measures, in studs. Spacing is derived from this,
	--: so a follower that reports nothing gets the default rather than a gap
	--: sized for something else.
	footprint: number?,
	--: Marks a follower that is deliberately much larger than the rest, so it
	--: can be sunk, lifted and placed behind without measuring every model.
	large: boolean?,
}

export type Config = {
	mode: string?,          -- "conga" | "risers" | "arc"
	followDistance: number?, -- studs behind the leader to the first row
	height: number?,         -- studs above the leader's root
	gap: number?,            -- added between neighbours, on top of their radii
	defaultFootprint: number?,
	perRow: number?,
	rowGap: number?,
	colSpacing: number?,
	radius: number?,
	arcStepDegrees: number?,
	spreadFactor: number?,
	depthFactor: number?,
	--: Vertical correction by size class, then by id. A large follower usually
	--: floats and wants a negative value; a tall one sinks and wants a
	--: positive one.
	floatOffsets: { normal: number?, large: number?, byId: { [string]: number }? }?,
}

--[[
	The defaults are the shipped ones, not invented.

	Six studs behind and two above is close enough to read as "with you" and
	far enough not to obscure the leader; three per row and four studs apart is
	what a squad of ten looks like without becoming a crowd.
]]
local DEFAULTS = {
	mode = "risers",
	followDistance = 6,
	height = 2,
	gap = 1.5,
	defaultFootprint = 4,
	perRow = 3,
	rowGap = 2,
	colSpacing = 3,
	radius = 11,
	arcStepDegrees = 20,
	spreadFactor = 0.15,
	depthFactor = 0.1,
}

local function setting(config: Config?, key: string): any
	local value = config and (config :: any)[key]
	if value ~= nil then
		return value
	end
	return (DEFAULTS :: any)[key]
end

local function footprintOf(follower: Follower, config: Config?): number
	return follower.footprint or setting(config, "defaultFootprint")
end

--[[
	Sorted smallest first, stably.

	Stable because an unstable sort reshuffles equal-sized followers every
	frame the set is recomputed, and a squad that swaps places while walking
	reads as a bug even when every position is correct.
]]
local function ordered(followers: { Follower }, config: Config?): { Follower }
	local indexed = {}
	for position, follower in followers do
		table.insert(indexed, { follower = follower, position = position })
	end
	table.sort(indexed, function(a, b)
		local sizeA = footprintOf(a.follower, config)
		local sizeB = footprintOf(b.follower, config)
		if sizeA ~= sizeB then
			return sizeA < sizeB
		end
		return a.position < b.position
	end)

	local out = {}
	for _, entry in indexed do
		table.insert(out, entry.follower)
	end
	return out
end

local function verticalOffset(follower: Follower, config: Config?): number
	local offsets = setting(config, "floatOffsets")
	if not offsets then
		return 0
	end
	local byId = offsets.byId
	if byId and follower.id and byId[follower.id] ~= nil then
		return byId[follower.id]
	end
	if follower.large then
		return offsets.large or 0
	end
	return offsets.normal or 0
end

-- =================================== conga ==================================
--: Single file, each one a full stride behind the last. Reads as a train, and
--: it is the only shape that stays legible in a corridor.
local function conga(followers: { Follower }, config: Config?): { Slot }
	local gap = setting(config, "gap")
	local slots: { Slot } = {}
	local depth = setting(config, "followDistance")

	for index, follower in followers do
		local radius = footprintOf(follower, config) * 0.5
		depth += radius
		table.insert(slots, {
			x = 0,
			y = setting(config, "height") + verticalOffset(follower, config),
			z = -depth,
			index = index,
		})
		depth += radius + gap
	end
	return slots
end

-- =================================== risers =================================
--[[
	Tiered rows, largest at the back.

	Row depth grows with the deepest member of the row rather than by a
	constant, so a row containing something big does not have the next row
	standing inside it.
]]
local function risers(followers: { Follower }, config: Config?): { Slot }
	local perRow = math.max(1, setting(config, "perRow"))
	local rowGap = setting(config, "rowGap")
	local colSpacing = setting(config, "colSpacing")
	local gap = setting(config, "gap")

	local slots: { Slot } = {}
	local depth = setting(config, "followDistance")
	local index = 1

	while index <= #followers do
		local row = {}
		for offset = 0, perRow - 1 do
			local follower = followers[index + offset]
			if not follower then
				break
			end
			table.insert(row, follower)
		end

		local deepest = 0
		local width = 0
		for _, follower in row do
			local size = footprintOf(follower, config)
			deepest = math.max(deepest, size)
			width += size + gap
		end
		width -= gap

		depth += deepest * 0.5
		local cursor = -width * 0.5
		for _, follower in row do
			local size = footprintOf(follower, config)
			cursor += size * 0.5
			table.insert(slots, {
				x = cursor,
				y = setting(config, "height") + verticalOffset(follower, config),
				z = -depth,
				index = #slots + 1,
			})
			cursor += size * 0.5 + gap
		end
		depth += deepest * 0.5 + rowGap + colSpacing * 0

		index += #row
	end

	return slots
end

-- ==================================== arc ===================================
--[[
	A concave cradle, the large ones curling back at the ends.

	`spreadFactor` and `depthFactor` push the outermost members wider and
	further back than a plain circle would, which is what stops an arc of ten
	from wrapping around in front of the leader and blocking the view.
]]
local function arc(followers: { Follower }, config: Config?): { Slot }
	local radius = setting(config, "radius")
	local step = math.rad(setting(config, "arcStepDegrees"))
	local spread = setting(config, "spreadFactor")
	local depthFactor = setting(config, "depthFactor")

	local slots: { Slot } = {}
	local count = #followers
	local middle = (count + 1) * 0.5

	for index, follower in followers do
		--: Signed distance from the centre of the arc, so the shape is
		--: symmetric however many there are.
		local fromMiddle = index - middle
		local angle = fromMiddle * step
		local out = radius * (1 + math.abs(fromMiddle) * spread)
		local back = setting(config, "followDistance")
			+ math.abs(fromMiddle) * radius * depthFactor

		table.insert(slots, {
			x = math.sin(angle) * out,
			y = setting(config, "height") + verticalOffset(follower, config),
			z = -(back + math.cos(angle) * radius * 0.15),
			index = index,
		})
	end
	return slots
end

local SHAPES: { [string]: ({ Follower }, Config?) -> { Slot } } = {
	conga = conga,
	risers = risers,
	arc = arc,
}

--[[
	Where everyone stands, in the leader's own space.

	Returned in the caller's original order, not the sorted one: the caller
	holds its followers in a stable list and wants slot `i` to belong to
	follower `i`. Sorting is an internal decision about who stands where.
]]
function Formation.resolve(followers: { Follower }, config: Config?): { Slot }
	if #followers == 0 then
		return {}
	end

	local shape = SHAPES[setting(config, "mode")] or risers
	local sorted = ordered(followers, config)
	local placed = shape(sorted, config)

	local byId: { [string]: Slot } = {}
	for position, follower in sorted do
		byId[follower.id] = placed[position]
	end

	local out: { Slot } = {}
	for position, follower in followers do
		local slot = byId[follower.id] or { x = 0, y = 0, z = 0, index = position }
		table.insert(out, {
			x = slot.x, y = slot.y, z = slot.z, index = position,
		})
	end
	return out
end

--[[
	A gentle bob, shared by everyone but out of phase.

	One oscillator for the whole group makes them rise and fall as a single
	object, which reads as a lift rather than as living things. Offsetting each
	by its index is the cheapest possible desync.
]]
function Formation.bob(index: number, clock: number, amplitude: number?, period: number?): number
	local size = amplitude or 0.5
	local seconds = period or 2
	if seconds <= 0 then
		return 0
	end
	return math.sin((clock / seconds + index * 0.37) * math.pi * 2) * size
end

--[[
	How far to nudge two followers that are standing on each other.

	Deliberately a push on their *targets* rather than a collision: the mover
	then walks them apart on its own terms, and nothing fights the physics
	engine for control of the same part. The shipped system is explicit that
	this is why -- "not via collisions -- they move away from each other so the
	other system can take over".
]]
function Formation.separate(slots: { Slot }, minimum: number?): { Slot }
	local limit = minimum or 3
	if limit <= 0 or #slots < 2 then
		return slots
	end

	local out: { Slot } = {}
	for _, slot in slots do
		table.insert(out, { x = slot.x, y = slot.y, z = slot.z, index = slot.index })
	end

	for i = 1, #out do
		for j = i + 1, #out do
			local a, b = out[i], out[j]
			local dx, dz = b.x - a.x, b.z - a.z
			local distance = math.sqrt(dx * dx + dz * dz)
			if distance < limit and distance > 1e-4 then
				local push = (limit - distance) * 0.5
				local ux, uz = dx / distance, dz / distance
				a.x -= ux * push
				a.z -= uz * push
				b.x += ux * push
				b.z += uz * push
			end
		end
	end
	return out
end

return Formation
