--!strict
--[[
	Map — the valley divided into places, and a way to say where you are.

	Shared, because the server owns where a player is and the client draws it,
	and if the two disagree about where a grid line falls then the minimap and
	the callout say different things. One table, read by both.

	Why a grid at all
	-----------------

	"South-east of the mill" is a sentence a player cannot act on quickly and
	cannot type. A grid reference is two characters, unambiguous, and the same
	two characters for everybody looking at the same map -- which is the entire
	reason military maps have them and the reason every shooter with a squad in
	it eventually grows one.

	`E4` is a hundred and twenty studs square. Small enough to walk across in
	fifteen seconds, large enough that saying it is useful rather than
	pedantic.
]]

local Map = {}

--: The playable square, in studs. The valley is a circle inside it; the
--: corners are cliff and belong to no cell anybody will stand in.
Map.EXTENT = 960
Map.CELL = 120
Map.COLUMNS = { "A", "B", "C", "D", "E", "F", "G", "H" }

--[[
	The named places.

	Each is somewhere a player would say out loud. That is the test for whether
	an area earns a name: if nobody would ever say "meet me at the north
	treeline", the north treeline is scenery and does not need one.

	`center` and `radius` are the geography `Forge.World.Areas` gained for
	exactly this. Smaller areas win when they overlap, so standing inside the
	mill reports the mill and not the clearing it sits in.
]]
Map.areas = {
	{
		id = "hollow", label = "The Hollow",
		center = Vector3.new(0, 0, 0), radius = 150,
		note = "The open middle. Nowhere to hide and everywhere to be seen from.",
	},
	{
		id = "mill", label = "Old Mill",
		center = Vector3.new(0, 0, 0), radius = 46, priority = 1,
		note = "Ruin in the hollow. Cover from three sides and one doorway.",
	},
	{
		id = "northwood", label = "North Wood",
		center = Vector3.new(-60, 0, -300), radius = 200,
		note = "Dense. Nothing sees further than forty studs in here.",
	},
	{
		id = "eastridge", label = "East Ridge",
		center = Vector3.new(300, 0, -60), radius = 190,
		note = "Rising ground. The only place a marksman is worth carrying.",
	},
	{
		id = "quarry", label = "The Quarry",
		center = Vector3.new(230, 0, -210), radius = 110, priority = 1,
		note = "Ruin on the ridge, overlooking the hollow.",
	},
	{
		id = "southflats", label = "South Flats",
		center = Vector3.new(60, 0, 300), radius = 200,
		note = "Low and wet. Long sightlines and no cover worth the name.",
	},
	{
		id = "westcamp", label = "West Camp",
		center = Vector3.new(-250, 0, 180), radius = 130, priority = 1,
		note = "Ruin at the treeline. The usual place to fall back to.",
	},
	{
		id = "chapel", label = "Broken Chapel",
		center = Vector3.new(-180, 0, -230), radius = 110, priority = 1,
		note = "Ruin in the north wood. Easy to hold, hard to leave.",
	},
}

local byId: { [string]: any } = {}
for _, area in Map.areas do
	byId[area.id] = area
end

function Map.area(id: string): any?
	return byId[id]
end

-- ================================== the grid ================================
--[[
	A world position as a grid reference.

	The origin is the north-west corner, so `A1` is top-left on the map the way
	it is on every map anybody has read. Getting that backwards is the classic
	minimap bug: the grid is correct, the drawing is correct, and they are
	mirrored against each other.
]]
function Map.reference(position: Vector3): string
	local half = Map.EXTENT / 2
	local column = math.floor((position.X + half) / Map.CELL) + 1
	local row = math.floor((position.Z + half) / Map.CELL) + 1
	column = math.clamp(column, 1, #Map.COLUMNS)
	row = math.clamp(row, 1, math.floor(Map.EXTENT / Map.CELL))
	return Map.COLUMNS[column] .. tostring(row)
end

--: The centre of a named cell, for a caller that has a reference and wants a
--: place. The inverse of `reference`, and having both is what lets a player
--: mark a square and everybody else walk to it.
function Map.cellCentre(reference: string): Vector3?
	local letter, number = string.match(reference, "^(%a)(%d+)$")
	if not letter or not number then
		return nil
	end
	local column = table.find(Map.COLUMNS, string.upper(letter))
	local row = tonumber(number)
	if not column or not row then
		return nil
	end
	local half = Map.EXTENT / 2
	return Vector3.new(
		(column - 1) * Map.CELL - half + Map.CELL / 2, 0,
		(row - 1) * Map.CELL - half + Map.CELL / 2)
end

--: Where a position sits inside the map, as 0..1 on each axis. The one number
--: a minimap actually needs, and computing it here rather than in the drawing
--: code is what stops the grid and the dot disagreeing.
function Map.normalised(position: Vector3): (number, number)
	local half = Map.EXTENT / 2
	return math.clamp((position.X + half) / Map.EXTENT, 0, 1),
		math.clamp((position.Z + half) / Map.EXTENT, 0, 1)
end

--: A compass bearing, in degrees, from a look vector. North is -Z, because
--: that is where `A1` is.
function Map.bearing(look: Vector3): number
	local degrees = math.deg(math.atan2(look.X, -look.Z))
	return (degrees + 360) % 360
end

Map.COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

function Map.compass(look: Vector3): string
	local index = math.floor(((Map.bearing(look) + 22.5) % 360) / 45) + 1
	return Map.COMPASS[index]
end

--: Everything a location readout wants, in one call, so the HUD does not have
--: to know how any of it is worked out.
function Map.locate(position: Vector3, areaId: string?): { [string]: any }
	local area = if areaId then byId[areaId] else nil
	return {
		reference = Map.reference(position),
		area = if area then area.label else "Open ground",
		areaId = areaId,
		x = math.floor(position.X),
		y = math.floor(position.Y),
		z = math.floor(position.Z),
	}
end

--: The shape of the areas, for the client to draw. Sent once rather than
--: polled: the map does not move.
function Map.layout(): { any }
	local out = {}
	for _, area in Map.areas do
		local nx, nz = Map.normalised(area.center)
		table.insert(out, {
			id = area.id, label = area.label, note = area.note,
			x = nx, z = nz,
			radius = area.radius / Map.EXTENT,
			priority = area.priority or 0,
		})
	end
	return out
end

return Map
