--!strict
-- Geometry and presentation only. Garden owns prompts, ownership and rewards.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local WorldKit = ReplicatedStorage:WaitForChild("WorldKit")
local Build = require(WorldKit.Build)
local Palette = require(WorldKit.Palette)
local Sky = require(WorldKit.Sky)

local World = {}
local V = Vector3.new
local theme = {
	name = "CrystalGarden",
	skyColor = Color3.fromRGB(181, 220, 242),
	fogColor = Color3.fromRGB(216, 233, 240),
	swatches = {
		ground = { color = Color3.fromRGB(160, 212, 187), material = Enum.Material.SmoothPlastic },
		leaf = { color = Color3.fromRGB(103, 178, 151), material = Enum.Material.SmoothPlastic },
		leafLight = { color = Color3.fromRGB(183, 231, 196), material = Enum.Material.SmoothPlastic },
		path = { color = Color3.fromRGB(244, 238, 221), material = Enum.Material.SmoothPlastic },
		trim = { color = Color3.fromRGB(203, 184, 229), material = Enum.Material.SmoothPlastic },
		lavender = { color = Color3.fromRGB(166, 141, 204), material = Enum.Material.SmoothPlastic },
		soil = { color = Color3.fromRGB(93, 101, 112), material = Enum.Material.Slate },
		ink = { color = Color3.fromRGB(57, 68, 83), material = Enum.Material.SmoothPlastic },
		gold = { color = Color3.fromRGB(237, 200, 132), material = Enum.Material.SmoothPlastic },
		crystal = { color = Color3.fromRGB(159, 229, 221), material = Enum.Material.SmoothPlastic },
		white = Palette.BrickFarm.swatches.white,
	},
}
local swatches = theme.swatches
local decor = { canCollide = false, castShadow = false }
local ROW_Z = { 48, 96 }
local COLUMN_X = { 0, -44, 44 }
local BED_SPACING = 9
local ROOT_NAME = "CrystalGardenWorld"
local GROW_TWEEN = TweenInfo.new(0.65, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

export type Plot = {
	id: number,
	origin: Vector3,
	spawn: CFrame,
	beds: { BasePart },
	sign: TextLabel,
}
export type BuiltWorld = {
	plots: { Plot }, market: BasePart, spawn: SpawnLocation, root: Folder,
}
type Piece = { part: BasePart, size: Vector3, frame: CFrame }
type Growth = {
	model: Model,
	pieces: { Piece },
	tweens: { Tween },
	speciesId: string,
	plantedAt: number,
	readyAt: number,
	mutationId: string,
	stage: number,
}
type BedView = { prompt: ProximityPrompt, label: BillboardGui, text: TextLabel, growth: Growth? }

local views: { [BasePart]: BedView } = {}
local activeRoot: Folder? = nil
local weatherText: TextLabel? = nil
local landmarkTip: BasePart? = nil

local function folder(parent: Instance, name: string): Folder
	local result = Instance.new("Folder")
	result.Name = name
	result.Parent = parent
	return result
end

local function box(parent: Instance, name: string, size: Vector3, position: Vector3, swatch: any, decorative: boolean?): Part
	local part = Build.part(parent, name, size, position, swatch, if decorative then decor else nil)
	part.CanTouch = false
	if decorative then part.CanQuery = false end
	return part
end

local function caption(anchor: BasePart, text: string, distance: number, height: number?): (BillboardGui, TextLabel)
	local gui = Build.billboard(anchor, text, swatches.ink.color, 230, height or 58, 2, 19, distance)
	local label = gui:FindFirstChildOfClass("TextLabel") :: TextLabel
	label.TextStrokeTransparency = 1
	label.TextWrapped = true
	return gui, label
end

-- Two opposed wedges give a pointed ridge and shaded facets without mesh assets.
-- All offsets are authored relative to the soil, so scaling never lifts the roots.
local function shard(parent: Instance, name: string, frame: CFrame, width: number, height: number, color: Color3): { Piece }
	local tipHeight = height * 0.25
	local bodyHeight = height - tipHeight
	local bodySwatch = { color = color, material = Enum.Material.SmoothPlastic }
	local bodyFrame = CFrame.new(0, bodyHeight / 2, 0)
	local body = box(parent, name .. "Stem", V(width, bodyHeight, width), V(0, 0, 0), bodySwatch, true)
	body.CastShadow = true
	body.CFrame = frame * bodyFrame
	local pieces = { { part = body, size = body.Size, frame = frame * bodyFrame } }
	for _, side in ipairs({ -1, 1 }) do
		local localFrame = CFrame.new(0, bodyHeight + tipHeight / 2, side * width / 4)
			* CFrame.Angles(0, if side == 1 then math.pi else 0, 0)
		local faceColor = color:Lerp(swatches.white.color, if side == 1 then 0.3 else 0.12)
		local tip = Build.wedge(parent, name .. "Facet" .. tostring(side), V(width, tipHeight, width / 2), frame * localFrame,
			{ color = faceColor, material = Enum.Material.SmoothPlastic }, decor)
		tip.CanTouch = false
		tip.CanQuery = false
		table.insert(pieces, { part = tip, size = tip.Size, frame = frame * localFrame })
	end
	return pieces
end

local function plantDecoration(parent: Instance, position: Vector3, index: number)
	local pot = Build.cylinder(parent, "Planter" .. index, V(6, 1.1, 6), position + V(0, 0.55, 0), swatches.trim, decor)
	pot.CanTouch = false
	pot.CanQuery = false
	for branch = 1, 3 do
		local angle = branch * math.pi * 2 / 3 + index * 0.7
		local leaf = box(parent, "Leaf" .. branch, V(1.6, 4.4, 0.7), position + V(math.cos(angle), 2.6, math.sin(angle)),
			if branch == 1 then swatches.leafLight else swatches.leaf, true)
		leaf.CFrame = CFrame.new(leaf.Position) * CFrame.Angles(0, -angle, math.rad(25))
	end
	shard(parent, "Flower", CFrame.new(position + V(0, 3.1, 0)) * CFrame.Angles(0, math.rad(45), 0),
		1.6, 2.5, if index % 2 == 0 then swatches.lavender.color else swatches.crystal.color)
end

local function stopGrowth(growth: Growth)
	for _, tween in ipairs(growth.tweens) do tween:Cancel() end
	table.clear(growth.tweens)
end

local function clearViews()
	for _, view in pairs(views) do
		if view.growth then stopGrowth(view.growth) end
	end
	table.clear(views)
	weatherText = nil
	landmarkTip = nil
end

local function buildPlot(parent: Instance, id: number, origin: Vector3, config: any): Plot
	local plotRoot = folder(parent, "Plot" .. id)
	plotRoot:SetAttribute("PlotId", id)
	box(plotRoot, "GardenBorder", V(36, 0.18, 36), origin + V(0, 0.01, 0), swatches.trim, true)
	box(plotRoot, "GardenFloor", V(34.8, 0.2, 34.8), origin, swatches.path)
	-- A low rear rail frames each garden; the front and both sides stay open.
	Build.fence(plotRoot, "RearRail", origin + V(-17, 0.1, 17), origin + V(17, 0.1, 17), 1.8, swatches.white, 9)
	local signPost = box(plotRoot, "NumberPost", V(0.7, 4.3, 0.7), origin + V(-14.5, 2.25, -14.5), swatches.lavender, true)
	box(plotRoot, "NumberBoard", V(5, 2.6, 0.45), signPost.Position + V(0, 1.2, 0), swatches.white, true)
	local _, sign = caption(signPost, string.format("JARDIM %02d\nDisponível", id), 42, 64)
	local beds: { BasePart } = {}
	for slot = 1, 9 do
		local column = (slot - 1) % 3 - 1
		local row = math.floor((slot - 1) / 3) - 1
		local centre = origin + V(column * BED_SPACING, 0, row * BED_SPACING)
		box(plotRoot, "BedRim" .. slot, V(6.6, 0.5, 6.6), centre + V(0, 0.35, 0), swatches.lavender, true)
		local bed = box(plotRoot, "Bed" .. slot, V(5.9, 0.5, 5.9), centre + V(0, 0.36, 0), swatches.soil, true)
		bed.CanQuery = true
		bed:SetAttribute("PlotId", id)
		bed:SetAttribute("Slot", slot)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "GardenPrompt"
		prompt.ActionText = "Plantar"
		prompt.ObjectText = string.format("Canteiro %02d", slot)
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.MaxActivationDistance = math.min(8, config.interactionDistance or 14)
		prompt.RequiresLineOfSight = false
		prompt.HoldDuration = 0.15
		-- Intentionally focus the nearest bed, instead of nine overlapping E prompts.
		prompt.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
		prompt:SetAttribute("PlotId", id)
		prompt:SetAttribute("Slot", slot)
		prompt.Parent = bed
		local gui, text = caption(bed, "Pronto para colher", 12, 30)
		gui.StudsOffsetWorldSpace = V(0, 6.6, 0)
		gui.Enabled = false
		text.TextSize = 16
		views[bed] = { prompt = prompt, label = gui, text = text, growth = nil }
		beds[slot] = bed
	end
	local approach = origin + V(0, 3.3, -20)
	return { id = id, origin = origin, spawn = CFrame.lookAt(approach, origin + V(0, 3.3, 0)), beds = beds, sign = sign }
end

local function buildMarket(parent: Instance): BasePart
	local marketRoot = folder(parent, "Market")
	local origin = V(-19, 0, 7)
	box(marketRoot, "MarketFloor", V(18, 0.12, 14), origin + V(0, 0.13, 0), swatches.trim)
	for _, side in ipairs({ -1, 1 }) do
		for _, back in ipairs({ -1, 1 }) do
			box(marketRoot, "CanopyPost", V(0.6, 8, 0.6), origin + V(side * 7, 4.1, back * 5), swatches.white)
		end
	end
	for stripe = 1, 8 do
		box(marketRoot, "Awning" .. stripe, V(2, 0.5, 13), origin + V(-9 + stripe * 2, 8.2, 0),
			if stripe % 2 == 0 then swatches.white else swatches.lavender, true)
	end
	box(marketRoot, "AwningEdge", V(16, 1.3, 0.35), origin + V(0, 7.65, -6.4), swatches.trim, true)
	local market = box(marketRoot, "MarketCounter", V(12, 2.5, 3), origin + V(0, 1.4, -2.5), swatches.lavender)
	market:SetAttribute("WorldKitRole", "market")
	box(marketRoot, "CounterTop", V(12.6, 0.3, 3.4), market.Position + V(0, 1.4, 0), swatches.path)
	local marketLabel = caption(market, "MERCADO\nVenda seus cristais", 48, 66)
	marketLabel.StudsOffsetWorldSpace = V(0, 4.1, 0)
	for index = 1, 3 do
		shard(marketRoot, "MarketCrystal" .. index, CFrame.new(origin + V((index - 2) * 3, 2.95, -2.5))
			* CFrame.Angles(0, math.rad(45), 0), 1.1, 1.8,
			if index == 2 then swatches.lavender.color else swatches.crystal.color)
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SellPrompt"
	prompt.ActionText = "Vender mochila"
	prompt.ObjectText = "Mercado de cristais"
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.Parent = market
	return market
end

function World.build(config: any): BuiltWorld
	assert(config.plotCount == nil or config.plotCount == 6, "CrystalGarden requires six plots")
	assert(config.bedCount == nil or config.bedCount == 9, "CrystalGarden requires nine beds per plot")
	clearViews()
	if activeRoot then activeRoot:Destroy() end
	-- Re-running the builder never stacks a second generated garden.
	local stale = Workspace:FindFirstChild(ROOT_NAME)
	if stale then stale:Destroy() end
	local root = folder(Workspace, ROOT_NAME)
	activeRoot = root
	root:SetAttribute("Palette", theme.name)
	root.Destroying:Connect(function()
		if activeRoot == root then
			clearViews()
			activeRoot = nil
		end
	end)
	Sky.apply(Sky.BrightDay)
	local ground = folder(root, "Ground")
	box(ground, "GardenFoundation", V(176, 3, 188), V(0, -1.5, 70), swatches.lavender)
	box(ground, "MintLawn", V(174, 0.2, 186), V(0, -0.1, 70), swatches.ground)
	local paths = folder(root, "Paths")
	box(paths, "WelcomePlaza", V(60, 0.14, 30), V(0, 0.05, 2), swatches.path)
	Build.road(paths, "EntrancePath", V(0, 0, 15), V(0, 0, 26), 10, swatches.path, -0.08)
	for _, z in ipairs({ 26, 72, 116 }) do
		Build.road(paths, "CrossPath" .. z, V(-68, 0, z), V(68, 0, z), 8, swatches.path, -0.08)
	end
	for _, x in ipairs({ -66, -22, 22, 66 }) do
		Build.road(paths, "Promenade" .. x, V(x, 0, 26), V(x, 0, 116), 6, swatches.path, -0.08)
	end
	Build.road(paths, "CrystalApproach", V(0, 0, 116), V(0, 0, 132), 12, swatches.path, -0.08)
	for _, x in ipairs({ -6, 6 }) do
		box(paths, "EntranceInlay", V(0.25, 0.06, 11), V(x, 0.15, 20.5), swatches.gold, true)
	end
	local plotFolder = folder(root, "Plots")
	local plots: { Plot } = {}
	for _, z in ipairs(ROW_Z) do
		for _, x in ipairs(COLUMN_X) do
			local id = #plots + 1
			plots[id] = buildPlot(plotFolder, id, V(x, 0, z), config)
		end
	end
	local market = buildMarket(root)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "GardenSpawn"
	spawn.Size = V(8, 0.2, 8)
	spawn.CFrame = CFrame.lookAt(V(0, 0.22, 0), V(0, 0.22, ROW_Z[1]))
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Material = swatches.path.material
	spawn.Color = swatches.path.color
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanTouch = false
	spawn.Parent = root
	local scenery = folder(root, "Scenery")
	local title = box(scenery, "WelcomeSign", V(10, 4, 0.6), V(19, 4.1, 8), swatches.white, true)
	caption(title, "JARDIM DE CRISTAIS\nPlante · Colha · Floresça", 44, 66)
	local weatherAnchor = box(scenery, "WeatherStone", V(5, 1.5, 3), V(19, 0.9, 8), swatches.trim, true)
	local _, weatherLabel = caption(weatherAnchor, "Céu limpo", 28, 28)
	weatherText = weatherLabel
	-- A tall, asymmetric cluster is the navigation landmark, not another plot.
	local landmark = folder(scenery, "HeartCrystal")
	local centre = V(0, 0, 142)
	Build.cylinder(landmark, "CrystalPlaza", V(32, 0.22, 32), centre + V(0, 0.11, 0), swatches.path)
	Build.cylinder(landmark, "LavenderMedallion", V(22, 0.3, 22), centre + V(0, 0.35, 0), swatches.trim)
	Build.cylinder(landmark, "CrystalPedestal", V(14, 1.2, 14), centre + V(0, 0.8, 0), swatches.white)
	local hero = shard(landmark, "Heart", CFrame.new(centre + V(0, 1.4, 0)) * CFrame.Angles(0, math.rad(45), math.rad(-5)),
		5.6, 28, swatches.crystal.color)
	landmarkTip = hero[2].part
	for index = 1, 4 do
		local angle = index * math.pi / 2 + 0.3
		shard(landmark, "Satellite" .. index, CFrame.new(centre + V(math.cos(angle) * 5, 1.4, math.sin(angle) * 5))
			* CFrame.Angles(math.rad(10), angle, math.rad(12)), 2.8, 9 + index * 1.2,
			if index % 2 == 0 then swatches.lavender.color else swatches.crystal.color)
	end
	local heroLight = Build.light(hero[1].part, swatches.crystal.color, 0.4, 22)
	heroLight.Shadows = false
	-- Deterministic botanical accents occupy borders, never the promenade.
	for sideIndex, side in ipairs({ -1, 1 }) do
		for index, z in ipairs({ 20, 48, 78, 108, 140 }) do
			plantDecoration(scenery, V(side * 77, 0, z), index + sideIndex)
		end
	end
	for _, x in ipairs({ -38, 38 }) do
		for _, z in ipairs({ 10, 142 }) do
			plantDecoration(scenery, V(x, 0, z), math.abs(x) + z)
		end
	end
	for _, side in ipairs({ -1, 1 }) do
		Build.fence(scenery, "GardenBoundary", V(side * 85, 0, -20), V(side * 85, 0, 160), 3, swatches.white, 18)
	end
	Build.fence(scenery, "BackBoundary", V(-85, 0, 160), V(85, 0, 160), 3, swatches.white, 18)
	root:SetAttribute("PlotCount", #plots)
	root:SetAttribute("BedCount", #plots * 9)
	-- 54 mature beds add only 594 instances (10 parts + 1 Model each).
	assert(#root:GetDescendants() + 54 * 11 < 2500, "CrystalGarden world instance budget exceeded")
	return { plots = plots, market = market, spawn = spawn, root = root }
end

function World.setOwner(plot: Plot, playerOrNil: Player?)
	-- Plot numbers and authored status avoid adding a user text moderation surface.
	plot.sign.Text = string.format("JARDIM %02d\n%s", plot.id, if playerOrNil then "Ocupado" else "Disponível")
	plot.sign.TextColor3 = if playerOrNil then swatches.ink.color else swatches.leaf.color
end

local function findEntry(entries: any, id: string): any
	for _, entry in ipairs(entries or {}) do
		if entry.id == id then return entry end
	end
	return nil
end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function World.setBed(plot: Plot, slot: number, plant: any, config: any)
	local bed = plot.beds[slot]
	local view = if bed then views[bed] else nil
	if not view or not bed or not bed:IsDescendantOf(Workspace) then return end
	local species = if plant then findEntry(config.species, plant.speciesId) else nil
	if not plant or not species or not finite(plant.plantedAt) or not finite(plant.readyAt) then
		if view.growth then
			stopGrowth(view.growth)
			view.growth.model:Destroy()
			view.growth = nil
		end
		view.label.Enabled = false
		view.prompt.ActionText = "Plantar"
		view.prompt.ObjectText = string.format("Canteiro %02d", slot)
		bed:SetAttribute("GrowthStage", nil)
		bed:SetAttribute("CrystalReady", nil)
		return
	end
	local mutationId = if type(plant.mutation) == "table" then plant.mutation.id else (plant.mutation or "normal")
	local mutation = findEntry(config.mutations, mutationId)
	local color = Color3.fromRGB(species.color[1], species.color[2], species.color[3])
	if mutation and mutationId ~= "normal" then
		color = color:Lerp(Color3.fromRGB(mutation.color[1], mutation.color[2], mutation.color[3]), 0.45)
	end
	local now = Workspace:GetServerTimeNow()
	local ready = now >= plant.readyAt
	local duration = math.max(0.001, plant.readyAt - plant.plantedAt)
	local stage = if ready then 1 else math.clamp((now - plant.plantedAt) / duration, 0, 1)
	-- At most fifty growth changes per plant; labels/prompts update independently.
	stage = math.floor(stage * 50) / 50
	local growth = view.growth
	if growth and (growth.speciesId ~= plant.speciesId or growth.plantedAt ~= plant.plantedAt
		or growth.readyAt ~= plant.readyAt or growth.mutationId ~= mutationId) then
		stopGrowth(growth)
		growth.model:Destroy()
		growth = nil
	end
	local newGrowth = growth == nil
	if not growth then
		local model = Instance.new("Model")
		model.Name = "CrystalGrowth"
		model.Parent = bed
		local anchor = bed.Position + V(0, bed.Size.Y / 2 + 0.02, 0)
		local pieces: { Piece } = {}
		for index = 1, 3 do
			local side = index - 2
			local frame = CFrame.new(V(side * 1.35, 0, math.abs(side) * 0.25))
				* CFrame.Angles(0, math.rad(45), math.rad(-side * 12))
			local group = shard(model, "Shoot" .. index, CFrame.new(anchor) * frame,
				if side == 0 then 1.65 else 1.05, if side == 0 then 5.8 else 3.7, color)
			for _, piece in ipairs(group) do
				piece.frame = CFrame.new(anchor):ToObjectSpace(piece.frame)
				table.insert(pieces, piece)
			end
		end
		local halo = Build.cylinder(model, "HarvestHalo", V(5.5, 0.08, 5.5), anchor, swatches.gold, decor)
		halo.CanQuery = false
		halo.CanTouch = false
		halo.Transparency = 1
		growth = { model = model, pieces = pieces, tweens = {}, speciesId = plant.speciesId,
			plantedAt = plant.plantedAt, readyAt = plant.readyAt, mutationId = mutationId, stage = -1 }
		view.growth = growth
	end
	if growth.stage ~= stage then
		stopGrowth(growth)
		local scale = 0.16 + stage * 0.84
		local anchor = CFrame.new(bed.Position + V(0, bed.Size.Y / 2 + 0.02, 0))
		for _, piece in ipairs(growth.pieces) do
			local localFrame = piece.frame
			local goal = {
				Size = piece.size * scale,
				CFrame = anchor * CFrame.new(localFrame.Position * scale) * localFrame.Rotation,
			}
			-- Edit-mode previews apply directly; TweenService only advances in play.
			if newGrowth or not RunService:IsRunning() then
				piece.part.Size = goal.Size
				piece.part.CFrame = goal.CFrame
			else
				local tween = TweenService:Create(piece.part, GROW_TWEEN, goal)
				table.insert(growth.tweens, tween)
				tween:Play()
			end
		end
		growth.stage = stage
		bed:SetAttribute("GrowthStage", stage)
	end
	local halo = growth.model:FindFirstChild("HarvestHalo") :: BasePart
	halo.Material = if ready then Enum.Material.Neon else Enum.Material.SmoothPlastic
	halo.Color = if mutation and mutationId ~= "normal" then color else swatches.gold.color
	halo.Transparency = if ready then 0.6 else 1
	view.label.Enabled = ready
	view.text.Text = if mutation and mutationId ~= "normal" then mutation.name .. " · Pronto!" else "Pronto para colher"
	view.prompt.ActionText = if ready then "Colher" else "Crescendo"
	view.prompt.ObjectText = if ready then species.name else string.format("%s · %ds", species.name, math.max(0, math.ceil(plant.readyAt - now)))
	bed:SetAttribute("CrystalReady", ready)
end

function World.setWeather(weather: any)
	if not weatherText or not activeRoot or not activeRoot.Parent then return end
	local id = if type(weather) == "table" then weather.id else "clear"
	-- Authored strings only. Weather never changes timers, rewards or interaction.
	local captions = { clear = "Céu limpo", dew = "Chuva de orvalho", aurora = "Aurora cristalina" }
	weatherText.Text = captions[id] or captions.clear
	if landmarkTip then
		landmarkTip.Color = if id == "aurora" then swatches.lavender.color
			elseif id == "dew" then swatches.crystal.color
			else swatches.crystal.color:Lerp(swatches.white.color, 0.3)
	end
end

return World
