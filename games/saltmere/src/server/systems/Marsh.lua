--!strict
--[[
	Marsh — the quay, the plots, and the tide clock.

	Sim decides what a pan is worth. This file only builds the place and says
	which phase the clock is in. Collect, claim, sell and the spring tide are
	registered here and invoked there: the prompt stores no handler of its own,
	because Works and Market bind after the prompt exists.

	No welds. Every part is anchored before it is parented, and the pan basin
	(the PrimaryPart) is never moved when the brine level changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Interaction = Forge.Interaction
local Net = Forge.Net
local Debug = Forge.Debug

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Marsh = {}

local PHASE_ORDER: { string } = { "flood", "settle", "harvest", "spoil" }
local PROMPT_HOLD = 0.35
local PROMPT_RANGE = 14
local NAMEPLATE_DISTANCE = 80

-- The quay's whole light budget. Neon on the lamp room is not a light.
local LANTERN_X = { -70, -34, 18, 48 }

type PhaseListener = (phase: string, tideIndex: number) -> ()
type PanListener = (player: Player, panId: string) -> ()
type PlayerListener = (player: Player) -> ()

type PanView = {
	brine: Part,
	crust: Part,
	bed: CFrame,
	fullHeight: number,
	spanX: number,
	spanZ: number,
}

local phaseListeners: { PhaseListener } = {}
local collectHandler: PanListener? = nil
local claimHandler: PanListener? = nil
local sellHandler: PlayerListener? = nil
local prestigeHandler: PlayerListener? = nil

local slotOf: { [Player]: number } = {}
local ownerOf: { [number]: Player } = {}
local builtFor: { [number]: Player } = {}
local panViews: { [Player]: { [string]: PanView } } = {}
local spawnWatch: { [Player]: RBXScriptConnection } = {}

local started = false
local clockStarted = false
local clockStart = 0
local reportedPhase = "flood"
local reportedIndex = 1
local broadcastAt = 0

-- ================================== helpers =================================

local function color3(channels: { number }): Color3
	local r = channels[1]
	local g = channels[2]
	local b = channels[3]
	if r == nil or g == nil or b == nil then
		return Color3.new(1, 1, 1)
	end
	return Color3.fromRGB(r, g, b)
end

local function folder(name: string): Folder
	local found = Workspace:FindFirstChild(name)
	if found and found:IsA("Folder") then
		return found
	end
	local created = Instance.new("Folder")
	created.Name = name
	created.Parent = Workspace
	return created
end

-- Deck centre is Config.world.quay; the tar sheet is what feet stand on.
local function surfaceY(): number
	return Config.world.quay.y + 1 + 0.22
end

-- A hair under the tar so the causeway seam does not z-fight the wearing surface.
local function pathTop(): number
	return surfaceY() - 0.05
end

local function slotX(index: number): number
	local world = Config.world
	return world.plotOriginX + (index - 1) * world.plotStride
end

local function padHalf(): (number, number)
	local spacing = Config.world.panSpacing
	return (spacing * 3 + 6) / 2, (spacing * 2 + 12) / 2
end

local function walkX(index: number): number
	local world = Config.world
	return slotX(index) - world.panSpacing - world.panSize.x / 2 - 3.5
end

local function causewaySpan(): (number, number, number, number)
	local quay = Config.world.quay
	local south = quay.z + quay.width / 2
	local width = 8
	local centerZ = south + width / 2 - 1.25
	local west = walkX(1) - 4
	local east = walkX(Config.maxPlayers) + 4
	return (west + east) / 2, centerZ, east - west, width
end

local function makePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material,
	canCollide: boolean
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	-- Anchored before the part joins the world. An unanchored weld, or a
	-- prompt on a part that is still loose, is how a character gets thrown.
	part.Anchored = true
	part.CanCollide = canCollide
	part.Parent = parent
	return part
end

local function dropPiling(parent: Instance, x: number, z: number, top: number)
	local bottom = -5
	local height = top - bottom
	if height < 1 then
		return
	end
	makePart(
		parent,
		"Piling",
		Vector3.new(1.1, height, 1.1),
		CFrame.new(x, (top + bottom) / 2, z),
		color3(Config.colors.timber),
		Enum.Material.Wood,
		true
	)
end

local function panTitle(panId: string): string
	local digits = string.match(panId, "%d+")
	if digits then
		return "Pan " .. digits
	end
	return panId
end

local function bind(instance: Instance, id: string, label: string, objectLabel: string, onTrigger: (Player, Instance) -> ())
	Interaction.register(instance, {
		id = id,
		label = label,
		objectLabel = objectLabel,
		holdDuration = PROMPT_HOLD,
		range = PROMPT_RANGE,
		onTrigger = onTrigger,
	})
end

-- The closure reads the upvalue when the prompt fires, not when it is created.
local function triggerPan(player: Player, instance: Instance, which: string)
	local handler = if which == "claim" then claimHandler else collectHandler
	if handler == nil then
		return
	end
	local panId = instance:GetAttribute("PanId")
	if type(panId) ~= "string" and instance.Parent then
		panId = instance.Parent:GetAttribute("PanId")
	end
	if type(panId) ~= "string" then
		return
	end
	handler(player, panId)
end

-- =================================== tide ===================================

local function phaseSeconds(name: string): number
	local tide = Config.tide
	local seconds = tide.flood
	if name == "settle" then
		seconds = tide.settle
	elseif name == "harvest" then
		seconds = tide.harvest
	elseif name == "spoil" then
		seconds = tide.spoil
	end
	if seconds ~= seconds or seconds <= 0 then
		return 0.05
	end
	return seconds
end

-- Elapsed time from the clock start. The first flood is tide 1; the index
-- steps when a later flood begins, which is one full cycle later.
local function sample(now: number): (string, number, number)
	local elapsed = math.max(0, now - clockStart)
	local cycle = phaseSeconds("flood")
		+ phaseSeconds("settle")
		+ phaseSeconds("harvest")
		+ phaseSeconds("spoil")
	local tide = 1
	local into = elapsed
	if cycle > 0 then
		tide = math.floor(elapsed / cycle) + 1
		into = elapsed % cycle
	end
	local cursor = into
	for index, name in PHASE_ORDER do
		local span = phaseSeconds(name)
		if cursor < span or index == #PHASE_ORDER then
			return name, math.max(0, span - cursor), tide
		end
		cursor -= span
	end
	return "flood", 0, tide
end

local function emitPhase(phase: string, index: number)
	local snapshot = table.clone(phaseListeners)
	for _, fn in snapshot do
		local ok, err = pcall(fn, phase, index)
		if not ok then
			Debug.warn("tide listener failed", tostring(err))
		end
	end
end

local function catchUp(now: number): boolean
	local phase, _left, index = sample(now)
	if phase == reportedPhase and index == reportedIndex then
		return false
	end
	for _ = 1, 24 do
		local pos = table.find(PHASE_ORDER, reportedPhase) or 1
		pos = (pos % #PHASE_ORDER) + 1
		reportedPhase = PHASE_ORDER[pos]
		if reportedPhase == "flood" then
			reportedIndex += 1
		end
		emitPhase(reportedPhase, reportedIndex)
		if reportedPhase == phase and reportedIndex == index then
			return true
		end
	end
	reportedPhase = phase
	reportedIndex = index
	emitPhase(reportedPhase, reportedIndex)
	return true
end

local function remainingAt(now: number): number
	if not clockStarted then
		return phaseSeconds("flood")
	end
	local phase, left, index = sample(now)
	if phase == reportedPhase and index == reportedIndex then
		return left
	end
	return phaseSeconds(reportedPhase)
end

local function broadcast(now: number)
	broadcastAt = now
	local payload = {
		phase = reportedPhase,
		remaining = remainingAt(now),
		tideIndex = reportedIndex,
	}
	local ok, err = pcall(function()
		Net.fireAll("Tide", payload)
	end)
	if not ok then
		Debug.warn("Tide broadcast failed", tostring(err))
	end
end

function Marsh.phase(): string
	if not clockStarted then
		return "flood"
	end
	return reportedPhase
end

function Marsh.remaining(): number
	return remainingAt(os.clock())
end

function Marsh.tideIndex(): number
	if not clockStarted then
		return 1
	end
	return reportedIndex
end

function Marsh.onPhase(fn: PhaseListener)
	table.insert(phaseListeners, fn)
end

function Marsh.onCollect(fn: PanListener)
	collectHandler = fn
end

function Marsh.onClaim(fn: PanListener)
	claimHandler = fn
end

function Marsh.onSell(fn: PlayerListener)
	sellHandler = fn
end

function Marsh.onPrestige(fn: PlayerListener)
	prestigeHandler = fn
end

-- =================================== quay ===================================

local function buildDeck(parent: Instance)
	local quay = Config.world.quay
	local timber = color3(Config.colors.timber)
	local tar = color3(Config.colors.tar)
	makePart(
		parent,
		"Deck",
		Vector3.new(quay.length, 2, quay.width),
		CFrame.new(quay.x, quay.y, quay.z),
		timber,
		Enum.Material.Wood,
		true
	)
	local wearing = makePart(
		parent,
		"Tar",
		Vector3.new(quay.length - 1.6, 0.22, quay.width - 1.6),
		CFrame.new(quay.x, quay.y + 1.11, quay.z),
		tar,
		Enum.Material.Slate,
		true
	)
	wearing.Reflectance = 0.05

	local northZ = quay.z - quay.width / 2 + 0.45
	makePart(
		parent,
		"Gunwale",
		Vector3.new(quay.length, 2.3, 0.7),
		CFrame.new(quay.x, surfaceY() + 1.15, northZ),
		timber,
		Enum.Material.Wood,
		true
	)

	local span = quay.length - 32
	for i = 1, 5 do
		local x = quay.x - quay.length / 2 + 16 + (i - 1) * (span / 4)
		local seam = makePart(
			parent,
			"Plank",
			Vector3.new(0.16, 0.05, quay.width - 3.4),
			CFrame.new(x, surfaceY() + 0.04, quay.z),
			timber,
			Enum.Material.Wood,
			false
		)
		seam.CanQuery = false
		seam.CanTouch = false
		seam.CastShadow = false
	end
end

local function buildDeckPilings(parent: Instance)
	local quay = Config.world.quay
	local top = quay.y - 1
	local zs = { quay.z - quay.width / 2 + 1.3, quay.z + quay.width / 2 - 1.3 }
	local xs = { -70, -35, 0, 35, 70 }
	for _, x in xs do
		for _, z in zs do
			dropPiling(parent, x, z, top)
		end
	end
end

local function buildCauseway(parent: Instance)
	local centerX, centerZ, length, width = causewaySpan()
	local thickness = 0.7
	local top = pathTop()
	local board = makePart(
		parent,
		"Causeway",
		Vector3.new(length, thickness, width),
		CFrame.new(centerX, top - thickness / 2, centerZ),
		color3(Config.colors.timber),
		Enum.Material.Wood,
		true
	)
	local underside = top - thickness
	local west = centerX - length / 2
	local x = west + 10
	while x < centerX + length / 2 - 8 do
		dropPiling(parent, x, centerZ, underside + 0.15)
		x += 46
	end
	return board
end

local function buildTidewater(parent: Instance)
	local water = makePart(
		parent,
		"Tidewater",
		Vector3.new(580, 0.8, 210),
		CFrame.new(-15, -1.3, 10),
		color3(Config.colors.brine),
		Enum.Material.Glass,
		false
	)
	water.Transparency = 0.38
	water.Reflectance = 0.06
	water.CanQuery = false
	water.CanTouch = false
	water.CastShadow = false
end

local function buildLanterns(parent: Instance)
	local quay = Config.world.quay
	local z = quay.z + quay.width / 2 - 3.6
	local timber = color3(Config.colors.timber)
	local copper = color3(Config.colors.copper)
	for index, x in LANTERN_X do
		local postHeight = 4.6
		makePart(
			parent,
			"Lantern" .. tostring(index),
			Vector3.new(0.4, postHeight, 0.4),
			CFrame.new(x, surfaceY() + postHeight / 2, z),
			timber,
			Enum.Material.Wood,
			true
		)
		local cap = makePart(
			parent,
			"LanternCap" .. tostring(index),
			Vector3.new(1, 0.7, 1),
			CFrame.new(x, surfaceY() + postHeight + 0.35, z),
			copper,
			Enum.Material.Metal,
			false
		)
		local light = Instance.new("PointLight")
		light.Name = "CopperLight"
		light.Color = copper
		light.Brightness = 0.75
		light.Range = 16
		light.Shadows = false
		light.Parent = cap
	end
end

local function buildStall(parent: Instance)
	local stone = color3(Config.colors.stone)
	local timber = color3(Config.colors.timber)
	local tar = color3(Config.colors.tar)
	local copper = color3(Config.colors.copper)
	local stallX = 0
	local stallZ = Config.world.quay.z - 3.2

	local stall = Instance.new("Model")
	stall.Name = "Stall"

	local counter = makePart(
		stall,
		"Counter",
		Vector3.new(14, 3.5, 5.4),
		CFrame.new(stallX, surfaceY() + 1.75, stallZ),
		stone,
		Enum.Material.Limestone,
		true
	)
	stall.PrimaryPart = counter

	makePart(
		stall,
		"Back",
		Vector3.new(14, 2.4, 0.6),
		CFrame.new(stallX, surfaceY() + 3.4, stallZ - 2.4),
		stone,
		Enum.Material.Limestone,
		true
	)

	local roofY = surfaceY() + 4.55
	for _, side in { -1, 1 } do
		for _, depth in { -1, 1 } do
			makePart(
				stall,
				"Post",
				Vector3.new(0.45, 4.7, 0.45),
				CFrame.new(stallX + side * 6.4, surfaceY() + 2.35, stallZ + depth * 2.2),
				timber,
				Enum.Material.Wood,
				true
			)
		end
	end
	makePart(
		stall,
		"Roof",
		Vector3.new(16, 0.4, 7.2),
		CFrame.new(stallX, roofY, stallZ),
		tar,
		Enum.Material.Slate,
		true
	)

	local till = makePart(
		stall,
		"Till",
		Vector3.new(2.6, 1.15, 0.4),
		CFrame.new(stallX, surfaceY() + 2.55, stallZ + 2.85),
		copper,
		Enum.Material.Metal,
		false
	)
	stall.Parent = parent

	local sellSign = Instance.new("BillboardGui")
	sellSign.Name = "SellSign"
	sellSign.Size = UDim2.fromOffset(140, 36)
	sellSign.StudsOffset = Vector3.new(0, 5, 0)
	sellSign.MaxDistance = 80
	sellSign.Parent = counter
	local sellText = Instance.new("TextLabel")
	sellText.BackgroundTransparency = 1
	sellText.Size = UDim2.fromScale(1, 1)
	sellText.Font = Enum.Font.GothamBold
	sellText.TextSize = 22
	sellText.TextColor3 = color3(Config.colors.salt)
	sellText.Text = "SELL"
	sellText.Parent = sellSign

	bind(till, "quay_sell", "Sell salt", "Stall", function(player: Player, _instance: Instance)
		local handler = sellHandler
		if handler then
			handler(player)
		end
	end)
end

local function buildLighthouse(parent: Instance)
	local quay = Config.world.quay
	local stone = color3(Config.colors.stone)
	local tar = color3(Config.colors.tar)
	local timber = color3(Config.colors.timber)
	local salt = color3(Config.colors.salt)
	local towerX = quay.x + quay.length / 2 - 14
	local towerZ = quay.z - 2

	local tower = Instance.new("Model")
	tower.Name = "Lighthouse"

	local plinth = makePart(
		tower,
		"Plinth",
		Vector3.new(12, 1.15, 12),
		CFrame.new(towerX, surfaceY() + 0.575, towerZ),
		stone,
		Enum.Material.Limestone,
		true
	)
	tower.PrimaryPart = plinth

	local faceZ = towerZ + 6
	makePart(
		tower,
		"StepHigh",
		Vector3.new(5.5, 0.78, 2.1),
		CFrame.new(towerX, surfaceY() + 0.39, faceZ + 1.05),
		stone,
		Enum.Material.Limestone,
		true
	)
	makePart(
		tower,
		"StepLow",
		Vector3.new(5.5, 0.38, 2.1),
		CFrame.new(towerX, surfaceY() + 0.19, faceZ + 3.15),
		stone,
		Enum.Material.Limestone,
		true
	)

	local shaftHeight = 22
	local shaftBottom = surfaceY() + 1.15
	makePart(
		tower,
		"Shaft",
		Vector3.new(6.4, shaftHeight, 6.4),
		CFrame.new(towerX, shaftBottom + shaftHeight / 2, towerZ),
		stone,
		Enum.Material.Limestone,
		true
	)

	local galleryY = shaftBottom + shaftHeight
	makePart(
		tower,
		"Gallery",
		Vector3.new(9.2, 0.4, 9.2),
		CFrame.new(towerX, galleryY, towerZ),
		stone,
		Enum.Material.Limestone,
		false
	)
	local lamp = makePart(
		tower,
		"Lamp",
		Vector3.new(3.8, 3.2, 3.8),
		CFrame.new(towerX, galleryY + 1.8, towerZ),
		salt,
		Enum.Material.Neon,
		false
	)
	lamp.CanQuery = false
	makePart(
		tower,
		"Cap",
		Vector3.new(5.2, 0.8, 5.2),
		CFrame.new(towerX, galleryY + 3.7, towerZ),
		tar,
		Enum.Material.Slate,
		false
	)

	local door = makePart(
		tower,
		"SpringTide",
		Vector3.new(2.4, 3.3, 0.35),
		CFrame.new(towerX, surfaceY() + 1.15 + 1.7, towerZ + 3.35),
		timber,
		Enum.Material.Wood,
		false
	)
	tower.Parent = parent

	bind(door, "lighthouse_spring", "Spring tide", "Lighthouse", function(player: Player, _instance: Instance)
		local handler = prestigeHandler
		if handler then
			handler(player)
		end
	end)
end

local function buildQuay()
	local quayFolder = folder("Quay")
	if quayFolder:FindFirstChild("Deck") then
		return
	end
	buildTidewater(quayFolder)
	buildDeck(quayFolder)
	buildDeckPilings(quayFolder)
	buildCauseway(quayFolder)
	buildStall(quayFolder)
	buildLighthouse(quayFolder)
	buildLanterns(quayFolder)
end

-- =================================== plots ==================================

local function ensureSlot(index: number): Model
	local plots = folder("Plots")
	local name = string.format("Slot%d", index)
	local existing = plots:FindFirstChild(name)
	local model: Model
	if existing and existing:IsA("Model") then
		model = existing
	else
		model = Instance.new("Model")
		model.Name = name
		model.Parent = plots
	end
	model:SetAttribute("Slot", index)
	if model:FindFirstChild("Pad") then
		return model
	end

	local halfX, halfZ = padHalf()
	local top = surfaceY()
	local pad = makePart(
		model,
		"Pad",
		Vector3.new(halfX * 2, 2, halfZ * 2),
		CFrame.new(slotX(index), top - 1, Config.world.plotZ),
		color3(Config.colors.marsh),
		Enum.Material.Mud,
		true
	)
	model.PrimaryPart = pad
	return model
end

local function clearDressing(model: Model)
	for _, child in model:GetChildren() do
		if child.Name ~= "Pad" then
			child:Destroy()
		end
	end
end

local function releaseBuild(slotIndex: number)
	local owner = builtFor[slotIndex]
	builtFor[slotIndex] = nil
	local plots = folder("Plots")
	local model = plots:FindFirstChild(string.format("Slot%d", slotIndex))
	if owner then
		panViews[owner] = nil
		local watch = spawnWatch[owner]
		if watch then
			watch:Disconnect()
			spawnWatch[owner] = nil
		end
		local respawn = owner.RespawnLocation
		if respawn and model and respawn.Parent == model then
			owner.RespawnLocation = nil
		end
	end
	if model and model:IsA("Model") then
		clearDressing(model)
	end
end

local function placeCharacter(player: Player, spawn: SpawnLocation, pivotExisting: boolean)
	local function place(character: Model)
		if spawn.Parent == nil then
			return
		end
		local top = spawn.Position.Y + spawn.Size.Y / 2
		local y = math.max(Config.world.spawnY, top + 3)
		local pos = Vector3.new(spawn.Position.X, y, spawn.Position.Z)
		-- Face the pans and the quay. +Z is empty marsh; that was the first thing
		-- a player saw, and it read as a mistake.
		character:PivotTo(CFrame.lookAt(pos, pos + Vector3.new(10, -1, -16)))
	end

	player.RespawnLocation = spawn
	if pivotExisting then
		local existing = player.Character
		if existing then
			place(existing)
		end
	end

	local previous = spawnWatch[player]
	if previous then
		previous:Disconnect()
	end
	spawnWatch[player] = player.CharacterAdded:Connect(function(character)
		task.defer(function()
			if player.Parent == nil or spawn.Parent == nil or character.Parent == nil then
				return
			end
			if player.RespawnLocation ~= spawn then
				return
			end
			place(character)
		end)
	end)
end

local function addNameplate(parent: Instance, player: Player, position: Vector3)
	local timber = color3(Config.colors.timber)
	local tar = color3(Config.colors.tar)
	local post = makePart(
		parent,
		"NamePost",
		Vector3.new(0.45, 5.2, 0.45),
		CFrame.new(position),
		timber,
		Enum.Material.Wood,
		false
	)
	local board = makePart(
		parent,
		"NameBoard",
		Vector3.new(3.4, 0.9, 0.18),
		CFrame.new(position + Vector3.new(0, 2.45, 0)),
		tar,
		Enum.Material.Wood,
		false
	)

	local gui = Instance.new("BillboardGui")
	gui.Name = "Nameplate"
	gui.MaxDistance = NAMEPLATE_DISTANCE
	gui.Size = UDim2.fromOffset(180, 40)
	gui.StudsOffset = Vector3.new(0, 0.2, 0)
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0.25
	gui.Adornee = board
	gui.Parent = board

	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.BackgroundColor3 = tar
	label.BackgroundTransparency = 0.15
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamMedium
	label.Text = player.Name
	label.TextColor3 = color3(Config.colors.salt)
	label.TextScaled = true
	label.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = label

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = label

	return post
end

local function buildPan(plot: Model, slotIndex: number, panId: string, row: number, col: number, views: { [string]: PanView })
	local world = Config.world
	local panSize = world.panSize
	local x = slotX(slotIndex) + (col - 1) * world.panSpacing
	local z = world.plotZ + (row - 0.5) * world.panSpacing
	local top = surfaceY()
	local tar = color3(Config.colors.tar)
	local timber = color3(Config.colors.timber)
	local brineColor = color3(Config.colors.brine)
	local salt = color3(Config.colors.salt)
	local copper = color3(Config.colors.copper)

	local pan = Instance.new("Model")
	pan.Name = panId
	pan:SetAttribute("PanId", panId)

	local basin = makePart(
		pan,
		"Basin",
		Vector3.new(panSize.x, panSize.y, panSize.z),
		CFrame.new(x, top + panSize.y / 2, z),
		tar,
		Enum.Material.Wood,
		true
	)
	basin:SetAttribute("PanId", panId)
	pan.PrimaryPart = basin

	local bed = CFrame.new(x, top + panSize.y, z)
	local spanX = panSize.x - 1.6
	local spanZ = panSize.z - 1.6
	local fullHeight = panSize.y * 0.5

	local brine = makePart(
		pan,
		"Brine",
		Vector3.new(spanX, 0.05, spanZ),
		bed * CFrame.new(0, 0.025, 0),
		brineColor,
		Enum.Material.Glass,
		false
	)
	brine.Transparency = 1
	brine.CanQuery = false
	brine.CanTouch = false
	brine.CastShadow = false
	brine.Reflectance = 0.12

	local crust = makePart(
		pan,
		"Crust",
		Vector3.new(spanX - 0.8, 0.12, spanZ - 0.8),
		bed * CFrame.new(0, 0.06, 0),
		salt,
		Enum.Material.Salt,
		false
	)
	crust.Transparency = 1
	crust.CanQuery = false
	crust.CanTouch = false
	crust.CastShadow = false

	local sign = Instance.new("BillboardGui")
	sign.Name = "RakeSign"
	sign.Size = UDim2.fromOffset(120, 36)
	sign.StudsOffset = Vector3.new(0, 4, 0)
	sign.MaxDistance = 50
	sign.AlwaysOnTop = true
	sign.Enabled = false
	sign.Parent = pan
	local signText = Instance.new("TextLabel")
	signText.BackgroundTransparency = 1
	signText.Size = UDim2.fromScale(1, 1)
	signText.Font = Enum.Font.GothamBold
	signText.TextSize = 22
	signText.TextColor3 = salt
	signText.Text = "RAKE"
	signText.Parent = sign

	local rimH = 0.7
	local rimT = 0.4
	local rimY = top + panSize.y + rimH / 2
	makePart(pan, "RimNorth", Vector3.new(panSize.x, rimH, rimT), CFrame.new(x, rimY, z - panSize.z / 2 + rimT / 2), timber, Enum.Material.Wood, true)
	makePart(pan, "RimSouth", Vector3.new(panSize.x, rimH, rimT), CFrame.new(x, rimY, z + panSize.z / 2 - rimT / 2), timber, Enum.Material.Wood, true)
	makePart(pan, "RimWest", Vector3.new(rimT, rimH, panSize.z - rimT * 2), CFrame.new(x - panSize.x / 2 + rimT / 2, rimY, z), timber, Enum.Material.Wood, true)
	makePart(pan, "RimEast", Vector3.new(rimT, rimH, panSize.z - rimT * 2), CFrame.new(x + panSize.x / 2 - rimT / 2, rimY, z), timber, Enum.Material.Wood, true)

	local postHeight = 3.15
	local postX = x - panSize.x / 2 - 1.05
	local postZ = z - panSize.z / 2 + 1.3
	local post = makePart(
		pan,
		"ClaimPost",
		Vector3.new(0.55, postHeight, 0.55),
		CFrame.new(postX, top + postHeight / 2, postZ),
		timber,
		Enum.Material.Wood,
		false
	)
	post:SetAttribute("PanId", panId)
	makePart(
		pan,
		"ClaimCap",
		Vector3.new(0.85, 0.28, 0.85),
		CFrame.new(postX, top + postHeight + 0.14, postZ),
		copper,
		Enum.Material.Metal,
		false
	)

	pan:SetAttribute("PanId", panId)
	pan.Parent = plot

	bind(pan, string.format("slot%d_%s_rake", slotIndex, panId), "Rake", panTitle(panId), function(player: Player, instance: Instance)
		triggerPan(player, instance, "collect")
	end)
	bind(post, string.format("slot%d_%s_claim", slotIndex, panId), "Claim", panTitle(panId), function(player: Player, instance: Instance)
		triggerPan(player, instance, "claim")
	end)

	views[panId] = {
		brine = brine,
		crust = crust,
		bed = bed,
		fullHeight = fullHeight,
		spanX = spanX,
		spanZ = spanZ,
	}
end

local function buildPlot(player: Player, slotIndex: number, plot: Model)
	local views: { [string]: PanView } = {}
	panViews[player] = views

	local _, halfZ = padHalf()
	local padNorth = Config.world.plotZ - halfZ
	local _centerX, centerZ, _length, width = causewaySpan()
	local causeSouth = centerZ + width / 2
	local zNorth = causeSouth - 1.2
	local zSouth = padNorth + 1.5
	local length = zSouth - zNorth
	local centerZWalk = (zNorth + zSouth) / 2
	local x = walkX(slotIndex)
	local thickness = 0.64
	local top = pathTop() - 0.03

	makePart(
		plot,
		"Walkway",
		Vector3.new(5, thickness, length),
		CFrame.new(x, top - thickness / 2, centerZWalk),
		color3(Config.colors.timber),
		Enum.Material.Wood,
		true
	)
	local underside = top - thickness
	for step = 1, 3 do
		local z = zNorth + (zSouth - zNorth) * (step / 4)
		dropPiling(plot, x, z, underside + 0.1)
	end

	local spawnTop = top + 0.04
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = Vector3.new(6, 0.36, 6)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Enabled = true
	spawn.AllowTeamChangeOnTouch = false
	spawn.Material = Enum.Material.Wood
	spawn.Color = color3(Config.colors.timber)
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	local spawnPos = Vector3.new(x, spawnTop - spawn.Size.Y / 2, padNorth - 5)
	spawn.CFrame = CFrame.lookAt(spawnPos, spawnPos + Vector3.new(10, 0, -16))
	spawn.Parent = plot

	addNameplate(plot, player, Vector3.new(x + 3.6, surfaceY() + 2.6, padNorth - 5))

	for _, spec in Config.pans do
		buildPan(plot, slotIndex, spec.id, spec.row, spec.col, views)
	end

	plot:SetAttribute("OwnerUserId", player.UserId)
	placeCharacter(player, spawn, true)
end

local function onPlayerRemoving(player: Player)
	local slot = slotOf[player]
	slotOf[player] = nil
	if slot ~= nil and ownerOf[slot] == player then
		ownerOf[slot] = nil
	end
	if slot ~= nil and builtFor[slot] == player then
		releaseBuild(slot)
	else
		panViews[player] = nil
		local watch = spawnWatch[player]
		if watch then
			watch:Disconnect()
			spawnWatch[player] = nil
		end
	end
end

function Marsh.release(player: Player)
	onPlayerRemoving(player)
end

function Marsh.assignSlot(player: Player, preferred: number?): number
	if type(preferred) == "number" and preferred == math.floor(preferred) and preferred >= 1 and preferred <= Config.maxPlayers then
		local owner = ownerOf[preferred]
		if owner == nil or owner == player or owner.Parent == nil then
			if owner ~= nil and owner ~= player then
				slotOf[owner] = nil
				ownerOf[preferred] = nil
				if builtFor[preferred] == owner then
					releaseBuild(preferred)
				end
			end
			ownerOf[preferred] = player
			slotOf[player] = preferred
			return preferred
		end
	end
	local held = slotOf[player]
	if held ~= nil and ownerOf[held] == player and player.Parent ~= nil then
		return held
	end

	for index = 1, Config.maxPlayers do
		local owner = ownerOf[index]
		if owner ~= nil and owner ~= player and owner.Parent == nil then
			slotOf[owner] = nil
			ownerOf[index] = nil
			if builtFor[index] == owner then
				releaseBuild(index)
			end
			owner = nil
		end
		if owner == nil or owner == player then
			ownerOf[index] = player
			slotOf[player] = index
			return index
		end
	end
	return 0
end

function Marsh.adopt(player: Player, slot: number)
	if slot < 1 or slot > Config.maxPlayers or slot ~= math.floor(slot) then
		return
	end

	local previous = slotOf[player]
	if previous ~= nil and previous ~= slot then
		if ownerOf[previous] == player then
			ownerOf[previous] = nil
		end
		if builtFor[previous] == player then
			releaseBuild(previous)
		end
	end

	local displaced = ownerOf[slot]
	if displaced ~= nil and displaced ~= player then
		slotOf[displaced] = nil
	end
	ownerOf[slot] = player
	slotOf[player] = slot

	local plot = ensureSlot(slot)
	if builtFor[slot] == player then
		local spawn = plot:FindFirstChild("Spawn")
		if spawn and spawn:IsA("SpawnLocation") then
			-- The plot is already there. Refresh the spawn binding without
			-- pulling a player who is already out on the pans back to the post.
			placeCharacter(player, spawn, false)
		end
		return
	end

	if builtFor[slot] ~= nil then
		releaseBuild(slot)
		ownerOf[slot] = player
		slotOf[player] = slot
	end
	clearDressing(plot)
	buildPlot(player, slot, plot)
	builtFor[slot] = player
end

function Marsh.setPanVisual(player: Player, panId: string, brine: number, capacity: number, ready: boolean)
	local views = panViews[player]
	if views == nil then
		return
	end
	local view = views[panId]
	if view == nil or view.brine.Parent == nil then
		return
	end

	local fraction = 0
	if capacity > 0 and brine == brine then
		fraction = math.clamp(brine / capacity, 0, 1)
	end

	local height = if fraction <= 0.01 then 0.04 else math.max(0.04, view.fullHeight * fraction)
	view.brine.Anchored = true
	view.crust.Anchored = true
	view.brine.CanCollide = false
	view.crust.CanCollide = false
	view.brine.Size = Vector3.new(view.spanX, height, view.spanZ)
	view.brine.CFrame = view.bed * CFrame.new(0, height / 2, 0)

	local wet = color3(Config.colors.brine)
	local foam = color3(Config.colors.foam)
	view.brine.Color = wet:Lerp(foam, fraction * 0.45)
	view.brine.Transparency = if fraction <= 0.01 then 1 else 0.28 - fraction * 0.12

	local crustLift = if ready then height + view.crust.Size.Y / 2 else view.crust.Size.Y / 2
	view.crust.CFrame = view.bed * CFrame.new(0, crustLift, 0)
	view.crust.Transparency = if ready then 0.05 else 1
	local sign = view.brine.Parent and view.brine.Parent:FindFirstChild("RakeSign")
	if sign and sign:IsA("BillboardGui") then
		sign.Enabled = ready
	end
end

-- =================================== start ==================================

local function startClock()
	clockStarted = true
	clockStart = os.clock()
	reportedPhase = "flood"
	reportedIndex = 1
	broadcastAt = clockStart
	broadcast(clockStart)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local changed = catchUp(now)
		if changed or now - broadcastAt >= 1 then
			broadcast(now)
		end
	end)
end

local function fillTerrain(cf: CFrame, size: Vector3, material: Enum.Material)
	Workspace.Terrain:FillBlock(cf, size, material)
end

-- Terrain water is what makes a coast read as a coast. A glass slab does not.
local function buildCoast()
	local props = folder("Props")
	if props:FindFirstChild("CoastMark") then
		return
	end
	local mark = Instance.new("BoolValue")
	mark.Name = "CoastMark"
	mark.Parent = props

	local terrain = Workspace.Terrain
	terrain.WaterColor = color3(Config.colors.brine)
	terrain.WaterTransparency = 0.25
	terrain.WaterReflectance = 0.35
	terrain.WaterWaveSize = 0.18
	terrain.WaterWaveSpeed = 10

	fillTerrain(CFrame.new(0, -8, 20), Vector3.new(980, 16, 560), Enum.Material.Water)
	fillTerrain(CFrame.new(0, -1.2, 55), Vector3.new(760, 4, 90), Enum.Material.Sand)
	fillTerrain(CFrame.new(0, -0.4, 150), Vector3.new(900, 8, 70), Enum.Material.Grass)
	fillTerrain(CFrame.new(0, -0.2, -130), Vector3.new(900, 8, 80), Enum.Material.Grass)

	local clouds = terrain:FindFirstChildOfClass("Clouds")
	if not clouds then
		clouds = Instance.new("Clouds")
		clouds.Cover = 0.42
		clouds.Density = 0.28
		clouds.Color = Color3.fromRGB(236, 226, 210)
		clouds.Parent = terrain
	end

	local rng = Random.new(Config.seed)
	local marsh = color3(Config.colors.marsh)
	for index = 1, 36 do
		local height = rng:NextNumber(2.4, 5.2)
		local reed = makePart(
			props,
			"Reed" .. tostring(index),
			Vector3.new(0.18, height, 0.18),
			CFrame.new(rng:NextNumber(-90, 110), height / 2 - 0.2, rng:NextNumber(-8, 28))
				* CFrame.Angles(0, rng:NextNumber(0, 6), math.rad(rng:NextNumber(-12, 12))),
			marsh:Lerp(Color3.fromRGB(120, 150, 70), 0.45),
			Enum.Material.Grass,
			false
		)
		reed.CanQuery = false
		reed.CanTouch = false
		reed.CastShadow = false
	end
end

function Marsh.start()
	if started then
		return
	end
	started = true

	buildCoast()
	buildQuay()
	for index = 1, Config.maxPlayers do
		ensureSlot(index)
	end

	startClock()
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	Debug.probe("tide", function()
		return {
			phase = Marsh.phase(),
			remaining = Marsh.remaining(),
			tideIndex = Marsh.tideIndex(),
		}
	end)
end

return Marsh
