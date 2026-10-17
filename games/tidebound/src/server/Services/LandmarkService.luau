--!strict
--[[
	LandmarkService — the far side of the horizon, placed and lit.

	Two halves, deliberately split:

	`plan(options)` is pure. Given the `SeaPlan` heightfield and one seeded
	stream function it returns every landmark, wreck, arch and reef prop as
	data — kind, position, yaw, scale, tag (land / water / reef) — plus a
	layout hash. No Instance, no Studio, no clock: the headless tests rebuild
	the exact layout the game will, so placement can be argued with before a
	live place exists.

	`start(services)` is the runtime half. It re-resolves every planned item
	onto the painted terrain with `World.surface`, hands each one to
	`LandmarkKit`, and keeps the one promise the layout cannot: at dusk the
	lighthouse beam starts sweeping and the fire flickers. Everything Forge
	provides is resolved here and not at module scope, because `Forge`'s lazy
	children cannot be indexed in the headless harness — and `plan` is the
	half that has to load there.

	Wire it after WorldService:
		require(script.Services.LandmarkService).start({ WorldService = WorldService })
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local SeaPlan = require(Shared.SeaPlan)
local LandmarkKit = require(script.Parent.Parent.Lib.LandmarkKit)

local LandmarkService = {}

local SEA = Config.waterLevel

--: Reef props per zone. The 26-stud grid can offer more than this in a big
--: reef; the cap keeps the extra instance budget for the landmarks that are
--: actually looked at.
local REEF_CAP = 96

--: How close a reef prop may come to a pier lane before a boat has to care.
local LANE_CLEARANCE = 14

-- ================================= geometry =================================
--: All linear helpers are 2D in (x, z); a Vector2's Y is a world Z.

local function heightAt(field: any, p: Vector2): number
	return field:height(p.X, p.Y)
end

local function yawToward(from: Vector2, to: Vector2): number
	return math.atan2(to.X - from.X, to.Y - from.Y)
end

local function yawOf(direction: Vector2): number
	return math.atan2(direction.X, direction.Y)
end

--: Distance from `p` to the rectangle [cx±hx, cz±hz]; zero inside it.
local function rectDistance(p: Vector2, cx: number, cz: number, hx: number, hz: number): number
	local dx = math.max(math.abs(p.X - cx) - hx, 0)
	local dz = math.max(math.abs(p.Y - cz) - hz, 0)
	return math.sqrt(dx * dx + dz * dz)
end

--: Distance from `p` to segment ab.
local function segmentDistance(p: Vector2, a: Vector2, b: Vector2): number
	local ab = b - a
	local length = ab.Magnitude
	if length == 0 then
		return (p - a).Magnitude
	end
	local t = ((p.X - a.X) * ab.X + (p.Y - a.Y) * ab.Y) / (length * length)
	if t < 0 then
		t = 0
	elseif t > 1 then
		t = 1
	end
	local closest = Vector2.new(a.X + ab.X * t, a.Y + ab.Y * t)
	return (p - closest).Magnitude
end

--[[
	Hub furniture to keep clear, as offsets from the hub dock point. This
	mirrors `WorldService.buildHub` — stalls at -34, crates and barrels behind
	them, the mooring lines along the west edge, the spawn plaza and sign, and
	the pier lane running north to the tip. The rectangles are padded about
	their real footprints; the placement test asserts land landmarks stay 24
	studs out from every one of them.
]]
local HUB_CLEARANCE_RECTS = {
	{ name = "stalls", cx = 0, cz = -34, hx = 26, hz = 7 },
	{ name = "crates", cx = 1, cz = -39, hx = 25, hz = 10 },
	{ name = "lamps", cx = 0, cz = -9, hx = 28, hz = 15 },
	{ name = "mooringsWest", cx = -34, cz = 12, hx = 6, hz = 23 },
	{ name = "mooringEast", cx = 34, cz = -6, hx = 6, hz = 6 },
	{ name = "spawnPlaza", cx = 0, cz = -2, hx = 12, hz = 10 },
}

--: FNV-1a over the layout, one line per item. Two plans that place the same
--: things in the same places hash the same; anything else does not.
local function layoutHash(items: { any }): string
	local hash = 2166136261
	local function mix(byte: number)
		hash = bit32.bxor(hash, byte)
		hash = (hash
			+ bit32.lshift(hash, 1)
			+ bit32.lshift(hash, 4)
			+ bit32.lshift(hash, 7)
			+ bit32.lshift(hash, 8)
			+ bit32.lshift(hash, 24)) % 4294967296
	end
	for _, item in items do
		local line = string.format("%s:%.2f:%.2f:%.2f:%.2f",
			item.kind, item.at.X, item.at.Y, item.at.Z, item.yaw)
		for index = 1, #line do
			mix(string.byte(line, index))
		end
		mix(10)
	end
	return string.format("%08x", hash)
end

-- ================================== plan ====================================
--[[
	`options.field`  — a `World.heightfield` result.
	`options.streamFor` — `Rng.at`, or a stand-in with the same
	                       (name, x, z) → seeded-stream contract, where the
	                       stream answers `:number()` and `:inDisc(radius)`.
	                       Land placement never touches it; only the reef
	                       scatter does, which is the property the seed
	                       variation test leans on.

	Returns `{ items, hash, counts }`. Every item is:
	  { kind, tag = "land"|"water"|"reef", at = Vector3, yaw, scale, flavor?, zone? }
	with `at.Y` the heightfield's own height: land items are guaranteed above
	the waterline by the sites chosen below, and the runtime re-resolves every
	Y onto the painted terrain anyway.
]]
function LandmarkService.plan(options: any): any
	local field = options.field
	if not field then
		error("[LandmarkService] plan needs a heightfield in options.field", 2)
	end
	local stream = options.streamFor
	if not stream then
		error("[LandmarkService] plan needs a seeded streamFor", 2)
	end

	local items: { any } = {}

	local function add(kind: string, tag: string, p: Vector2, y: number, yaw: number, opts: any?)
		table.insert(items, {
			kind = kind,
			tag = tag,
			at = Vector3.new(p.X, y, p.Y),
			yaw = yaw,
			scale = if opts and opts.scale then opts.scale else 1,
			flavor = if opts then opts.flavor else nil,
			zone = if opts then opts.zone else nil,
		})
	end

	local function addLand(kind: string, p: Vector2, yaw: number, opts: any?)
		add(kind, "land", p, heightAt(field, p), yaw, opts)
	end

	local hub = SeaPlan.dockPoint(Config.zone("shallows"))

	-- ------------------------------------------------------------- the harbor --
	-- Fixed offsets from the dock, chosen by survey against the finished hub
	-- and then asserted by the placement test: the lighthouse marks the pier
	-- approach, the shack and its clothesline sit off the market row's flank,
	-- and the shallows shrine stands clear of the west mooring line.
	local lighthouseAt = hub + Vector2.new(46, 52)
	addLand("lighthouse", lighthouseAt, yawToward(lighthouseAt, Vector2.new(hub.X, hub.Y + 97)))

	local shackAt = hub + Vector2.new(-56, -44)
	addLand("fishingShack", shackAt, yawToward(shackAt, hub))

	local hubShrineAt = hub + Vector2.new(-66, 24)
	addLand("shrine", hubShrineAt, yawToward(hubShrineAt, hub), { flavor = "shallows" })

	-- ------------------------------------------------- the outer zone marks ---
	-- Each zone's shrine stands just inland of its dock, so a boat arriving
	-- at any water is met by that water's sigil before its pier is.
	local outerShrineAt: { [string]: Vector2 } = {}
	for _, zone in Config.zones do
		if zone.id == "shallows" then
			continue
		end
		local dock = SeaPlan.dockPoint(zone)
		local seaward = (zone.center - dock).Unit
		local at = dock - seaward * 46
		outerShrineAt[zone.id] = at
		addLand("shrine", at, yawOf(seaward), { flavor = zone.id })
	end

	-- The kelp campfire: a short walk along the flat from the shrine.
	do
		local zone = Config.zone("kelp")
		local dock = SeaPlan.dockPoint(zone)
		local seaward = (zone.center - dock).Unit
		local perp = Vector2.new(-seaward.Y, seaward.X)
		local fireA = dock + perp * 40
		local fireB = dock - perp * 40
		local fireAt = if heightAt(field, fireA) >= SEA + 1 then fireA else fireB
		addLand("campfire", fireAt, yawOf(seaward))
	end

	-- ------------------------------------------------------ the watchtower ----
	-- The north ridge is the map's one high silhouette; the site is measured,
	-- not assumed, and the scan is ordered so it is deterministic.
	do
		local function towerOk(p: Vector2): boolean
			return heightAt(field, p) >= SEA + 10
				and field:slope(p.X, p.Y) >= 0.8
				and (p - hub).Magnitude >= 140
		end
		local site: Vector2? = nil
		local first = Vector2.new(-948, -116)
		if towerOk(first) then
			site = first
		else
			for ring = 1, 5 do
				local radius = ring * 20
				for step = 0, 11 do
					local angle = step * math.pi / 6
					local p = Vector2.new(-940 + math.cos(angle) * radius, -120 + math.sin(angle) * radius)
					if towerOk(p) then
						site = p
						break
					end
				end
				if site then
					break
				end
			end
		end
		if not site then
			error("[LandmarkService] no watchtower site on the north ridge", 2)
		end
		addLand("watchtower", site :: Vector2, yawToward(site :: Vector2, hub))
	end

	-- -------------------------------------------------------- the cave mouth --
	-- On the abyss rim, facing out of the trench. The rim ring is walkable
	-- land by SeaPlan's own construction.
	do
		local zone = Config.zone("abyss")
		local center = zone.center
		local function caveOk(p: Vector2): boolean
			return heightAt(field, p) >= SEA + 6 and field:slope(p.X, p.Y) >= 0.45
		end
		local site: Vector2? = nil
		local first = center + Vector2.new(-330, 0)
		if caveOk(first) then
			site = first
		else
			for _, radius in { 330, 350, 310 } do
				for step = 0, 11 do
					local angle = step * math.pi / 6
					local p = Vector2.new(center.X + math.cos(angle) * radius, center.Y + math.sin(angle) * radius)
					if caveOk(p) then
						site = p
						break
					end
				end
				if site then
					break
				end
			end
		end
		if not site then
			error("[LandmarkService] no cave-mouth site on the abyss rim", 2)
		end
		local outward = (site :: Vector2 - center).Unit
		addLand("caveMouth", site :: Vector2, yawOf(outward))
	end

	-- ------------------------------------------------------- the shipwreck ----
	-- Coral Steps gets the wreck: a shelving beach between the waterline and
	-- the flat, clear of the pier lane, the dock's own furniture and that
	-- zone's shrine. The bow is aimed at the fishing water.
	do
		local zone = Config.zone("coral")
		local dock = SeaPlan.dockPoint(zone)
		local seaward = (zone.center - dock).Unit
		local laneA = dock
		local laneB = dock + seaward * 150
		local shrine = outerShrineAt.coral
		local site: Vector2? = nil
		for step = 0, 15 do
			local angle = step * math.pi / 8
			local dir = Vector2.new(math.cos(angle), math.sin(angle))
			for radius = 70, 98, 4 do
				local p = dock + dir * radius
				local h = heightAt(field, p)
				if h >= SEA + 1.2 and h <= SEA + 4.5
					and field:slope(p.X, p.Y) >= 0.45
					and segmentDistance(p, laneA, laneB) >= 30
					and (p - shrine).Magnitude >= 45 then
					site = p
					break
				end
			end
			if site then
				break
			end
		end
		if not site then
			error("[LandmarkService] no shipwreck beach on Coral Steps", 2)
		end
		addLand("shipwreck", site :: Vector2, yawToward(site :: Vector2, zone.center))
	end

	-- -------------------------------------------------------- the sea arch ----
	-- Standing on the seabed in water a few studs deep, on the shallow arcs
	-- either side of the hub pier, facing the harbor. Placed last of the
	-- water marks so it can hold 60 studs off every land landmark.
	do
		local function clearOfLand(p: Vector2, spacing: number): boolean
			for _, item in items do
				if item.tag == "land" then
					if (p - Vector2.new(item.at.X, item.at.Z)).Magnitude < spacing then
						return false
					end
				end
			end
			return true
		end
		local laneA = Vector2.new(hub.X, hub.Y + 97)
		local laneB = Vector2.new(hub.X + 6, hub.Y + 181)
		local site: Vector2? = nil
		for _, band in { { 10, 75 }, { 105, 170 } } do
			for angle = band[1], band[2], 5 do
				local a = math.rad(angle)
				local dir = Vector2.new(math.cos(a), math.sin(a))
				for radius = 112, 176, 8 do
					local p = hub + dir * radius
					local depth = SEA - heightAt(field, p)
					if depth >= 2.5 and depth <= 9.5
						and segmentDistance(p, laneA, laneB) >= 30
						and clearOfLand(p, 60) then
						site = p
						break
					end
				end
				if site then
					break
				end
			end
			if site then
				break
			end
		end
		if not site then
			error("[LandmarkService] no sea-arch site in the shallows", 2)
		end
		add("seaArch", "water", site :: Vector2, heightAt(field, site :: Vector2), yawToward(site :: Vector2, hub))
	end

	-- ------------------------------------------------------- the reef floor ---
	-- Kelp and coral — exactly the zones SeaPlan calls `depth = "reef"` —
	-- get a jittered 26-stud lattice of kelp strands, rocks and glow plants
	-- on the seabed. The lattice is what keeps the soles apart; the per-cell
	-- stream decides what grows.
	for _, zone in Config.zones do
		if zone.depth ~= "reef" then
			continue
		end
		local zoneName = "tidebound.reef." .. zone.id
		local dock = SeaPlan.dockPoint(zone)
		local laneA = dock
		local laneB = dock + (zone.center - dock).Unit * 150
		local placed = 0
		for gx = -7, 7 do
			for gz = -7, 7 do
				local cell = Vector2.new(zone.center.X + gx * 26, zone.center.Y + gz * 26)
				if (cell - zone.center).Magnitude > zone.radius * 0.7 then
					continue
				end
				local cellStream = stream(zoneName, cell.X, cell.Y)
				local p = cell + cellStream:inDisc(6)
				local h = heightAt(field, p)
				local depth = SEA - h
				if depth < 1.5 or depth > 36 then
					continue
				end
				if segmentDistance(p, laneA, laneB) < LANE_CLEARANCE then
					continue
				end
				placed += 1
				if placed > REEF_CAP then
					continue
				end
				local kindRoll = cellStream:number()
				local kind = if kindRoll < 0.5
					then "kelpStrand"
					elseif kindRoll < 0.78
					then "reefRock"
					else "glowPlant"
				add(kind, "reef", p, h, cellStream:number() * math.pi * 2, {
					scale = 0.9 + cellStream:number() * 0.6,
					zone = zone.id,
				})
			end
		end
	end

	local counts: { [string]: number } = { land = 0, water = 0, reef = 0, total = #items }
	for _, item in items do
		counts[item.tag] = (counts[item.tag] or 0) + 1
	end

	return { items = items, hash = layoutHash(items), counts = counts }
end

-- ============================== night dressing ==============================
--[[
	One behaviour, on purpose: at dusk the lantern's beam starts sweeping and
	the campfire breathes harder. Every other flame — the lanterns, the braziers,
	the shrine sigils — just burns; a night that turns nine lights on at once is
	a light switch, not weather.

	The beam is two Attachments and one Position write per tick; nothing moves
	and nothing is welded.
]]
function LandmarkService.dressNight(root: Instance)
	local Lighting = game:GetService("Lighting")

	local beam: Beam? = nil
	local beamEnd: Attachment? = nil
	local fire: PointLight? = nil
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("Beam") then
			beam = descendant
		elseif descendant:IsA("Attachment") and descendant.Name == "BeamEnd" then
			beamEnd = descendant
		elseif descendant:IsA("PointLight") and descendant.Name == "FireLight" then
			fire = descendant
		end
	end

	local sweepRadius = 72
	if beamEnd then
		sweepRadius = beamEnd.Position.Magnitude
	end

	local phase = 0
	task.spawn(function()
		while root.Parent do
			task.wait(0.1)
			phase += 0.1
			local hour = Lighting.ClockTime
			local night = hour >= Config.nightStartHour or hour < Config.nightEndHour
			if beam then
				beam.Enabled = night
				if night and beamEnd then
					local heading = phase * 1.1
					beamEnd.Position = Vector3.new(
						math.sin(heading) * sweepRadius, 0, math.cos(heading) * sweepRadius)
				end
			end
			if fire then
				fire.Brightness = 2.4 + 0.5 * math.sin(phase * 6.3)
			end
		end
	end)
end

-- ================================== startup =================================
function LandmarkService.start(services: any?)
	services = services or {}
	local started = os.clock()

	-- Resolved here, not at module scope: `plan` must stay loadable in the
	-- headless harness, and Forge lazily indexes `script` on first access.
	-- `Forge.Core.Rng` is the exported module table, not a ModuleScript:
	-- requiring it is invalid-argument and kills the whole boot (measured).
	local World = Forge.World :: any
	local Debug = Forge.Debug :: any
	local Rng = Forge.Core.Rng :: any
	--: The quality vocabulary, resolved here for the same reason as the rest.
	local Mark = Forge.Mark :: any

	local field = services.WorldService and services.WorldService.field
	if not field then
		field = World.heightfield(SeaPlan.heightfieldConfig())
	end

	local result = LandmarkService.plan({ field = field, streamFor = Rng.at })

	local root = Workspace:FindFirstChild("TideboundLandmarks")
	if not root then
		root = Instance.new("Folder")
		root.Name = "TideboundLandmarks"
		root.Parent = Workspace
	end

	--: Reef scatter is scenery, not landmark; it still has to name what it is.
	local REEF_VISUAL_TYPES: { [string]: string } = {
		kelpStrand = "plant",
		glowPlant = "plant",
		reefRock = "rock",
	}

	for index, item in result.items do
		-- The plan knows the heightfield; the world is painted terrain. The
		-- runtime trusts the measurement over the plan, exactly as the hub
		-- does, and only falls back to the plan's height with no ground hit.
		local y = item.at.Y
		local hit = World.surface(item.at.X, item.at.Z, { ignoreWater = true, from = 400 })
		if hit then
			y = hit.Y
		end
		if item.tag == "land" and y < SEA + 0.8 then
			y = SEA + 0.8
		end
		local model = LandmarkKit.build({
			kind = item.kind,
			at = Vector3.new(item.at.X, y, item.at.Z),
			yaw = item.yaw,
			scale = item.scale,
			flavor = item.flavor,
		}, root)
		if model then
			local visualType = REEF_VISUAL_TYPES[item.kind] or "landmark"
			local variant = if item.flavor then item.kind .. "-" .. item.flavor else item.kind
			Mark.root(model, visualType, variant, "landmark-kit")
			if item.kind == "lighthouse" then
				Mark.landmark(model, "lighthouse")
				Mark.ringAnchors(model, "lighthouse", 8, 12)
			elseif item.kind == "seaArch" then
				Mark.landmark(model, "sea-arch")
				Mark.ringAnchors(model, "sea-arch", 8, 16)
			end
		end
		if index % 8 == 0 then
			task.wait()
		end
	end

	LandmarkService.dressNight(root)

	Debug.count("landmarks.props", #root:GetDescendants())
	Debug.info(string.format("landmarks: %d props (%d land, %d water, %d reef) hash %s in %.1fs",
		result.counts.total, result.counts.land, result.counts.water, result.counts.reef,
		result.hash, os.clock() - started))
end

return LandmarkService
