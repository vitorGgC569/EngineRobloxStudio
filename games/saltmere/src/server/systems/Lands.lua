--!strict
--[[
	Lands — the other shores you can see from the quay.

	Your plot is one yard. Harth, Vellum and Kest already hold the reef,
	the reed docks and the crystal flat. The board on the quay is the race.
]]

local Workspace = game:GetService("Workspace")

local Lands = {}

local labels: { [string]: TextLabel } = {}
local rankLabels: { TextLabel } = {}
local takeHandler: ((Player) -> ())? = nil

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, collide: boolean): Part
	local block = Instance.new("Part")
	block.Name = name
	block.Size = size
	block.CFrame = cf
	block.Anchored = true
	block.CanCollide = collide
	block.Color = color
	block.Material = material
	block.TopSurface = Enum.SurfaceType.Smooth
	block.BottomSurface = Enum.SurfaceType.Smooth
	block.Parent = parent
	return block
end

local function sign(parent: BasePart, name: string, text: string, offset: Vector3): TextLabel
	local board = Instance.new("BillboardGui")
	board.Name = name
	board.Size = UDim2.fromOffset(220, 48)
	board.StudsOffset = offset
	board.MaxDistance = 220
	board.AlwaysOnTop = false
	board.Parent = parent
	local label = Instance.new("TextLabel")
	label.BackgroundColor3 = Color3.fromRGB(20, 18, 16)
	label.BackgroundTransparency = 0.25
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 20
	label.TextColor3 = Color3.fromRGB(236, 232, 220)
	label.Text = text
	label.Parent = board
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = label
	return label
end

local function yard(model: Model, origin: Vector3, color: Color3, material: Enum.Material)
	for index = 1, 3 do
		local x = origin.X + (index - 2) * 16
		part(model, "Pan" .. index, Vector3.new(12, 1.2, 12), CFrame.new(x, origin.Y + 0.6, origin.Z), color, material, true)
		local crust = part(
			model,
			"Crust" .. index,
			Vector3.new(9, 0.2, 9),
			CFrame.new(x, origin.Y + 1.3, origin.Z),
			Color3.fromRGB(236, 232, 220),
			Enum.Material.Salt,
			false
		)
		crust.CanQuery = false
	end
end

local function shore(id: string, title: string, origin: Vector3, ground: Enum.Material, tint: Color3, deck: Enum.Material)
	local terrain = Workspace.Terrain
	terrain:FillBlock(CFrame.new(origin + Vector3.new(0, -1, 0)), Vector3.new(86, 10, 64), ground)

	local model = Instance.new("Model")
	model.Name = id
	local pad = part(model, "Pad", Vector3.new(70, 2, 48), CFrame.new(origin), tint, deck, true)
	model.PrimaryPart = pad
	part(model, "House", Vector3.new(16, 10, 12), CFrame.new(origin + Vector3.new(0, 6, -14)), tint:Lerp(Color3.new(0, 0, 0), 0.25), deck, true)
	yard(model, origin + Vector3.new(0, 1, 8), tint, deck)
	labels[id] = sign(pad, "Score", title, Vector3.new(0, 8, 0))
	model.Parent = Workspace:FindFirstChild("Lands") or Workspace
	return model
end

local function pier(parent: Instance, from: Vector3, to: Vector3)
	local delta = to - from
	local length = delta.Magnitude
	local mid = (from + to) / 2 + Vector3.new(0, 0.4, 0)
	part(parent, "Pier", Vector3.new(6, 0.6, length), CFrame.lookAt(mid, to), Color3.fromRGB(92, 64, 46), Enum.Material.WoodPlanks, true)
end

function Lands.onTake(fn: (Player) -> ())
	takeHandler = fn
end

function Lands.paint(rows: { { id: string, name: string, score: number } })
	for index, row in rows do
		local line = rankLabels[index]
		if line then
			line.Text = string.format("%d  %s    %d", index, row.name, math.floor(row.score))
		end
	end
	for index = #rows + 1, #rankLabels do
		rankLabels[index].Text = ""
	end
end

function Lands.house(id: string, text: string)
	local label = labels[id]
	if label then
		label.Text = text
	end
end

function Lands.start()
	local root = Workspace:FindFirstChild("Lands")
	if not root then
		root = Instance.new("Folder")
		root.Name = "Lands"
		root.Parent = Workspace
	end
	if root:FindFirstChild("AshReef") then
		return
	end

	local ash = shore("harth", "HARTH", Vector3.new(168, 4, -16), Enum.Material.Basalt, Color3.fromRGB(48, 42, 38), Enum.Material.Slate)
	ash.Name = "AshReef"
	ash.Parent = root
	local reed = shore("vellum", "VELLUM", Vector3.new(-168, 4, -16), Enum.Material.LeafyGrass, Color3.fromRGB(86, 110, 62), Enum.Material.Wood)
	reed.Name = "ReedDocks"
	reed.Parent = root
	local flat = shore("kest", "KEST", Vector3.new(0, 5, -176), Enum.Material.Glacier, Color3.fromRGB(214, 224, 228), Enum.Material.Ice)
	flat.Name = "CrystalFlat"
	flat.Parent = root

	local quay = Workspace:FindFirstChild("Quay")
	local anchor = if quay then quay else root
	pier(anchor, Vector3.new(70, 3, -42), Vector3.new(150, 4, -16))
	pier(anchor, Vector3.new(-70, 3, -42), Vector3.new(-150, 4, -16))
	pier(anchor, Vector3.new(0, 3, -52), Vector3.new(0, 5, -150))

	local board = part(anchor, "RaceBoard", Vector3.new(14, 8, 0.6), CFrame.new(-18, 7, -34), Color3.fromRGB(28, 26, 24), Enum.Material.Wood, true)
	local face = Instance.new("SurfaceGui")
	face.Name = "Standings"
	face.Face = Enum.NormalId.Back
	face.CanvasSize = Vector2.new(400, 240)
	face.Parent = board
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 40)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 22
	title.TextColor3 = Color3.fromRGB(236, 196, 120)
	title.Text = "SALT SOLD"
	title.Parent = face
	for index = 1, 4 do
		local line = Instance.new("TextLabel")
		line.Name = "Rank" .. index
		line.BackgroundTransparency = 1
		line.Position = UDim2.fromOffset(12, 36 + (index - 1) * 46)
		line.Size = UDim2.new(1, -24, 0, 42)
		line.Font = Enum.Font.GothamMedium
		line.TextSize = 20
		line.TextXAlignment = Enum.TextXAlignment.Left
		line.TextColor3 = Color3.fromRGB(236, 232, 220)
		line.Text = ""
		line.Parent = face
		rankLabels[index] = line
	end

	local gate = part(flat, "Gate", Vector3.new(8, 6, 1), CFrame.new(0, 8, -150), Color3.fromRGB(176, 112, 62), Enum.Material.Metal, true)
	local Forge = require(game:GetService("ReplicatedStorage"):WaitForChild("Forge"))
	Forge.Interaction.register(gate, {
		id = "crystal_flat",
		label = "Take the flat",
		objectLabel = "Kest",
		holdDuration = 0.6,
		range = 16,
		onTrigger = function(player: Player)
			if takeHandler then
				takeHandler(player)
			end
		end,
	})
end

return Lands
