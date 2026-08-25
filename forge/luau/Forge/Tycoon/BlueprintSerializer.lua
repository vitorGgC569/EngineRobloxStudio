--!strict
--[[
	BlueprintSerializer — persist a placed layout as data, rebuild later.

	Every placed model becomes { itemId, offset from anchor (quantized),
	look direction }; layouts are JSON-safe so they ride inside any save
	schema and can be swapped in-game ("layout 1/2/3"). Deserialization
	fails loudly listing unknown ids instead of silently dropping parts.
]]

local BlueprintSerializer = {}

local QUANTUM = 1000

export type PlacedEntry = {
	itemId: string,
	pos: { x: number, y: number, z: number },
	lookX: number,
	lookZ: number,
}

export type SerializedEntry = {
	i: string,
	o: { number },
	l: { number },
}

type Self = {
	quantum: number,
}

BlueprintSerializer.__index = BlueprintSerializer

function BlueprintSerializer.new(config: { quantumDecimals: number? }): Self
	return setmetatable({ quantum = 10 ^ (config.quantumDecimals or 3) }, BlueprintSerializer)
end

local function quantize(value: number, q: number): number
	return math.floor(value * q + 0.5) / q
end

function BlueprintSerializer.serialize(self: Self, entries: { PlacedEntry }, anchor: { x: number, y: number, z: number }): { SerializedEntry }
	local out: { SerializedEntry } = {}
	for _, entry in entries do
		table.insert(out, {
			i = entry.itemId,
			o = {
				quantize(entry.pos.x - anchor.x, self.quantum),
				quantize(entry.pos.y - anchor.y, self.quantum),
				quantize(entry.pos.z - anchor.z, self.quantum),
			},
			l = {
				math.floor(entry.lookX * 1000 + 0.5) / 1000,
				math.floor(entry.lookZ * 1000 + 0.5) / 1000,
			},
		})
	end
	return out
end

function BlueprintSerializer.deserialize(
	self: Self,
	data: { SerializedEntry },
	resolve: (itemId: string) -> boolean?,
	anchor: { x: number, y: number, z: number }
): ({ PlacedEntry }?, { string }?)
	local entries: { PlacedEntry } = {}
	local missing: { string } = {}
	for _, raw in data do
		if not resolve(raw.i) then
			table.insert(missing, raw.i)
			continue
		end
		assert(#raw.o == 3 and #raw.l == 2, "malformed blueprint entry")
		table.insert(entries, {
			itemId = raw.i,
			pos = { x = raw.o[1] + anchor.x, y = raw.o[2] + anchor.y, z = raw.o[3] + anchor.z },
			lookX = raw.l[1],
			lookZ = raw.l[2],
		})
	end
	if #missing > 0 then
		return nil, missing
	end
	return entries, nil
end

return BlueprintSerializer
