--!strict
-- Reusable authored setpieces assembled from WorldKit primitives.
--
-- A setpiece sits between a grammar blockout and a bespoke mesh. It owns a
-- recognizable spatial composition, but no game identity, quest logic or
-- uploaded asset. Callers decide what the focus means; this module makes sure
-- the player can enter, cross the nave and find it.

local Build = require(script.Parent.Build)
local Semantics = require(script.Parent.Semantics)
local Tokens = require(script.Parent.Tokens)

local Setpiece = {}

export type Roles = {
	stone: string?,
	trim: string?,
	floor: string?,
	wood: string?,
	metal: string?,
	focus: string?,
}

export type SanctuarySpec = {
	--- World transform. The entrance faces local -Z and the focus sits at +Z.
	cframe: CFrame?,
	width: number?,
	length: number?,
	wallHeight: number?,
	--- Clear width between the two pillar rows.
	naveWidth: number?,
	--- Number of longitudinal arcade openings.
	bays: number?,
	seed: number?,
	focusKind: ("altar" | "bell")?,
	roles: Roles?,
}

export type SanctuaryResult = {
	model: Model,
	nave: BasePart,
	entrance: BasePart,
	focus: BasePart,
	parts: number,
	pillars: number,
	arches: number,
	brokenWalls: number,
}

local function fail(message: string): never
	error("[WorldKit.Setpiece] " .. message, 0)
end

local function positive(value: number, label: string): number
	if value <= 0 then
		fail(label .. " must be positive")
	end
	return value
end

