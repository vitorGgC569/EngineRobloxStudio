--!strict
--[[
	FishingService — the loop.

	A cast goes: the client asks, the server decides everything that matters.
	The server picks the spot's zone from the *bobber's* position rather than
	the player's, rolls the bite delay, rolls the fish when the bite lands,
	and only the fight itself is reported back -- as an outcome, which is then
	checked against the session it is claiming to be.

	What the client is trusted with: that a human held a button well or badly.
	What it is not: what bit, how heavy it was, what it is worth, or whether
	the session ever existed. Those are rolled here, at the moment of the
	bite, before the client has heard of the fish at all.

	Fishing from the helm is deliberate, not tolerated. Casting from your own
	boat's seat is legal, rolls with the boat's luck bonus, and the throw's
	origin -- measured against a hull that keeps moving after the click -- is
	given slack in proportion to her speed. The rule that decides "aboard" is
	the seat's own `Owner` attribute, the same traversal the HUD reads, so
	the luck shown aboard is the luck rolled aboard.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local Debug = Forge.Debug
local Rng = Forge.Core.Rng

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local FishCatalog = require(Shared.FishCatalog)
local Roll = require(Shared.Roll)

local DataService = require(script.Parent.DataService)
local QuestService = require(script.Parent.QuestService)
local BestiaryService = require(script.Parent.BestiaryService)
local LeaderboardService = require(script.Parent.LeaderboardService)
local WeatherService = require(script.Parent.WeatherService)
local WorldService = require(script.Parent.WorldService)

local FishingService = {}

local SEA = Config.waterLevel

--: player -> cast state. One rod, one line.
local active: { [Player]: any } = {}
local nextSession = 0

-- ================================ bobber ====================================
local function bobbersFolder(): Instance
	local folder = Workspace:FindFirstChild("Bobbers")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Bobbers"
		folder.Parent = Workspace
	end
	return folder
end

local function spawnBobber(player: Player, target: Vector3): Part
	local bobber = Instance.new("Part")
	bobber.Name = "Bobber_" .. tostring(player.UserId)
	bobber.Shape = Enum.PartType.Ball
	bobber.Size = Vector3.new(0.7, 0.7, 0.7)
	bobber.Position = Vector3.new(target.X, SEA + 0.22, target.Z)
	bobber.Anchored = true
	bobber.CanCollide = false
	bobber.CanQuery = false
	bobber.CanTouch = false
	bobber.Material = Enum.Material.SmoothPlastic
	bobber.Color = Color3.fromRGB(220, 62, 56)
	bobber.CastShadow = false
	bobber.Parent = bobbersFolder()

	local cap = Instance.new("Part")
	cap.Name = "Top"
	cap.Shape = Enum.PartType.Ball
	cap.Size = Vector3.new(0.42, 0.42, 0.42)
	cap.Position = bobber.Position + Vector3.new(0, 0.26, 0)
	cap.Anchored = true
	cap.CanCollide = false
	cap.CanQuery = false
	cap.CanTouch = false
	cap.Color = Color3.fromRGB(240, 238, 230)
	cap.CastShadow = false
	cap.Parent = bobbersFolder()

	local ripple = Instance.new("Part")
	ripple.Name = "Ripple"
	ripple.Shape = Enum.PartType.Cylinder
	ripple.Size = Vector3.new(0.12, 4.6, 4.6)
	ripple.CFrame = CFrame.new(Vector3.new(target.X, SEA + 0.06, target.Z)) * CFrame.Angles(0, 0, math.pi / 2)
	ripple.Anchored = true
	ripple.CanCollide = false
	ripple.CanQuery = false
	ripple.CanTouch = false
	ripple.Material = Enum.Material.Neon
	ripple.Color = Color3.fromRGB(210, 240, 246)
	ripple.Transparency = 0.72
	ripple.CastShadow = false
	ripple.Parent = bobbersFolder()

	local model = Instance.new("Model")
	model.Name = "Bobber"
	bobber.Parent = model
	cap.Parent = model
	ripple.Parent = model
	model.PrimaryPart = bobber
	model.Parent = bobbersFolder()
	return bobber
end

-- ================================ lifecycle =================================
local function cleanup(player: Player, outcome: string)
	local cast = active[player]
	if not cast then
		return
	end
	active[player] = nil
	if cast.bobber and cast.bobber.Parent then
		local model = cast.bobber:FindFirstAncestorOfClass("Model")
		;(model or cast.bobber):Destroy()
	end
	if outcome and outcome ~= "resolved" then
		Net.fire(player, "CastEnd", { sessionId = cast.sessionId, outcome = outcome })
	end
end

--: The seat of the player's own boat they are sitting in, or nil. Mirrors
--: DataService.state's aboard traversal exactly -- the seat's `Owner`
--: attribute against the UserId -- so the luck a client is shown and the
--: luck beginBite rolls cannot disagree; and it names the moving frame a
--: cast from the helm was measured against.
local function aboardSeat(player: Player): Seat?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if seat and seat:GetAttribute("Owner") == player.UserId then
		return seat
	end
	return nil
end

--: A catch is rolled at the bite and paid at the landing, so the difficulty
--: the client feels is derived from the fish that was already decided.
local function beginBite(player: Player, cast: any)
	if active[player] ~= cast then
		return
	end
	local profile = DataService.profile(player)
	if not profile then
		cleanup(player, "lost")
		return
	end

	local rod = Items.rodById[profile.rods.equipped] or Items.rodById.bamboo
	--: `aboard` was hardcoded false here while the HUD derived it from the
	--: seat: the boat's luck bonus was displayed but never rolled. It is now
	--: the same predicate the display uses, so the two cannot drift apart.
	local luck = Roll.luckTotal(
		Config.levelForXp(profile.xp or 0),
		profile.rods.equipped,
		profile.baits.equipped,
		profile.boats.equipped,
		aboardSeat(player) ~= nil) + WeatherService.luckBonus()

	local stream = Rng.at("catch", player.UserId, cast.sessionId)
	local result = Roll.fish({
		zoneId = cast.zoneId,
		luck = luck,
		hour = WeatherService.hour(),
		weather = WeatherService.phase(),
		bait = profile.baits.equipped,
		rng = function()
			return stream:number()
		end,
	})

	--: Bait is spent by the fish that ate it, not by the cast. A cast into
	--: empty water costs a worm only when a worm was actually taken.
	local bait = profile.baits.equipped and Items.baitById[profile.baits.equipped]
	if bait and (profile.baits.owned[bait.id] or 0) > 0 then
		profile.baits.owned[bait.id] -= 1
		if profile.baits.owned[bait.id] <= 0 then
			profile.baits.owned[bait.id] = 0
		end
	end

	local ratio = result.weightKg / math.max(rod.power, 1)
	local difficulty = math.clamp(0.3 + 0.7 * ratio, 0.3, 1.5)
	local duration = Config.reelTimeoutBase + difficulty * Config.reelTimeoutPerDifficulty

	cast.phase = "bite"
	cast.session = {
		result = result,
		difficulty = difficulty,
		duration = duration,
		seed = (player.UserId * 31 + cast.sessionId * 7919) % 2147483647,
		biteClock = os.clock(),
	}

	Net.fire(player, "Bite", {
		sessionId = cast.sessionId,
		difficulty = difficulty,
		duration = duration,
		seed = cast.session.seed,
	})
	Debug.count("bites")

	--: If the client never answers -- tab closed, connection dropped -- the
	--: line comes back on its own clock rather than hanging forever.
	task.delay(duration + 10, function()
		if active[player] == cast and cast.phase == "bite" then
			cleanup(player, "escaped")
		end
	end)
end

-- ================================ the cast ==================================
--[[
	Refuse a throw loudly enough for the client to come back to idle.

	Every `Cast` request must get exactly one terminal answer: CastState for
	one that lands, CastEnd for one that does not. A refused throw used to
	return silently, which left the client in its optimistic "casting" phase
	with no way out -- measured live, one "Nothing but ground there" and the
	fisher could not cast again until rejoin, because the next mouse-up was
	ignored in a phase the server never resolved.
]]
local function refuse(player: Player, reason: string)
	Debug.count("casts.refused." .. reason)
	Net.fire(player, "CastEnd", { outcome = "refused" })
end

local function tryCast(player: Player, origin: Vector3, target: Vector3)
	if active[player] then
		return
	end
	local profile = DataService.profile(player)
	if not profile then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	--[[
		The throw has to start where the angler is and end where the rod can
		actually reach. Both are cheap to check and both are the first thing
		an exploit would lie about.

		From the helm the start is a moving frame: the hull has drifted for
		the round trip by the time this arrives, so the origin tolerance
		grows with her speed -- about a second of lag, capped -- while the
		reach itself stays exact.
	]]
	local seat = aboardSeat(player)
	local originSlack = 14
	if seat then
		originSlack += math.min(seat.AssemblyLinearVelocity.Magnitude, 90)
	end
	if (origin - root.Position).Magnitude > originSlack then
		refuse(player, "origin")
		return
	end
	local rod = Items.rodById[profile.rods.equipped] or Items.rodById.bamboo
	local distance = (target - origin).Magnitude
	if distance < 6 or distance > rod.range * 1.08 + 4 then
		refuse(player, "range")
		return
	end
	if target.Y > SEA + 4 then
		refuse(player, "air")
		return
	end

	local zone = Config.zoneAt(target)
	if zone and not profile.zones[zone.id] then
		Net.fire(player, "Notify", { text = string.format("%s is not charted yet.", zone.name) })
		refuse(player, "locked")
		return
	end
	if not WorldService.isWater(target) then
		Net.fire(player, "Notify", { text = "Nothing but ground there." })
		refuse(player, "ground")
		return
	end

	nextSession += 1
	local sessionId = nextSession
	local bobber = spawnBobber(player, target)

	--: Zone comes from where the bobber lands, not where the player stands,
	--: so casting across a border catches the water it landed in.
	local zoneId = zone and zone.id or "shallows"
	local stream = Rng.at("bite", player.UserId, sessionId)
	local bait = profile.baits.equipped
		and (profile.baits.owned[profile.baits.equipped] or 0) > 0
		and Items.baitById[profile.baits.equipped]
	local biteDelay = stream:number(Config.biteMinSeconds, Config.biteMaxSeconds)
		* WeatherService.modifier().bite
		* (bait and bait.bite or 1)
		* stream:number(0.92, 1.08)

	local cast = {
		player = player,
		sessionId = sessionId,
		bobber = bobber,
		zoneId = zoneId,
		target = target,
		phase = "waiting",
		startedAt = os.clock(),
	}
	active[player] = cast

	Net.fire(player, "CastState", {
		sessionId = sessionId,
		at = target,
		landsIn = Config.bobberSettleSeconds,
	})
	Debug.count("casts")

	task.delay(biteDelay, function()
		beginBite(player, cast)
	end)
end

-- =============================== the landing ================================
local function resolveCatch(player: Player, cast: any, integrity: number)
	local profile = DataService.profile(player)
	if not profile then
		return
	end
	local result = cast.session.result
	local species = FishCatalog.byId[result.speciesId]
	local tier = FishCatalog.rarityById[result.rarity]
	local mutation = nil
	for _, entry in Config.mutations do
		if entry.id == result.mutation then
			mutation = entry
		end
	end

	local catch = {
		speciesId = result.speciesId,
		weightKg = result.weightKg,
		mutation = result.mutation,
		value = result.value,
		integrity = integrity,
	}

	local isNew, isRecord = DataService.recordCatch(player, catch)
	local stored = DataService.crateAdd(player, catch)

	DataService.addXp(player, result.xp)

	QuestService.record(player, {
		kind = "catch",
		speciesId = result.speciesId,
		zoneId = cast.zoneId,
		rarity = result.rarity,
		weightKg = result.weightKg,
		mutation = result.mutation,
		integrity = integrity,
		weather = WeatherService.phase(),
	})
	BestiaryService.afterCatch(player, isNew)
	LeaderboardService.afterCatch(player, result)

	local state = DataService.state(player)
	Net.fire(player, "CatchResult", {
		sessionId = cast.sessionId,
		speciesId = result.speciesId,
		name = species.name,
		blurb = species.blurb,
		cclass = species.cclass,
		rarity = result.rarity,
		rarityName = tier.name,
		mutation = result.mutation,
		mutationName = mutation and mutation.name or "Normal",
		weightKg = result.weightKg,
		value = result.value,
		xp = result.xp,
		isNew = isNew,
		isRecord = isRecord,
		stored = stored,
		crateCount = state and #state.crate or 0,
		crateCap = state and state.crateCap or Config.baseCrate,
		perfect = integrity >= 0.85,
	})
	Net.fire(player, "CastEnd", { sessionId = cast.sessionId, outcome = "caught" })
	Debug.count("catches")
	if isNew then
		Debug.count("catches.new")
	end
	Debug.info(string.format("catch: %s %.2fkg (%s) worth $%d", species.name, result.weightKg, result.mutation, result.value))
end

local function onReelResult(player: Player, payload: any)
	local cast = active[player]
	if not cast or cast.phase ~= "bite" then
		return
	end
	if cast.sessionId ~= payload.sessionId then
		Debug.count("reel.stale")
		return
	end

	local elapsed = payload.elapsed
	local integrity = math.clamp(payload.integrity, 0, 1)
	local serviceElapsed = os.clock() - cast.session.biteClock

	--[[
		A reported win has to be plausible on the server's own clock. The
		floor catches "won in 40 milliseconds"; the ceiling catches a result
		that claims to have taken four times as long as the bite has existed
		-- answers to rounds that never happened.
	]]
	local won = payload.won
	if won and (elapsed < Config.minReelSeconds or elapsed > cast.session.duration + 4) then
		won = false
		Debug.count("reel.refused")
	end
	if won and serviceElapsed + 3 < elapsed then
		won = false
		Debug.count("reel.refused")
	end

	if won then
		active[player] = nil
		if cast.bobber and cast.bobber.Parent then
			local model = cast.bobber:FindFirstAncestorOfClass("Model")
			;(model or cast.bobber):Destroy()
		end
		resolveCatch(player, cast, integrity)
	else
		local profile = DataService.profile(player)
		if profile then
			profile.stats.escaped += 1
		end
		cleanup(player, payload.integrity <= 0.001 and "snapped" or "escaped")
		Debug.count("escapes")
	end
end

-- ================================== start ===================================
function FishingService.start()
	Net.on("Cast", function(player: Player, payload: any)
		tryCast(player, payload.origin, payload.target)
	end)

	Net.on("ReelResult", onReelResult)

	Net.on("CancelCast", function(player: Player)
		local cast = active[player]
		if cast then
			cleanup(player, "cancelled")
			DataService.push(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		cleanup(player, "resolved")
	end)

	--: Death ends the line. Swimming back to it is not a feature anyone asked
	--: for, and a bobber left over from a dead cast would be a lie about what
	--: is in the water.
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterRemoving:Connect(function()
			cleanup(player, "resolved")
		end)
	end)

	Debug.info("fishing armed")
end

--: For tests and probes: is this player mid-cast?
function FishingService.isCasting(player: Player): boolean
	return active[player] ~= nil
end

return FishingService
