--!strict
--[[
	holdout — the interface.

	Three things and no more, because a shooter's HUD earns its place by what
	it leaves out: where you are, what posture you are in, and what just
	happened to you.

	The minimap is drawn, not rendered
	-----------------------------------

	A `ViewportFrame` with a camera over the world is the obvious way and the
	wrong one: it costs a second render pass every frame to show a player
	shapes they already know. This draws the areas as circles and the player as
	a dot, from `Map` -- the same table the server tests positions against, so
	the drawing and the grid reference can never disagree.

	Coordinates are the point
	-------------------------

	`E4` is two characters a player can type, say out loud, or point at. That
	is the whole reason maps have grids, and it is what makes a minimap useful
	to somebody who is not looking at it.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Map = require(Shared:WaitForChild("Map"))
local Posture = require(Shared:WaitForChild("Posture"))
local Wire = require(Shared:WaitForChild("Wire"))

--[[
	The contract is installed on both halves.

	`Net.define` builds a per-VM table of what exists and which way it points,
	so a client that has not run it answers `Net.on("located")` with "never
	defined" -- which is exactly what happened, and which reads on screen as a
	readout stuck on "Locating" with no error anywhere a player could see.
]]
Wire.install()

local UI = Forge.UI
local Net = Forge.Net
local T = UI.theme

local player = Players.LocalPlayer
local screen = UI.mount("Holdout", { displayOrder = 8, ignoreInset = false })

--: Cold, low and legible over a grey-green forest. A HUD tinted like the world
--: it sits on disappears into it, which is the most common way an atmospheric
--: game becomes an unreadable one.
local INK = Color3.fromRGB(226, 232, 230)
local DIM = Color3.fromRGB(150, 160, 158)
local MARK = Color3.fromRGB(228, 176, 72)
local PLATE = Color3.fromRGB(18, 22, 24)

local MAP_SIZE = 190
--: A circle of the world around the player rather than the whole valley. A
--: minimap that shows everything shows nothing: the useful information is what
--: is close enough to walk into.
local MINIMAP_REACH = 260

local function dot(parent: Instance, size: number, colour: Color3, z: number): Frame
	local f = Instance.new("Frame")
	f.Size = UDim2.fromOffset(size, size)
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = colour
	f.BorderSizePixel = 0
	f.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = f
	f.Parent = parent
	return f
end

-- ================================= minimap ==================================
local minimap = UI.panel(screen, {
	name = "Minimap",
	size = UDim2.fromOffset(MAP_SIZE, MAP_SIZE),
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -T.space.lg, 0, T.space.lg + 34),
	color = PLATE, transparency = 0.28, radius = T.radius.sm,
	strokeColor = Color3.fromRGB(70, 80, 82),
})
minimap.ClipsDescendants = true

--: Grid lines, so the reference on the readout has something to correspond to.
--: They scroll with the player rather than being fixed, because the minimap is
--: a window on the world and not a picture of it.
local gridLines: { Frame } = {}
for _ = 1, math.floor(Map.EXTENT / Map.CELL) do
	for _, vertical in { true, false } do
		local line = Instance.new("Frame")
		line.Name = "Grid"
		line.BackgroundColor3 = Color3.fromRGB(90, 102, 104)
		line.BackgroundTransparency = 0.72
		line.BorderSizePixel = 0
		line.ZIndex = 2
		line.Size = if vertical then UDim2.new(0, 1, 1, 0) else UDim2.new(1, 0, 0, 1)
		line.Parent = minimap
		table.insert(gridLines, line)
	end
end

local areaBlobs: { any } = {}
local self = dot(minimap, 8, MARK, 6)
self.Position = UDim2.fromScale(0.5, 0.5)

--: A needle for facing. Knowing where you are is half of a minimap; knowing
--: which way you are pointing is the half people actually use.
local facing = Instance.new("Frame")
facing.Size = UDim2.fromOffset(2, 12)
facing.AnchorPoint = Vector2.new(0.5, 1)
facing.Position = UDim2.fromScale(0.5, 0.5)
facing.BackgroundColor3 = MARK
facing.BorderSizePixel = 0
facing.ZIndex = 5
facing.Parent = minimap

local atlas: any = nil
task.spawn(function()
	local ok, answer = pcall(function()
		return Net.request("atlas")
	end)
	if not ok or type(answer) ~= "table" then
		return
	end
	atlas = answer
	for _, area in answer.areas do
		local blob = dot(minimap, 12, Color3.fromRGB(120, 150, 148), 3)
		blob.BackgroundTransparency = 0.6
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromOffset(84, 12)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.BackgroundTransparency = 1
		label.Text = string.upper(area.label)
		label.TextSize = 9
		label.TextColor3 = DIM
		label.ZIndex = 4
		label.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
			Enum.FontWeight.Bold)
		label.Parent = blob
		table.insert(areaBlobs, { blob = blob, area = area })
	end
end)