--- An open, playable gothic ruin with a clear central nave.
---
--- The returned `focus` is a real BasePart suitable for a ProximityPrompt,
--- Guidance target or authoritative interaction. Nothing here attaches game
--- behaviour: the same sanctuary can hold a key, bell, boss gate or checkpoint.
function Setpiece.ruinedSanctuary(parent: Instance, tokens: Tokens.TokenSet,
	spec: SanctuarySpec?): SanctuaryResult
	local options = spec or {}
	local roomMinimum = tokens:grammar("roomMinDimension")
	local corridor = tokens:grammar("corridorWidth")
	local doorHeight = tokens:grammar("doorHeight")
	local doorWidth = tokens:grammar("doorWidth")
	local ceiling = tokens:grammar("ceilingHeight")

	local width = positive(options.width or roomMinimum * 2.4, "width")
	local length = positive(options.length or roomMinimum * 3.4, "length")
	local wallHeight = positive(options.wallHeight or math.max(ceiling * 1.6,
		doorHeight * 1.8), "wallHeight")
	local naveWidth = positive(options.naveWidth or corridor * 1.35, "naveWidth")
	local bays = options.bays or math.clamp(math.floor(length / (roomMinimum * 0.8)), 3, 7)
	local focusKind = options.focusKind or "altar"

	-- Refuse before parenting the Model: a bad request must not leave half a ruin
	-- behind for a later build to mistake for a valid setpiece.
	if width < roomMinimum * 1.8 then
		fail(string.format("width %.1f is below the playable minimum %.1f", width,
			roomMinimum * 1.8))
	end
	if length < roomMinimum * 2.2 then
		fail(string.format("length %.1f is below the playable minimum %.1f", length,
			roomMinimum * 2.2))
	end
	if wallHeight < doorHeight + tokens:grammar("stairRise") * 2 then
		fail("wallHeight must clear the token doorway")
	end
	if naveWidth < corridor then
		fail("naveWidth must be at least the token corridorWidth")
	end
	if naveWidth > width - corridor then
		fail("naveWidth leaves no playable side aisles")
	end
	if bays ~= math.floor(bays) or bays < 3 or bays > 10 then
		fail("bays must be an integer from 3 through 10")
	end
	if focusKind ~= "altar" and focusKind ~= "bell" then
		fail("focusKind must be altar or bell")
	end

	local roles = options.roles or {}
	local stoneRole = roles.stone or "stonePrimary"
	local trimRole = roles.trim or "stoneSecondary"
	local floorRole = roles.floor or "pavement"
	local woodRole = roles.wood or "woodSecondary"
	local metalRole = roles.metal or "metalDark"
	local focusRole = roles.focus or "accentGold"
	for label, role in pairs({
		stone = stoneRole,
		trim = trimRole,
		floor = floorRole,
		wood = woodRole,
		metal = metalRole,
		focus = focusRole,
	}) do
		if not tokens:hasRole(role) then
			fail(string.format("%s role %q does not exist in token set %q", label, role,
				tokens.id))
		end
	end

	local origin = options.cframe or CFrame.identity
	local random = Random.new(options.seed or 1)
	local model = Instance.new("Model")
	model.Name = "RuinedSanctuary"
	model:SetAttribute("WorldKitSetpiece", "ruined-sanctuary")
	model:SetAttribute("OpenRoof", true)
	model:SetAttribute("NaveClearWidth", naveWidth)
	model:SetAttribute("Bays", bays)
	model:SetAttribute("FocusKind", focusKind)
	model.Parent = parent
	Semantics.root(model, "architecture", "ruined-sanctuary",
		"worldkit.setpiece.ruined-sanctuary")

	local partCount = 0
	local function placed(name: string, size: Vector3, localCFrame: CFrame,
		role: string, canCollide: boolean?): Part
		local worldCFrame = origin * localCFrame
		local part = Build.part(model, name, size, worldCFrame.Position, tokens:swatch(role), {
			canCollide = canCollide,
		})
		part.CFrame = worldCFrame
		partCount += 1
		return part
	end

	local function cylinder(name: string, diameter: number, height: number,
		localPosition: Vector3, role: string): Part
		local worldCFrame = origin * CFrame.new(localPosition)
		local part = Build.cylinder(model, name, Vector3.new(diameter, height, diameter),
			worldCFrame.Position, tokens:swatch(role))
		part.CFrame = origin * CFrame.new(localPosition)
			* CFrame.Angles(0, 0, math.rad(90))
		partCount += 1
		return part
	end

	local function beam(name: string, from: Vector3, to: Vector3, thickness: number,
		role: string): Part
		local distance = (to - from).Magnitude
		local centre = from:Lerp(to, 0.5)
		return placed(name, Vector3.new(thickness, thickness, distance),
			CFrame.lookAt(centre, to), role)
	end

	-- Three floor masses make the nave legible without putting any obstruction
	-- in it. The threshold is returned so spawn/guidance code has a stable entry.
	local floorThickness = math.max(tokens:grammar("stairRise") * 0.35, 0.4)
	local arcadeX = naveWidth / 2 + doorWidth * 0.22
	local sideWidth = width / 2 - arcadeX
	local nave = placed("NaveFloor", Vector3.new(arcadeX * 2, floorThickness, length),
		CFrame.new(0, -floorThickness / 2, 0), floorRole)
	placed("AisleFloor", Vector3.new(sideWidth, floorThickness, length),
		CFrame.new(-(arcadeX + sideWidth / 2), -floorThickness / 2, 0), trimRole)
	placed("AisleFloor", Vector3.new(sideWidth, floorThickness, length),
		CFrame.new(arcadeX + sideWidth / 2, -floorThickness / 2, 0), trimRole)
	local entrance = placed("EntranceThreshold",
		Vector3.new(naveWidth, floorThickness * 1.25, doorWidth * 0.45),
		CFrame.new(0, -floorThickness * 0.25, -length / 2), trimRole)
	entrance:SetAttribute("RQESetpieceRole", "entrance")

	-- Pillar rows and pointed longitudinal arches define the nave. The ruin has
	-- no roof: the ribs stop at the arcade rather than silently forming a ceiling.
	local bayLength = length / bays
	local pillarHeight = wallHeight * 0.64
	local pillarRadius = math.max(doorWidth * 0.15, 1)
	local pillars = 0
	for index = 0, bays do
		local z = -length / 2 + index * bayLength
		for _, side in ipairs({ -1, 1 }) do
			local x = side * arcadeX
			placed("PillarBase",
				Vector3.new(pillarRadius * 2.7, tokens:grammar("stairRise") * 0.8,
					pillarRadius * 2.7),
				CFrame.new(x, tokens:grammar("stairRise") * 0.4, z), trimRole)
			cylinder("PillarShaft", pillarRadius * 2, pillarHeight,
				Vector3.new(x, pillarHeight / 2 + tokens:grammar("stairRise") * 0.8, z),
				stoneRole)
			placed("PillarCapital",
				Vector3.new(pillarRadius * 3.1, tokens:grammar("stairRise"),
					pillarRadius * 3.1),
				CFrame.new(x, pillarHeight + tokens:grammar("stairRise") * 1.3, z), trimRole)
			pillars += 1
		end
	end

	local arches = 0
	local archThickness = math.max(pillarRadius * 0.9, 0.9)
	local springY = pillarHeight + tokens:grammar("stairRise") * 1.8
	for bay = 1, bays do
		local z0 = -length / 2 + (bay - 1) * bayLength
		local z1 = z0 + bayLength
		local peak = Vector3.new(0, wallHeight, (z0 + z1) / 2)
		for _, side in ipairs({ -1, 1 }) do
			local x = side * arcadeX
			local localPeak = Vector3.new(x, peak.Y, peak.Z)
			beam("ArcRib", Vector3.new(x, springY, z0), localPeak,
				archThickness, trimRole)
			beam("ArcRib", localPeak, Vector3.new(x, springY, z1),
				archThickness, trimRole)
			arches += 1
		end
	end

	-- Broken side curtains deliberately alternate mass and open air. Each mass
	-- has two unequal shoulders, so its top cannot read as one intact low wall.
	local brokenWalls = 0
	local outerX = width / 2
	local wallThickness = math.max(doorWidth * 0.18, 1.2)
	for bay = 1, bays do
		local z = -length / 2 + (bay - 0.5) * bayLength
		for _, side in ipairs({ -1, 1 }) do
			local heightA = wallHeight * random:NextNumber(0.28, 0.58)
			local heightB = heightA * random:NextNumber(0.5, 0.82)
			local span = bayLength * random:NextNumber(0.2, 0.32)
			for shoulder, height in ipairs({ heightA, heightB }) do
				local offset = (shoulder == 1 and -1 or 1) * span * 0.55
				placed("BrokenWall", Vector3.new(wallThickness, height, span),
					CFrame.new(side * outerX, height / 2, z + offset), stoneRole)
				brokenWalls += 1
			end
			-- A buttress at every bay gives the broken curtain a plausible support.
			placed("Buttress", Vector3.new(wallThickness * 2.2, wallHeight * 0.52,
				wallThickness * 2.8),
				CFrame.new(side * (outerX + wallThickness * 0.45), wallHeight * 0.26,
					z - bayLength / 2), trimRole)
		end
	end

	-- Broken end walls frame, but never close, the entrance and focal axis.
	local endSpan = (width - naveWidth) / 4
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (naveWidth / 2 + endSpan / 2)
		local backHeight = wallHeight * (if side < 0 then 0.72 else 0.5)
		placed("BrokenApseWall", Vector3.new(endSpan, backHeight, wallThickness),
			CFrame.new(x, backHeight / 2, length / 2), stoneRole)
		placed("BrokenEntranceWall",
			Vector3.new(endSpan, wallHeight * 0.36, wallThickness),
			CFrame.new(x, wallHeight * 0.18, -length / 2), stoneRole)
		brokenWalls += 2
	end

	-- Rubble stays in the side aisles. A deterministic seed changes the damage
	-- pattern while the central route remains guaranteed clear.
	for index = 1, bays * 2 do
		local side = if index % 2 == 0 then 1 else -1
		local x = side * random:NextNumber(arcadeX + pillarRadius * 2,
			math.max(arcadeX + pillarRadius * 2.1, outerX - wallThickness * 2))
		local z = random:NextNumber(-length * 0.43, length * 0.43)
		local size = random:NextNumber(pillarRadius * 0.7, pillarRadius * 1.5)
		placed("Rubble", Vector3.new(size * 1.8, size, size * 1.2),
			CFrame.new(x, size / 2, z)
				* CFrame.Angles(random:NextNumber(-0.25, 0.25),
					random:NextNumber(0, math.pi * 2), random:NextNumber(-0.25, 0.25)),
			if index % 3 == 0 then trimRole else stoneRole)
	end

	local focus: BasePart
	local focusZ = length / 2 - math.max(bayLength * 0.48, doorWidth)
	if focusKind == "altar" then
		-- Stepped altar: large enough to read as authored, low enough to interact
		-- with, and positioned only at the terminal end of the clear nave.
		for step = 1, 3 do
			placed("AltarStep",
				Vector3.new(naveWidth * (0.72 - step * 0.08),
					tokens:grammar("stairRise") * 0.55, doorWidth * (1.2 - step * 0.18)),
				CFrame.new(0, tokens:grammar("stairRise") * 0.275 * step,
					focusZ + step * tokens:grammar("stairRun") * 0.2), trimRole)
		end
		local altarHeight = tokens:grammar("railHeight") * 0.86
		placed("AltarBase", Vector3.new(naveWidth * 0.42, altarHeight,
			doorWidth * 0.62), CFrame.new(0, altarHeight / 2 + tokens:grammar("stairRise"),
			focusZ), stoneRole)
		placed("AltarSlab", Vector3.new(naveWidth * 0.52, tokens:grammar("stairRise") * 0.55,
			doorWidth * 0.78), CFrame.new(0, altarHeight + tokens:grammar("stairRise") * 1.25,
			focusZ), trimRole)
		focus = placed("AltarFocus",
			Vector3.new(doorWidth * 0.3, doorWidth * 0.3, doorWidth * 0.3),
			CFrame.new(0, altarHeight + doorWidth * 0.34, focusZ), focusRole, false)
	else
		-- A freestanding bell frame works in an open ruin without inventing a
		-- tower or uploaded mesh. The bell itself is the interaction target.
		local frameWidth = math.min(naveWidth * 0.62, doorWidth * 1.5)
		local frameHeight = doorHeight * 0.9
		for _, side in ipairs({ -1, 1 }) do
			placed("BellPost", Vector3.new(doorWidth * 0.24, frameHeight,
				doorWidth * 0.24),
				CFrame.new(side * frameWidth / 2, frameHeight / 2, focusZ), woodRole)
		end
		placed("BellBeam", Vector3.new(frameWidth + doorWidth * 0.5,
			doorWidth * 0.25, doorWidth * 0.28),
			CFrame.new(0, frameHeight, focusZ), woodRole)
		placed("BellYoke", Vector3.new(frameWidth * 0.56, doorWidth * 0.18,
			doorWidth * 0.18), CFrame.new(0, frameHeight * 0.78, focusZ), metalRole)
		focus = cylinder("Bell", doorWidth * 0.72, doorWidth * 0.62,
			Vector3.new(0, frameHeight * 0.58, focusZ), focusRole)
		local clapper = placed("Clapper",
			Vector3.new(doorWidth * 0.16, doorWidth * 0.52, doorWidth * 0.16),
			CFrame.new(0, frameHeight * 0.48, focusZ), metalRole, false)
		clapper.CanTouch = false
	end

	focus:SetAttribute("RQESetpieceRole", "focus")
	focus:SetAttribute("FocusKind", focusKind)
	model.PrimaryPart = nave
	model:SetAttribute("PartCount", partCount)
	model:SetAttribute("PillarCount", pillars)
	model:SetAttribute("ArchCount", arches)
	model:SetAttribute("BrokenWallCount", brokenWalls)

	return {
		model = model,
		nave = nave,
		entrance = entrance,
		focus = focus,
		parts = partCount,
		pillars = pillars,
		arches = arches,
		brokenWalls = brokenWalls,
	}
end

return Setpiece
