--!strict
-- Map lifecycle: build all maps into ServerStorage at boot, run the intermission
-- vote, clone the winner into Workspace per round, destroy it after. Also owns
-- spawn-point selection, including "zombies respawn near the action but out of
-- survivor sightlines".

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Lighting = game:GetService("Lighting")

local Mall = require(script.Parent.Parent.Maps.Mall)
local Suburbia = require(script.Parent.Parent.Maps.Suburbia)
local Facility = require(script.Parent.Parent.Maps.Facility)
-- Three maps, not five. Warehouse (57 parts, flat by its own admission) and Metro (39
-- parts, two studs of height variation in the whole level) were placeholders shipped as
-- finished content; the effort went into making these three worth replaying instead.
local MAPS = { Mall, Suburbia, Facility }
-- Equal to #MAPS, so every map is always on the ballot: stable buttons, and players learn
-- the rotation instead of being shown a random subset.
local VOTE_CANDIDATES = 3

local MapService = {}
MapService.__index = MapService

export type Deps = {
	remotes: any, -- Remotes.ServerApi
}

local rng = Random.new()

function MapService.new(deps: Deps)
	local self = setmetatable({}, MapService)
	self._deps = deps
	self._storage = Instance.new("Folder")
	self._storage.Name = "Maps"
	self._storage.Parent = ServerStorage
	self._built = {} :: { Model }
	self._active = nil :: Model?
	self._activeIndex = 1
	self._votes = {} :: { [Player]: number } -- player -> candidate slot (1..#candidates)
	self._candidates = {} :: { number } -- actual map indices offered this vote
	self._voteOpen = false

	for _, mapDef in MAPS do
		local model = mapDef.build()
		model.Parent = self._storage
		table.insert(self._built, model)
	end
	return self
end

function MapService:mapNames(): { string }
	local names = {}
	for _, mapDef in MAPS do
		table.insert(names, mapDef.name)
	end
	return names
end

-- Voting -------------------------------------------------------------------------

-- Pick N distinct random map indices to offer this vote.
function MapService:_pickCandidates(): { number }
	local pool = {}
	for i = 1, #MAPS do
		pool[i] = i
	end
	-- Fisher-Yates partial shuffle.
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local out = {}
	for i = 1, math.min(VOTE_CANDIDATES, #MAPS) do
		out[i] = pool[i]
	end
	return out
end

function MapService:openVote()
	table.clear(self._votes)
	self._candidates = self:_pickCandidates()
	self._voteOpen = true
	local names = {}
	for _, index in self._candidates do
		table.insert(names, MAPS[index].name)
	end
	self._deps.remotes.fireAllClients("HordeUpdate", { mapVote = names })
end

-- `slot` is the candidate button index (1..#candidates), not the raw map index.
function MapService:castVote(player: Player, slot: number)
	if self._voteOpen and slot >= 1 and slot <= #self._candidates then
		self._votes[player] = slot
	end
end

function MapService:_tallyWinner(): number
	local candidates = self._candidates
	if #candidates == 0 then
		return rng:NextInteger(1, #MAPS)
	end
	local counts = table.create(#candidates, 0)
	for _, slot in self._votes do
		counts[slot] += 1
	end
	local bestSlot, bestCount = 0, -1
	for i = 1, #candidates do
		if counts[i] > bestCount then
			bestSlot, bestCount = i, counts[i]
		end
	end
	if bestCount <= 0 then
		return candidates[rng:NextInteger(1, #candidates)] -- nobody voted
	end
	return candidates[bestSlot]
end

-- Round lifecycle ------------------------------------------------------------------

function MapService:loadVotedMap(): Model
	self._voteOpen = false
	self:unload()
	local index = self:_tallyWinner()
	self._activeIndex = index
	local clone = self._built[index]:Clone()
	clone.Name = "ActiveMap"
	clone.Parent = workspace

	self:_applyLighting(MAPS[index].lighting)

	self._active = clone
	return clone
end

function MapService:unload()
	if self._active then
		self._active:Destroy()
		self._active = nil
	end
end

-- One place that owns lighting, used by both the round load and the lobby load (the two
-- used to carry duplicated copies of the same block).
--
-- Beyond Ambient/Fog, this drives Brightness and creates the Atmosphere / ColorCorrection /
-- Bloom instances. None of those existed anywhere in the game before, which is a large part
-- of why every map read as the same grey box regardless of its stated time of day.
function MapService:_applyLighting(def: any)
	Lighting.Ambient = def.Ambient
	Lighting.OutdoorAmbient = def.OutdoorAmbient
	Lighting.ClockTime = def.ClockTime
	Lighting.FogEnd = def.FogEnd
	Lighting.FogColor = def.FogColor
	Lighting.FogStart = def.FogStart or 0
	Lighting.Brightness = def.Brightness or 2
	Lighting.ExposureCompensation = def.Exposure or 0

	local function ensure(className: string, name: string): Instance
		local existing = Lighting:FindFirstChild(name)
		if existing and existing.ClassName == className then
			return existing
		end
		if existing then
			existing:Destroy()
		end
		local created = Instance.new(className)
		created.Name = name
		created.Parent = Lighting
		return created
	end

	local atmosphereDef = def.atmosphere
	local atmosphere = ensure("Atmosphere", "MapAtmosphere") :: Atmosphere
	if atmosphereDef then
		atmosphere.Density = atmosphereDef.Density or 0.3
		atmosphere.Offset = atmosphereDef.Offset or 0
		atmosphere.Haze = atmosphereDef.Haze or 1
		atmosphere.Glare = atmosphereDef.Glare or 0
		atmosphere.Color = atmosphereDef.Color or Color3.fromRGB(199, 199, 199)
		atmosphere.Decay = atmosphereDef.Decay or Color3.fromRGB(106, 112, 125)
	else
		atmosphere.Density = 0.2
		atmosphere.Haze = 0
	end

	-- Sky. A custom skybox would need six uploaded textures, but StarCount/SunAngularSize on
	-- the stock sky are free and make a night map read as night rather than as a dark room.
	local skyDef = def.sky
	local sky = ensure("Sky", "MapSky") :: Sky
	sky.StarCount = if skyDef then skyDef.StarCount or 3000 else 3000
	sky.CelestialBodiesShown = if skyDef then skyDef.CelestialBodiesShown ~= false else true
	sky.SunAngularSize = if skyDef then skyDef.SunAngularSize or 21 else 21
	sky.MoonAngularSize = if skyDef then skyDef.MoonAngularSize or 11 else 11

	local fx = def.postFx
	local correction = ensure("ColorCorrectionEffect", "MapColorCorrection") :: ColorCorrectionEffect
	local bloom = ensure("BloomEffect", "MapBloom") :: BloomEffect
	if fx then
		correction.Brightness = fx.Brightness or 0
		correction.Contrast = fx.Contrast or 0
		correction.Saturation = fx.Saturation or 0
		correction.TintColor = fx.TintColor or Color3.fromRGB(255, 255, 255)
		bloom.Intensity = fx.BloomIntensity or 0.4
		bloom.Threshold = fx.BloomThreshold or 0.95
		bloom.Size = fx.BloomSize or 24
	else
		correction.Brightness = 0
		correction.Contrast = 0
		correction.Saturation = 0
		correction.TintColor = Color3.fromRGB(255, 255, 255)
		bloom.Intensity = 0.3
	end
end

-- A map is always present so players never stand on an empty baseplate. Used during
-- intermission and at server start; a round replaces it via loadVotedMap().
function MapService:loadLobby()
	self:unload()
	local index = rng:NextInteger(1, #MAPS)
	self._activeIndex = index
	local clone = self._built[index]:Clone()
	clone.Name = "ActiveMap"
	clone.Parent = workspace
	self:_applyLighting(MAPS[index].lighting)
	self._active = clone
	return clone
end

-- Spawns -------------------------------------------------------------------------
--
-- Markers are author intent; geometry can still trap a character (inside a house shell,
-- jammed in furniture, under a low ceiling). Every public spawn API resolves through
-- `_safeSpawnFrom` so we never hand RoleService / bots a CFrame that is stuck in world
-- collision.

local SPAWN_HRP_HEIGHT = 3.0 -- studs above floor for HumanoidRootPart
local SPAWN_CLEAR_RADIUS = 1.6
local SPAWN_MIN_HEADROOM = 5.5
local SPAWN_WALL_PROBE = 2.2 -- reject if a wall is this close on every axis

function MapService:_spawnsIn(folderName: string): { BasePart }
	local out = {}
	if self._active then
		local folder = self._active:FindFirstChild(folderName)
		if folder then
			for _, marker in folder:GetChildren() do
				if marker:IsA("BasePart") then
					table.insert(out, marker)
				end
			end
		end
	end
	return out
end

function MapService:_excludeList(extraExclude: { Instance }?): { Instance }
	local exclude: { Instance } = {}
	if self._active then
		local survivors = self._active:FindFirstChild("SurvivorSpawns")
		local zombies = self._active:FindFirstChild("ZombieSpawns")
		local patrol = self._active:FindFirstChild("PatrolPoints")
		if survivors then
			table.insert(exclude, survivors)
		end
		if zombies then
			table.insert(exclude, zombies)
		end
		if patrol then
			table.insert(exclude, patrol)
		end
	end
	-- Living characters occupy volume; never treat them as "stuck in geometry".
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	for _, child in workspace:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("IsBot") == true then
			table.insert(exclude, child)
		end
	end
	if extraExclude then
		for _, inst in extraExclude do
			table.insert(exclude, inst)
		end
	end
	return exclude
end

function MapService:_rayParams(extraExclude: { Instance }?): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = self:_excludeList(extraExclude)
	return params
end

-- Try to turn a rough position into a standable, unobstructed spawn CFrame.
-- Returns nil if the candidate is sealed / inside geometry / has no floor.
function MapService:_resolveOpenSpawn(approx: Vector3, extraExclude: { Instance }?): CFrame?
	local params = self:_rayParams(extraExclude)
	-- Drop from above so we land on the topmost floor, not a roof slab below a ceiling.
	local dropFrom = approx + Vector3.new(0, 24, 0)
	local floorHit = workspace:Raycast(dropFrom, Vector3.new(0, -60, 0), params)
	if floorHit == nil or not floorHit.Instance.CanCollide then
		return nil
	end
	-- Reject steep surfaces (walls mistaken for floors).
	if floorHit.Normal.Y < 0.7 then
		return nil
	end
	local feet = floorHit.Position
	local hrp = feet + Vector3.new(0, SPAWN_HRP_HEIGHT, 0)

	-- Headroom: must be able to stand without a ceiling immediately overhead.
	local headHit = workspace:Raycast(hrp, Vector3.new(0, SPAWN_MIN_HEADROOM, 0), params)
	if headHit and headHit.Instance.CanCollide then
		return nil
	end

	-- Horizontal breathing room: at least one axis must not be a tight corridor cage.
	-- (We still allow true hallways; we reject being fully wedged.)
	local blocked = 0
	for _, dir in {
		Vector3.new(1, 0, 0),
		Vector3.new(-1, 0, 0),
		Vector3.new(0, 0, 1),
		Vector3.new(0, 0, -1),
	} do
		local hit = workspace:Raycast(hrp, dir * SPAWN_WALL_PROBE, params)
		if hit and hit.Instance.CanCollide and hit.Distance < 1.1 then
			blocked += 1
		end
	end
	if blocked >= 3 then
		return nil -- almost fully boxed in
	end

	-- Volume check: no solid part overlapping the character capsule.
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = self:_excludeList(extraExclude)
	local parts = workspace:GetPartBoundsInRadius(hrp, SPAWN_CLEAR_RADIUS, overlap)
	for _, part in parts do
		if part:IsA("BasePart") and part.CanCollide and part.Transparency < 1 then
			-- Floors under our feet are fine; anything else in the body volume is a trap.
			local top = part.Position.Y + part.Size.Y / 2
			if top > feet.Y + 0.6 then
				return nil
			end
		end
	end

	return CFrame.new(hrp)
end

function MapService:_safeSpawnFrom(markers: { BasePart }, prefer: ((BasePart) -> number)?): CFrame?
	if #markers == 0 then
		return self:_fallbackOpenSpawn()
	end
	-- Shuffle so retries don't always pick the same bad marker first.
	local order = table.create(#markers)
	for i = 1, #markers do
		order[i] = markers[i]
	end
	for i = #order, 2, -1 do
		local j = rng:NextInteger(1, i)
		order[i], order[j] = order[j], order[i]
	end
	if prefer then
		table.sort(order, function(a, b)
			return prefer(a) < prefer(b)
		end)
	end
	for _, marker in order do
		local resolved = self:_resolveOpenSpawn(marker.Position)
		if resolved then
			return resolved
		end
		-- Nudge outward from the marker in 4 directions and retry (escape furniture clusters).
		for _, offset in {
			Vector3.new(6, 0, 0),
			Vector3.new(-6, 0, 0),
			Vector3.new(0, 0, 6),
			Vector3.new(0, 0, -6),
			Vector3.new(10, 0, 10),
			Vector3.new(-10, 0, -10),
		} do
			resolved = self:_resolveOpenSpawn(marker.Position + offset)
			if resolved then
				return resolved
			end
		end
	end
	return self:_fallbackOpenSpawn()
end

-- Last resort: open ground near map origin so a round can never soft-lock on a bad marker.
function MapService:_fallbackOpenSpawn(): CFrame?
	for _, candidate in {
		Vector3.new(0, 4, 0),
		Vector3.new(20, 4, 0),
		Vector3.new(-20, 4, 0),
		Vector3.new(0, 4, 20),
		Vector3.new(0, 4, -20),
		Vector3.new(40, 4, 40),
	} do
		local resolved = self:_resolveOpenSpawn(candidate)
		if resolved then
			return resolved
		end
	end
	return CFrame.new(0, 8, 0)
end

function MapService:randomSurvivorSpawn(): CFrame?
	return self:_safeSpawnFrom(self:_spawnsIn("SurvivorSpawns"))
end

-- A wander destination for bots. Prefers map-authored PatrolPoints; falls back to spawn
-- markers so this works on maps that predate them. Bots previously wandered between spawn
-- markers only, which made them ping-pong and clump in the same few spots every round.
function MapService:randomPatrolPoint(): Vector3?
	local active = workspace:FindFirstChild("ActiveMap")
	local folder = active and active:FindFirstChild("PatrolPoints")
	if folder then
		local points = folder:GetChildren()
		if #points > 0 then
			-- Prefer patrols that resolve to open ground.
			local shuffled = {}
			for _, p in points do
				if p:IsA("BasePart") then
					table.insert(shuffled, p)
				end
			end
			for i = #shuffled, 2, -1 do
				local j = rng:NextInteger(1, i)
				shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
			end
			for _, pick in shuffled do
				local resolved = self:_resolveOpenSpawn(pick.Position)
				if resolved then
					return resolved.Position
				end
			end
		end
	end
	local spawn = self:randomSurvivorSpawn()
	return spawn and spawn.Position or nil
end

function MapService:zombieSpawnNearAction(survivorRoots: { BasePart }): CFrame?
	local spawns = self:_spawnsIn("ZombieSpawns")
	if #spawns == 0 then
		return self:randomSurvivorSpawn()
	end
	-- Score: prefer near action, not visible, not on top of survivors — then safety filter.
	return self:_safeSpawnFrom(spawns, function(marker: BasePart): number
		local nearest = math.huge
		local visible = false
		for _, root in survivorRoots do
			local offset = root.Position - marker.Position
			local dist = offset.Magnitude
			nearest = math.min(nearest, dist)
			if dist < 120 then
				local params = self:_rayParams({ root.Parent :: Instance })
				local hit = workspace:Raycast(marker.Position, offset, params)
				if hit == nil then
					visible = true
				end
			end
		end
		-- Lower score = better. Penalize too-close and line-of-sight.
		local score = nearest
		if nearest < 25 then
			score += 200
		end
		if visible then
			score += 100
		end
		return score
	end)
end

function MapService:start()
	self._deps.remotes.onValidated("VoteMap", function(player, payload)
		self:castVote(player, payload.mapIndex)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self._votes[player] = nil
	end)
end

return MapService