-- ================================= readout ==================================
local readout = UI.panel(screen, {
	name = "Readout",
	size = UDim2.fromOffset(MAP_SIZE, 48),
	anchor = Vector2.new(1, 0),
	pos = UDim2.new(1, -T.space.lg, 0, T.space.lg + 40 + MAP_SIZE),
	color = PLATE, transparency = 0.28, radius = T.radius.sm,
	strokeColor = Color3.fromRGB(70, 80, 82),
})

local gridLabel = UI.label(readout, "\u{2014}", {
	size = T.text.lg, font = T.font.bold, color = MARK,
	frameSize = UDim2.new(0, 56, 0, 24), pos = UDim2.fromOffset(10, 5), z = 3,
})
gridLabel.TextXAlignment = Enum.TextXAlignment.Left

local areaLabel = UI.label(readout, "Locating", {
	size = T.text.sm, color = INK,
	frameSize = UDim2.new(1, -78, 0, 16), pos = UDim2.fromOffset(68, 7), z = 3,
})
areaLabel.TextXAlignment = Enum.TextXAlignment.Left

local coordLabel = UI.label(readout, "", {
	size = T.text.xs, color = DIM,
	frameSize = UDim2.new(1, -60, 0, 14), pos = UDim2.fromOffset(10, 29), z = 3,
})
coordLabel.TextXAlignment = Enum.TextXAlignment.Left

local compassLabel = UI.label(readout, "N", {
	size = T.text.md, font = T.font.bold, color = INK,
	frameSize = UDim2.new(0, 36, 0, 20), z = 3,
	anchor = Vector2.new(1, 0), pos = UDim2.new(1, -10, 0, 25),
})

Net.on("located", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	gridLabel.Text = tostring(payload.reference)
	areaLabel.Text = tostring(payload.area)
	coordLabel.Text = string.format("%d, %d, %d",
		payload.x or 0, payload.y or 0, payload.z or 0)
end)

-- ================================= posture ==================================
local postureLabel = UI.label(screen, "STANDING", {
	name = "Posture",
	size = T.text.xs, font = T.font.bold, color = DIM,
	frameSize = UDim2.new(0, 220, 0, 16),
	anchor = Vector2.new(0, 1), pos = UDim2.new(0, T.space.lg, 1, -T.space.lg),
})
postureLabel.TextXAlignment = Enum.TextXAlignment.Left

local currentPosture = "stand"

Net.on("postured", function(payload: any)
	if type(payload) ~= "table" then
		return
	end
	currentPosture = tostring(payload.posture)
	postureLabel.Text = string.upper(Posture.get(currentPosture).label)
	postureLabel.TextColor3 = if currentPosture == "stand" then DIM else MARK
end)

local function ask(to: string)
	pcall(function()
		Net.request("posture", { to = to })
	end)
end

