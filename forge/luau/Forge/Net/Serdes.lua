--!strict
--[[
	Serdes — binary codecs and frame batching over the Roblox `buffer` global.

	REQUIRES A ROBLOX RUNTIME (or Lune): `buffer` is an engine global, so this
	module compiles anywhere but only RUNS where the engine provides it.

	Codecs come in write/read pairs that advance an offset, YAN-style:

		local next = Serdes.u16.write(buf, at, value)
		local value, next = Serdes.u16.read(buf, at)

	Each codec exposes `size` (fixed width, when constant) and
	`sizeOf(value)` (encoded-width estimate; variable-width codecs measure,
	fixed ones return their constant).

	BatchWriter packs many messages into ONE buffer — per frame a u16 channel
	id, a u16 byte length, then the raw payload — the same batching idea as
	YetAnotherNet's Bridge; BatchReader walks the frames back out. Frames are
	never trusted: an out-of-range write asserts, and a truncated tail ends
	iteration instead of decoding garbage.
]]

local Serdes = {}

export type WriteFn = (buf: buffer, offset: number, value: any) -> number
export type ReadFn = (buf: buffer, offset: number) -> (any, number)
export type SizeOf = (value: any) -> number

export type Codec = {
	size: number?, -- fixed encoded width, when constant
	sizeOf: SizeOf, -- encoded width for a concrete value
	write: WriteFn, -- writes the value, returns the offset just past it
	read: ReadFn, -- reads the value, returns (value, offset just past it)
}

local U16_MAX = 65535

local function fixedSize(width: number): SizeOf
	return function(_value: any): number
		return width
	end
end

local function finiteFloat(value: any, kind: string): ()
	assert(
		type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge,
		kind .. " must be a finite number"
	)
end

local codecs: { [string]: Codec } = {}

local function register(name: string, codec: Codec): ()
	codecs[name] = codec
	Serdes[name] = codec
end

local function fixedCodec(width: number, write: WriteFn, read: ReadFn): Codec
	return {
		size = width,
		sizeOf = fixedSize(width),
		write = write,
		read = read,
	}
end

register("u8", fixedCodec(1,
	function(buf, at, v)
		assert(v % 1 == 0 and v >= 0 and v <= 255, "u8 out of range")
		buffer.writeu8(buf, at, v)
		return at + 1
	end,
	function(buf, at)
		return buffer.readu8(buf, at), at + 1
	end))

register("u16", fixedCodec(2,
	function(buf, at, v)
		assert(v % 1 == 0 and v >= 0 and v <= U16_MAX, "u16 out of range")
		buffer.writeu16(buf, at, v)
		return at + 2
	end,
	function(buf, at)
		return buffer.readu16(buf, at), at + 2
	end))

register("u32", fixedCodec(4,
	function(buf, at, v)
		assert(v % 1 == 0 and v >= 0 and v <= 4294967295, "u32 out of range")
		buffer.writeu32(buf, at, v)
		return at + 4
	end,
	function(buf, at)
		return buffer.readu32(buf, at), at + 4
	end))

register("i32", fixedCodec(4,
	function(buf, at, v)
		assert(v % 1 == 0 and v >= -2147483648 and v <= 2147483647, "i32 out of range")
		buffer.writei32(buf, at, v)
		return at + 4
	end,
	function(buf, at)
		return buffer.readi32(buf, at), at + 4
	end))

register("f32", fixedCodec(4,
	function(buf, at, v)
		finiteFloat(v, "f32")
		buffer.writef32(buf, at, v)
		return at + 4
	end,
	function(buf, at)
		return buffer.readf32(buf, at), at + 4
	end))

register("f64", fixedCodec(8,
	function(buf, at, v)
		finiteFloat(v, "f64")
		buffer.writef64(buf, at, v)
		return at + 8
	end,
	function(buf, at)
		return buffer.readf64(buf, at), at + 8
	end))

register("bool", fixedCodec(1,
	function(buf, at, v)
		buffer.writeu8(buf, at, if v then 1 else 0)
		return at + 1
	end,
	function(buf, at)
		return buffer.readu8(buf, at) ~= 0, at + 1
	end))

