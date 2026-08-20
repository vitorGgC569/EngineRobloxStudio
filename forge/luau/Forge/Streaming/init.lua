--!strict
--[[
	Streaming — a chunk layer over a Scene.

	Roblox's own StreamingEnabled streams *replication*: the server still holds
	every instance, and every instance still costs memory, physics and a slot in
	the DataModel. A scene with twelve thousand placements is twelve thousand
	instances on the server whether anyone is near them or not.

	This streams *existence*. Placements are bucketed into chunks; a chunk
	materialises when someone is near it and dematerialises when nobody is.
	The scene keeps all twelve thousand placements as data — a few hundred
	kilobytes of tables — and the world holds only what is being looked at.

		local streamer = Streaming.attach(scene, {
			chunkSize = 128,
			loadRadius = 320,
			unloadRadius = 420,
			budget = 12,
		})
		streamer:start()

	Two things this gets right that a naive version does not:

	  * Load and unload radii differ. With one radius, a player standing on a
	    boundary thrashes a chunk in and out every tick. Hysteresis is not a
	    refinement here, it is the difference between working and unusable.

	  * Materialisation is budgeted. Walking into a dense chunk otherwise
	    creates four hundred instances in one frame and drops the server for
	    half a second, exactly when the player is moving fastest.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Signal = require(script.Parent.Core.Signal)
local Sched = require(script.Parent.Core.Sched)

local Streaming = {}

Streaming.chunkLoaded = Signal.new() -- (sceneName, chunkKey, count)
Streaming.chunkUnloaded = Signal.new() -- (sceneName, chunkKey)

local streamers: { [string]: any } = {}

local StreamerClass = {}
StreamerClass.__index = StreamerClass

export type Options = {
	chunkSize: number?,
	loadRadius: number?,
	unloadRadius: number?,
	budget: number?, -- placements materialised per tick
	rate: number?, -- ticks per second
	anchors: (() -> { Vector3 })?,
	alwaysLoaded: { string }?, -- chunk keys that never unload
}

local function chunkKey(x: number, z: number, size: number): string
	return string.format("%d:%d", math.floor(x / size), math.floor(z / size))
end

--[[
	Anchor velocity, tracked internally.

	Loading a symmetric radius around a player means half the budget is spent
	behind them, on chunks they are leaving. Biasing the centre forward by where
	they are heading spends the same budget on what they are about to see. It
	costs one table of previous positions.
]]
local previousAnchors: { Vector3 } = {}
local anchorVelocities: { Vector3 } = {}

local function trackVelocities(anchors: { Vector3 }, dt: number)
	for index, position in anchors do
		local previous = previousAnchors[index]
		if previous and dt > 0 then
			local velocity = (position - previous) / dt
			anchorVelocities[index] = Vector3.new(velocity.X, 0, velocity.Z)
		else
			anchorVelocities[index] = Vector3.zero
		end
		previousAnchors[index] = position
	end
	for index = #anchors + 1, #previousAnchors do
		previousAnchors[index] = nil
		anchorVelocities[index] = nil
	end
end

local function defaultAnchors(): { Vector3 }
	local out = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			table.insert(out, character:GetPivot().Position)
		end
	end
	return out
end

function Streaming.attach(scene: any, options: Options?): any
	local opts = options or {}
	local self = setmetatable({
		scene = scene,
		chunkSize = opts.chunkSize or 128,
		loadRadius = opts.loadRadius or 320,
		unloadRadius = opts.unloadRadius or (opts.loadRadius and opts.loadRadius * 1.3 or 420),
		budget = opts.budget or 12,
		rate = opts.rate or 4,
		leadSeconds = opts.leadSeconds or 1.2,
		anchors = opts.anchors or defaultAnchors,
		alwaysLoaded = {},
		chunks = {}, -- key -> { placements }
		loaded = {}, -- key -> true
		queue = {}, -- placements waiting to materialise
		stats = { loads = 0, unloads = 0, live = 0 },
	}, StreamerClass)

	for _, key in (opts.alwaysLoaded or {}) do
		self.alwaysLoaded[key] = true
	end

	-- The scene must not materialise everything on load; the streamer owns that.
	scene.streamed = true
	self:reindex()

	-- Attaching to a scene that already loaded is normal — a game builds the
	-- scene, loads it to see it, then decides to stream it. Everything it
	-- materialised has to go back, or the streamer reports full coverage
	-- forever and streams nothing.
	if scene:isLoaded() then
		local reclaimed = 0
		for _, placement in scene.placements do
			if placement._instance then
				scene:dematerialise(placement)
				reclaimed += 1
			end
		end
		if reclaimed > 0 then
			warn(string.format(
				"[Streaming] '%s' was already loaded; reclaimed %d instances so chunks can own them",
				scene.name, reclaimed
			))
		end
	end

	streamers[scene.name] = self
	return self
end

function Streaming.get(sceneName: string): any
	return streamers[sceneName]
end

--[[
	Rebuild the chunk index from the scene's placements. Cheap enough to call
	after bulk edits; the editor calls it every time a placement moves between
	chunks.
]]
function StreamerClass:reindex()
	table.clear(self.chunks)
	for _, placement in self.scene.placements do
		local position = placement.cframe.Position
		local key = chunkKey(position.X, position.Z, self.chunkSize)
		local bucket = self.chunks[key]
		if not bucket then
			bucket = {}
			self.chunks[key] = bucket
		end
		table.insert(bucket, placement)
		placement._chunk = key
	end
end

function StreamerClass:chunkCount(): number
	local n = 0
	for _ in self.chunks do
		n += 1
	end
	return n
end

function StreamerClass:loadChunk(key: string)
	if self.loaded[key] then
		return
	end
	self.loaded[key] = true
	local bucket = self.chunks[key]
	if not bucket then
		return
	end
	-- Queued rather than built: the budget is what keeps a dense chunk from
	-- stalling the frame a player crosses into it.
	for _, placement in bucket do
		if not placement._instance then
			table.insert(self.queue, placement)
		end
	end
	self.stats.loads += 1
	Streaming.chunkLoaded:Fire(self.scene.name, key, #bucket)
end

function StreamerClass:unloadChunk(key: string)
	if not self.loaded[key] or self.alwaysLoaded[key] then
		return
	end
	self.loaded[key] = nil

	for _, placement in (self.chunks[key] or {}) do
		self.scene:dematerialise(placement)
	end
	-- Anything from this chunk still waiting in the queue must not appear.
	for index = #self.queue, 1, -1 do
		if self.queue[index]._chunk == key then
			table.remove(self.queue, index)
		end
	end

	self.stats.unloads += 1
	Streaming.chunkUnloaded:Fire(self.scene.name, key)
end

function StreamerClass:_tick(dt: number?)
	local anchors = self.anchors()
	trackVelocities(anchors, dt or (1 / self.rate))

	-- Look ahead along movement. A player at 24 studs/s with a 1.2s lead time
	-- gets the next ~29 studs of world loaded before they arrive in it.
	local lead = self.leadSeconds
	local biased = {}
	for index, anchor in anchors do
		local velocity = anchorVelocities[index] or Vector3.zero
		if velocity.Magnitude > 1 and lead > 0 then
			table.insert(biased, anchor + velocity * lead)
		end
		table.insert(biased, anchor)
	end
	anchors = biased

	local wanted: { [string]: boolean } = {}

	-- Which chunks are within the load radius of anyone?
	if #anchors > 0 then
		local span = math.ceil(self.loadRadius / self.chunkSize)
		for _, anchor in anchors do
			local cx = math.floor(anchor.X / self.chunkSize)
			local cz = math.floor(anchor.Z / self.chunkSize)
			for dx = -span, span do
				for dz = -span, span do
					local key = string.format("%d:%d", cx + dx, cz + dz)
					if self.chunks[key] then
						-- distance to the chunk's centre, not its index
						local centreX = (cx + dx + 0.5) * self.chunkSize
						local centreZ = (cz + dz + 0.5) * self.chunkSize
						local distance = math.sqrt((anchor.X - centreX) ^ 2 + (anchor.Z - centreZ) ^ 2)
						if distance <= self.loadRadius then
							wanted[key] = true
						end
					end
				end
			end
		end
	end

	for key in self.alwaysLoaded do
		wanted[key] = true
	end

	for key in wanted do
		if not self.loaded[key] then
			self:loadChunk(key)
		end
	end

	-- Unload uses the larger radius: hysteresis, so a player walking a boundary
	-- does not thrash.
	for key in table.clone(self.loaded) do
		if wanted[key] or self.alwaysLoaded[key] then
			continue
		end
		local parts = string.split(key, ":")
		local centreX = (tonumber(parts[1]) + 0.5) * self.chunkSize
		local centreZ = (tonumber(parts[2]) + 0.5) * self.chunkSize
		local nearest = math.huge
		for _, anchor in anchors do
			nearest = math.min(nearest, math.sqrt((anchor.X - centreX) ^ 2 + (anchor.Z - centreZ) ^ 2))
		end
		if nearest > self.unloadRadius then
			self:unloadChunk(key)
		end
	end

	-- Spend the frame budget, nearest and highest priority first. Without the
	-- sort, walking into a chunk builds it in table order, so the thing behind
	-- a wall can appear before the thing in front of the player.
	if #self.queue > 1 then
		local reference = anchors[1]
		table.sort(self.queue, function(a, b)
			local pa = (a.options and a.options.priority) or 0
			local pb = (b.options and b.options.priority) or 0
			if pa ~= pb then
				return pa > pb
			end
			if not reference then
				return false
			end
			return (a.cframe.Position - reference).Magnitude < (b.cframe.Position - reference).Magnitude
		end)
	end

	local built = 0
	local index = 1
	while built < self.budget and index <= #self.queue do
		local placement = self.queue[index]
		if not placement or placement._instance or not self.loaded[placement._chunk] then
			table.remove(self.queue, index)
			continue
		end

		-- LOD: a placement may declare the distance beyond which it is not worth
		-- existing. Decoration disappears first; landmarks never do.
		local maxDistance = placement.options and placement.options.maxDistance
		if maxDistance then
			local nearest = math.huge
			for _, anchor in anchors do
				nearest = math.min(nearest, (placement.cframe.Position - anchor).Magnitude)
			end
			if nearest > maxDistance then
				index += 1
				continue
			end
		end

		table.remove(self.queue, index)
		self.scene:materialise(placement)
		built += 1
	end

	local live = 0
	for _, bucket in self.chunks do
		for _, placement in bucket do
			if placement._instance then
				live += 1
			end
		end
	end
	self.stats.live = live
end

function StreamerClass:start()
	if self._group then
		return self
	end
	if not self.scene:isLoaded() then
		self.scene:load()
	end
	self._group = Sched.group(self.rate)
	self._group:add("stream:" .. self.scene.name, function(dt)
		local ok, err = pcall(function()
			self:_tick(dt)
		end)
		if not ok then
			warn(string.format("[Streaming] '%s' tick failed: %s", self.scene.name, tostring(err)))
		end
	end)
	return self
end

function StreamerClass:stop()
	if self._group then
		self._group:destroy()
		self._group = nil
	end
end

-- Force a region in, regardless of anchors. For a cutscene, a teleport
-- destination, or a headless measurement run that has no players in it.
function StreamerClass:pin(position: Vector3, radius: number?)
	local span = math.ceil((radius or self.chunkSize) / self.chunkSize)
	local cx = math.floor(position.X / self.chunkSize)
	local cz = math.floor(position.Z / self.chunkSize)
	for dx = -span, span do
		for dz = -span, span do
			local key = string.format("%d:%d", cx + dx, cz + dz)
			if self.chunks[key] then
				self.alwaysLoaded[key] = true
				self:loadChunk(key)
			end
		end
	end
end

function StreamerClass:unpin(position: Vector3, radius: number?)
	local span = math.ceil((radius or self.chunkSize) / self.chunkSize)
	local cx = math.floor(position.X / self.chunkSize)
	local cz = math.floor(position.Z / self.chunkSize)
	for dx = -span, span do
		for dz = -span, span do
			self.alwaysLoaded[string.format("%d:%d", cx + dx, cz + dz)] = nil
		end
	end
end

-- Materialise everything, ignoring anchors entirely. Used by the editor, where
-- you must see what you are editing, and by a full-world validation pass.
function StreamerClass:loadAll()
	for key in self.chunks do
		self:loadChunk(key)
	end
	while #self.queue > 0 do
		local placement = table.remove(self.queue, 1)
		if placement and not placement._instance then
			self.scene:materialise(placement)
		end
	end
end

function StreamerClass:describe(): { [string]: any }
	local loadedCount = 0
	for _ in self.loaded do
		loadedCount += 1
	end
	return {
		scene = self.scene.name,
		chunkSize = self.chunkSize,
		chunks = self:chunkCount(),
		chunksLoaded = loadedCount,
		placements = #self.scene.placements,
		live = self.stats.live,
		queued = #self.queue,
		loads = self.stats.loads,
		unloads = self.stats.unloads,
		leadSeconds = self.leadSeconds,
	}
end

function Streaming.describe(): { [string]: any }
	local out: { [string]: any } = {}
	for name, streamer in streamers do
		out[name] = streamer:describe()
	end
	return out
end

return Streaming