--[[
	C steps down and up, X drops straight to prone. Both are toggles.

	Hold-to-crouch is the other convention and it is wrong for a game with
	prone in it: holding two keys to lie down while also moving and aiming is
	more fingers than a person has.
]]
ContextActionService:BindAction("Crouch", function(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	ask(if currentPosture == "stand" then "crouch" else "stand")
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.C)

ContextActionService:BindAction("Prone", function(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	ask(if currentPosture == "prone" then "crouch" else "prone")
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.X)

--: Sprint and aim are held. The client sends both without second-guessing
--: what the server will allow: the two disagreeing about the rules is worse
--: than one wasted remote.
local function hold(name: string, key: Enum.KeyCode, remote: string)
	ContextActionService:BindAction(name, function(_, state)
		if state == Enum.UserInputState.Begin then
			pcall(function() Net.request(remote, { on = true }) end)
		elseif state == Enum.UserInputState.End then
			pcall(function() Net.request(remote, { on = false }) end)
		end
		return Enum.ContextActionResult.Pass
	end, false, key)
end
hold("Sprint", Enum.KeyCode.LeftShift, "sprint")
hold("Aim", Enum.KeyCode.LeftAlt, "aim")

-- ================================== atlas ===================================
--[[
	The full map, on M.

	The same drawing at three times the size, with the grid labelled. A player
	who wants to say where something is opens this once, reads two characters
	and closes it -- which is the entire job.
]]
local ATLAS_SIZE = 540

local mapScreen = UI.panel(screen, {
	name = "Atlas",
	size = UDim2.fromOffset(ATLAS_SIZE, ATLAS_SIZE),
	anchor = Vector2.new(0.5, 0.5), pos = UDim2.fromScale(0.5, 0.5),
	color = PLATE, transparency = 0.06, radius = T.radius.md,
	strokeColor = Color3.fromRGB(88, 100, 102),
})
mapScreen.Visible = false
mapScreen.ZIndex = 40
mapScreen.ClipsDescendants = true

local mapSelf = dot(mapScreen, 12, MARK, 46)
local drawn = false

local function drawAtlas()
	local cells = math.floor(Map.EXTENT / Map.CELL)
	for index = 0, cells do
		for _, vertical in { true, false } do
			local line = Instance.new("Frame")
			line.BackgroundColor3 = Color3.fromRGB(96, 110, 112)
			line.BackgroundTransparency = 0.75
			line.BorderSizePixel = 0
			line.ZIndex = 42
			local t = index / cells
			line.Size = if vertical then UDim2.new(0, 1, 1, 0) else UDim2.new(1, 0, 0, 1)
			line.Position = if vertical then UDim2.fromScale(t, 0)
				else UDim2.fromScale(0, t)
			line.Parent = mapScreen
		end
	end

	--: Column letters across the top and row numbers down the side. A grid
	--: with no labels is a decoration.
	for column = 1, #Map.COLUMNS do
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromOffset(20, 14)
		label.Position = UDim2.fromScale((column - 0.5) / cells, 0)
		label.AnchorPoint = Vector2.new(0.5, 0)
		label.BackgroundTransparency = 1
		label.Text = Map.COLUMNS[column]
		label.TextSize = 11
		label.TextColor3 = DIM
		label.ZIndex = 44
		label.Parent = mapScreen
	end
	for row = 1, cells do
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromOffset(16, 14)
		label.Position = UDim2.fromScale(0, (row - 0.5) / cells)
		label.AnchorPoint = Vector2.new(0, 0.5)
		label.BackgroundTransparency = 1
		label.Text = tostring(row)
		label.TextSize = 11
		label.TextColor3 = DIM
		label.ZIndex = 44
		label.Parent = mapScreen
	end

	for _, area in (atlas and atlas.areas or {}) do
		local size = math.max(20, area.radius * ATLAS_SIZE * 2)
		local blob = dot(mapScreen, size, Color3.fromRGB(120, 152, 150), 43)
		blob.BackgroundTransparency = 0.72
		blob.Position = UDim2.fromScale(area.x, area.z)
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromOffset(150, 14)
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromScale(0.5, 0.5)
		label.BackgroundTransparency = 1
		label.Text = area.label
		label.TextSize = 12
		label.TextColor3 = INK
		label.ZIndex = 45
		label.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
			Enum.FontWeight.Bold)
		label.Parent = blob
	end
end

ContextActionService:BindAction("Atlas", function(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if not drawn and atlas then
		drawAtlas()
		drawn = true
	end
	mapScreen.Visible = not mapScreen.Visible
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.M)

-- ================================== ticking =================================
RunService.RenderStepped:Connect(function()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	local position = root.Position
	local look = root.CFrame.LookVector
	local bearing = Map.bearing(look)

	facing.Rotation = bearing
	compassLabel.Text = Map.compass(look)

	--: The world scrolls under a fixed dot, which is what everybody expects
	--: and what makes the dot mean "you" rather than "a thing on a picture".
	for _, entry in areaBlobs do
		local worldX = (entry.area.x - 0.5) * Map.EXTENT
		local worldZ = (entry.area.z - 0.5) * Map.EXTENT
		local dx = (worldX - position.X) / MINIMAP_REACH
		local dz = (worldZ - position.Z) / MINIMAP_REACH
		entry.blob.Position = UDim2.fromScale(0.5 + dx * 0.5, 0.5 + dz * 0.5)
		local size = math.max(16,
			entry.area.radius * Map.EXTENT / MINIMAP_REACH * MAP_SIZE)
		entry.blob.Size = UDim2.fromOffset(size, size)
		--: Hidden rather than clipped off the edge, so the map does not grow a
		--: ring of half-circles around its border.
		entry.blob.Visible = math.abs(dx) < 0.95 and math.abs(dz) < 0.95
	end

	local pixelsPerCell = Map.CELL / MINIMAP_REACH * MAP_SIZE / 2
	for index, line in gridLines do
		local vertical = index % 2 == 1
		local slot = math.floor((index - 1) / 2)
		local offset = if vertical
			then (position.X % Map.CELL) / Map.CELL
			else (position.Z % Map.CELL) / Map.CELL
		local at = (slot * pixelsPerCell - offset * pixelsPerCell) % MAP_SIZE
		line.Position = if vertical then UDim2.fromOffset(at, 0)
			else UDim2.fromOffset(0, at)
	end

	if mapScreen.Visible then
		local nx, nz = Map.normalised(position)
		mapSelf.Position = UDim2.fromScale(nx, nz)
		mapSelf.Rotation = bearing
	end
end)

-- ================================= feedback =================================
Net.on("notice", function(payload: any)
	if type(payload) ~= "table" or type(payload.text) ~= "string" then
		return
	end
	UI.toast(payload.text, {
		color = if payload.kind == "refused" then T.color.danger else INK,
	})
end)

Net.on("looted", function(payload: any)
	if type(payload) ~= "table" or type(payload.found) ~= "table" then
		return
	end
	for _, drop in payload.found do
		UI.toast(string.format("%s%s", tostring(drop.id),
			if drop.amount then " x" .. tostring(drop.amount) else ""),
			{ color = MARK })
	end
end)

return nil