register("string", {
	sizeOf = function(v)
		assert(type(v) == "string", "string codec expected a string")
		return 2 + #v
	end,
	write = function(buf, at, v)
		assert(type(v) == "string", "string codec expected a string")
		assert(#v <= U16_MAX, "string too long for u16 length prefix")
		buffer.writeu16(buf, at, #v)
		buffer.writestring(buf, at + 2, v)
		return at + 2 + #v
	end,
	read = function(buf, at)
		local len = buffer.readu16(buf, at)
		return buffer.readstring(buf, at + 2, len), at + 2 + len
	end,
})

-- 3 x f32, exactly YAN's Vector3 serdes layout.
register("vector3", fixedCodec(12,
	function(buf, at, v)
		buffer.writef32(buf, at, v.X)
		buffer.writef32(buf, at + 4, v.Y)
		buffer.writef32(buf, at + 8, v.Z)
		return at + 12
	end,
	function(buf, at)
		local x = buffer.readf32(buf, at)
		local y = buffer.readf32(buf, at + 4)
		local z = buffer.readf32(buf, at + 8)
		return Vector3.new(x, y, z), at + 12
	end))

-- 3 x u8, RGB channels rounded from Color3's 0..1 components.
register("color3", fixedCodec(3,
	function(buf, at, v)
		buffer.writeu8(buf, at, math.floor(v.R * 255 + 0.5))
		buffer.writeu8(buf, at + 1, math.floor(v.G * 255 + 0.5))
		buffer.writeu8(buf, at + 2, math.floor(v.B * 255 + 0.5))
		return at + 3
	end,
	function(buf, at)
		local r = buffer.readu8(buf, at)
		local g = buffer.readu8(buf, at + 1)
		local b = buffer.readu8(buf, at + 2)
		return Color3.fromRGB(r, g, b), at + 3
	end))

Serdes.codecs = codecs

function Serdes.sizeOf(name: string, value: any): number
	local codec = codecs[name]
	assert(codec ~= nil, "unknown codec: " .. name)
	return codec.sizeOf(value)
end

-- ================================ batching ==================================

type BatchWriterImpl = {
	__index: BatchWriterImpl,
	pieces: { buffer }, -- alternating header/payload, in frame order
	bytes: number,

	push: (self: BatchWriter, channelId: number, payload: buffer) -> (),
	finish: (self: BatchWriter) -> buffer,
	pendingBytes: (self: BatchWriter) -> number,
}

export type BatchWriter = typeof(setmetatable({} :: { pieces: { buffer }, bytes: number }, {} :: BatchWriterImpl))

local BatchWriter: BatchWriterImpl = {} :: BatchWriterImpl
BatchWriter.__index = BatchWriter

function BatchWriter.new(): BatchWriter
	return setmetatable({ pieces = {}, bytes = 0 }, BatchWriter)
end

-- Appends one frame: u16 channelId, u16 payload byte-length, payload bytes.
function BatchWriter.push(self: BatchWriter, channelId: number, payload: buffer): ()
	assert(type(channelId) == "number" and channelId % 1 == 0 and channelId >= 0 and channelId <= U16_MAX,
		"channelId must be an integer fitting u16")
	local length = buffer.len(payload)
	assert(length <= U16_MAX, "payload too large for u16 frame length")

	local header = buffer.create(4)
	buffer.writeu16(header, 0, channelId)
	buffer.writeu16(header, 2, length)

	table.insert(self.pieces, header)
	table.insert(self.pieces, payload)
	self.bytes += 4 + length
end

-- Concatenates every queued frame into one buffer and clears the queue.
function BatchWriter.finish(self: BatchWriter): buffer
	local out = buffer.create(self.bytes)
	local at = 0
	for _, piece in self.pieces do
		local width = buffer.len(piece)
		buffer.copy(out, at, piece, 0, width)
		at += width
	end
	self.pieces = {}
	self.bytes = 0
	return out
end

function BatchWriter.pendingBytes(self: BatchWriter): number
	return self.bytes
end

type BatchReaderImpl = {
	__index: BatchReaderImpl,
	source: buffer,
	total: number,
	at: number,

	next: (self: BatchReader) -> (number?, buffer?),
}

export type BatchReader = typeof(setmetatable({} :: { source: buffer, total: number, at: number }, {} :: BatchReaderImpl))

local BatchReader: BatchReaderImpl = {} :: BatchReaderImpl
BatchReader.__index = BatchReader

function BatchReader.new(source: buffer): BatchReader
	return setmetatable({ source = source, total = buffer.len(source), at = 0 }, BatchReader)
end

-- Returns the next (channelId, payloadBuffer) or (nil, nil) at the end.
-- Channel id 0 is a valid channel; only nil signals exhaustion. A truncated
-- or corrupt frame stops iteration rather than reading past the buffer.
function BatchReader.next(self: BatchReader): (number?, buffer?)
	local at = self.at
	if at + 4 > self.total then
		return nil, nil
	end

	local channelId = buffer.readu16(self.source, at)
	local length = buffer.readu16(self.source, at + 2)
	at += 4

	if at + length > self.total then
		self.at = self.total
		return nil, nil
	end

	local payload = buffer.create(length)
	buffer.copy(payload, 0, self.source, at, length)
	at += length
	self.at = at

	return channelId, payload
end

Serdes.BatchWriter = BatchWriter
Serdes.BatchReader = BatchReader

return Serdes
