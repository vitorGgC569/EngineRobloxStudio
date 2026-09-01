--!strict
--[[
	Shop — the building a player stacks, and the shelves customers look at.

	`Yard` decides how many stands exist and what is on them. This builds the
	thing you can walk into and puts the carvings where a customer can see
	them, which is the whole reason display is a mechanic rather than a number:
	a piece on a shelf is a piece somebody is looking at.

	Floors, not a bigger box
	------------------------

	The first upgrade widens the ground floor and the next stacks another one on
	top. Growing upward is legible from across the map -- a five-storey shop is
	a player who has been at it, and that is visible to the other five people on
	the server in a way that a wider hut is not.

	`Tycoon/GridPlacement` owns where a stand may go
	------------------------------------------------

	Stand positions are not hand-placed. Each floor is a grid with bounds, the
	stands are items with footprints, and the module answers where they fit.
	That is the same machinery a placement-based tycoon would use later for
	player-arranged furniture, and doing it now means that arrives as a UI
	rather than as a rewrite.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Trees = require(ReplicatedStorage.Shared.Trees)
local Yard = require(script.Parent.Yard)

local GridPlacement = Forge.Tycoon.GridPlacement

local Shop = {}

Shop.FLOOR_HEIGHT = 13
Shop.WIDTH = 38
Shop.DEPTH = 24
Shop.CELL = 3

--: One grid per shop shape rather than per shop. The bounds only depend on
--: the building, so six players with the same upgrades share the answer.
local grids: { [number]: any } = {}

local function gridFor(perFloor: number): any
	local existing = grids[perFloor]
	if existing then
		return existing
	end
	local items = {}
	for index = 1, perFloor do
		table.insert(items, { id = "stand" .. index, footprintX = 3, footprintZ = 3 })
	end
	local grid = GridPlacement.new({
		cellSize = Shop.CELL,
		--[[
			The shelves stand in the *back* half, and the back is +Z.

			The building faces the yard, because the yard is where its owner
			is. Built the other way round the first time, and the first
			screenshot of a finished shop is its blank back wall filling the
			screen with every shelf hidden behind it.
		]]
		bounds = {
			minX = -Shop.WIDTH / 2 + 3, maxX = Shop.WIDTH / 2 - 3,
			minZ = 0, maxZ = Shop.DEPTH / 2 - 3,
		},
		items = items,
	})
	grids[perFloor] = grid
	return grid
end

--[[
	Where the stands sit on one floor, left to right.

	`multiOffsets` is asked for the whole row at once so the spacing comes from
	the grid rather than from arithmetic here -- which is what keeps the answer
	right when the counter upgrade changes how many there are.
]]
function Shop.standOffsets(perFloor: number): { { x: number, z: number } }
	local grid = gridFor(perFloor)
	local offsets = grid:multiOffsets("stand1", perFloor, 0)
	if #offsets >= perFloor then
		return offsets
	end
	--: The grid could not fit them; spread them evenly instead of dropping
	--: shelves a player has paid for.
	local out = {}
	local span = Shop.WIDTH - 8
	for index = 1, perFloor do
		local t = if perFloor == 1 then 0.5 else (index - 1) / (perFloor - 1)
		table.insert(out, { x = -span / 2 + t * span, z = 3 })
	end
	return out
end

-- ================================== pieces ==================================
local function slab(name: string, size: Vector3, at: Vector3, colour: Color3,
                    material: Enum.Material, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(at)
	part.Anchored = true
	part.Color = colour
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

--[[
	A carving on a shelf.

	Small, and shaped rather than a coloured cube: the piece is the product, and
	a player who spent three strokes earning a Masterwork should be able to see
	which shelf it is on. Quality shows as a rim -- brighter and taller as the
	grade climbs -- because colour is already saying which species it is.
]]
local QUALITY_RIM = {
	rough = { colour = Color3.fromRGB(122, 106, 88), height = 0.15 },
	fine = { colour = Color3.fromRGB(206, 190, 160), height = 0.3 },
	master = { colour = Color3.fromRGB(238, 186, 92), height = 0.5 },
	flawless = { colour = Color3.fromRGB(150, 226, 244), height = 0.75 },
}

function Shop.carvingModel(speciesId: string, quality: string, at: Vector3,
                           parent: Instance): Model
	local species = Trees.get(speciesId)
	local colour = if species then species.colour else Color3.fromRGB(150, 150, 150)
	local wood = if species then species.trunk else Color3.fromRGB(120, 90, 60)
	local rim = QUALITY_RIM[quality] or QUALITY_RIM.rough

	local model = Instance.new("Model")
	model.Name = "Carving"

	local base = slab("Base", Vector3.new(2.4, rim.height, 2.4),
		at, rim.colour, Enum.Material.SmoothPlastic, model)
	base.CanCollide = false
	model.PrimaryPart = base

	--: A turned shape: two stacked drums and a cap. Enough silhouette to read
	--: as *made* at the distance a customer stands.
	local body = slab("Body", Vector3.new(1.5, 1.6, 1.5),
		at + Vector3.new(0, rim.height / 2 + 0.8, 0),
		wood, Enum.Material.Wood, model)
	body.Shape = Enum.PartType.Cylinder
	body.Size = Vector3.new(1.6, 1.5, 1.5)
	body.CFrame = CFrame.new(at + Vector3.new(0, rim.height / 2 + 0.8, 0))
		* CFrame.Angles(0, 0, math.pi / 2)
	body.CanCollide = false

	local crown = slab("Crown", Vector3.new(1.15, 1.15, 1.15),
		at + Vector3.new(0, rim.height / 2 + 2.1, 0),
		colour, Enum.Material.SmoothPlastic, model)
	crown.Shape = Enum.PartType.Ball
	crown.CanCollide = false

	if quality == "flawless" then
		local light = Instance.new("PointLight")
		light.Color = rim.colour
		light.Brightness = 1.1
		light.Range = 11
		light.Parent = crown
	end
	model.Parent = parent
	return model
end

-- ================================ the shell =================================
local shops: { [Player]: any } = {}

local function label(parent: BasePart, face: Enum.NormalId, text: string,
                     colour: Color3, size: Vector2): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.CanvasSize = size
	gui.Parent = parent
	local t = Instance.new("TextLabel")
	t.Name = "Text"
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextScaled = true
	t.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json",
		Enum.FontWeight.Bold)
	t.TextColor3 = colour
	t.Parent = gui
	return t
end

--[[
	Build (or rebuild) a player's shop to match their upgrades.

	Torn down and re-raised rather than diffed. A shop changes shape a handful
	of times in a session -- five floors is five events -- and a rebuild is
	twenty lines where a diff is two hundred and a class of bugs where stands
	survive a floor that did not.
]]
function Shop.raise(player: Player, anchor: Vector3, state: Yard.State,
                    parent: Instance): any
	Shop.clear(player)

	local folder = Instance.new("Folder")
	folder.Name = "Shop_" .. player.Name
	folder.Parent = parent

	local floors = Yard.floors(state.shop)
	local perFloor = Yard.standsPerFloor(state.shop)
	local offsets = Shop.standOffsets(perFloor)

	local record = {
		folder = folder, anchor = anchor, stands = {}, floors = floors,
		perFloor = perFloor,
		--: Where a customer walks to: in front of the open side, which faces
		--: the yard. They come in off the boardwalk and round the building,
		--: which is what makes a shop something you walk *into*.
		door = anchor + Vector3.new(0, 0, -(Shop.DEPTH / 2 + 6)),
	}
	shops[player] = record

	for floor = 1, floors do
		local y = (floor - 1) * Shop.FLOOR_HEIGHT
		local deck = slab("Deck" .. floor, Vector3.new(Shop.WIDTH, 1, Shop.DEPTH),
			anchor + Vector3.new(0, y, 0),
			Color3.fromRGB(176, 134, 88), Enum.Material.WoodPlanks, folder)
		deck.CanCollide = true

		--: Corner posts, non-colliding so a player can walk through the front.
		for _, corner in {
			Vector3.new(-Shop.WIDTH / 2 + 1, 0, -Shop.DEPTH / 2 + 1),
			Vector3.new(Shop.WIDTH / 2 - 1, 0, -Shop.DEPTH / 2 + 1),
			Vector3.new(-Shop.WIDTH / 2 + 1, 0, Shop.DEPTH / 2 - 1),
			Vector3.new(Shop.WIDTH / 2 - 1, 0, Shop.DEPTH / 2 - 1),
		} do
			local post = slab("Post", Vector3.new(1.2, Shop.FLOOR_HEIGHT, 1.2),
				anchor + corner + Vector3.new(0, y + Shop.FLOOR_HEIGHT / 2, 0),
				Color3.fromRGB(122, 88, 58), Enum.Material.Wood, folder)
			post.CanCollide = false
		end

		--[[
			A lamp on every floor.

			The roof is solid and `Future` lighting is honest about that: the
			first shop built came out as a black box with the shelves invisible
			inside it. A shop nobody can see into is a shop with no stock, and
			the whole mechanic is that the stock is visible.
		]]
		local lamp = slab("Lamp" .. floor, Vector3.new(1.2, 0.5, 1.2),
			anchor + Vector3.new(0, y + Shop.FLOOR_HEIGHT - 1.4, 0),
			Color3.fromRGB(252, 232, 186), Enum.Material.Neon, folder)
		lamp.CanCollide = false
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 226, 176)
		light.Brightness = 2.6
		light.Range = math.max(Shop.WIDTH, Shop.DEPTH) * 0.9
		light.Shadows = false
		light.Parent = lamp

		--: Back wall only, at +Z. Three open sides is what lets the shelves be
		--: seen from the yard, and being seen is the entire mechanic.
		local wall = slab("Wall" .. floor,
			Vector3.new(Shop.WIDTH, Shop.FLOOR_HEIGHT - 1, 0.8),
			anchor + Vector3.new(0, y + Shop.FLOOR_HEIGHT / 2, Shop.DEPTH / 2),
			Color3.fromRGB(158, 120, 80), Enum.Material.WoodPlanks, folder)
		wall.CanCollide = false

		for index, offset in offsets do
			local standIndex = (floor - 1) * perFloor + index
			local at = anchor + Vector3.new(offset.x, y + 2.9, offset.z)
			local plinth = slab("Stand" .. standIndex,
				Vector3.new(3.4, 3.8, 3.4), at,
				Color3.fromRGB(146, 110, 70), Enum.Material.Wood, folder)
			plinth:SetAttribute("stand", standIndex)
			plinth.CanCollide = false

			--: The price tag faces out of the open side. `NormalId.Front` is a
			--: part's -Z face, which is the way the customer is standing.
			local tag = label(plinth, Enum.NormalId.Front, "",
				Color3.fromRGB(244, 236, 220), Vector2.new(280, 120))
			tag.TextScaled = false
			tag.TextSize = 26
			tag.Font = Enum.Font.SourceSansBold

			record.stands[standIndex] = {
				plinth = plinth, tag = tag, model = nil,
				top = at + Vector3.new(0, 2.1, 0),
				shown = nil,
			}
		end
	end

	--: The roof goes on whatever floor is currently the top one.
	local topY = (floors - 1) * Shop.FLOOR_HEIGHT
	local roof = slab("Roof", Vector3.new(Shop.WIDTH + 5, 1.2, Shop.DEPTH + 5),
		anchor + Vector3.new(0, topY + Shop.FLOOR_HEIGHT, 0),
		Color3.fromRGB(168, 86, 62), Enum.Material.WoodPlanks, folder)
	roof.CanCollide = false

	local sign = slab("Sign", Vector3.new(Shop.WIDTH - 4, 5.5, 0.7),
		anchor + Vector3.new(0, topY + Shop.FLOOR_HEIGHT + 3.8, -Shop.DEPTH / 2),
		Color3.fromRGB(122, 88, 58), Enum.Material.Wood, folder)
	sign.CanCollide = false
	label(sign, Enum.NormalId.Front,
		player.DisplayName .. "'s Carvings",
		Color3.fromRGB(248, 226, 170), Vector2.new(900, 170))

	--: The counter you walk up to. Its prompt opens the shop panel, so the
	--: building is a door into the interface rather than scenery beside it.
	local counter = slab("Counter", Vector3.new(13, 4, 3.5),
		anchor + Vector3.new(0, 2.4, -(Shop.DEPTH / 2 + 1.5)),
		Color3.fromRGB(150, 112, 72), Enum.Material.Wood, folder)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Open"
	prompt.ActionText = "Manage"
	prompt.ObjectText = "Your shop"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 13
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter
	record.counter, record.prompt = counter, prompt

	Shop.refresh(player, state)
	return record
end

function Shop.clear(player: Player)
	local record = shops[player]
	if record and record.folder then
		record.folder:Destroy()
	end
	shops[player] = nil
end

function Shop.of(player: Player): any
	return shops[player]
end

--[[
	Make the shelves agree with the state.

	Only the stands that changed are rebuilt -- a shop with thirty shelves gets
	one sale at a time, and destroying twenty-nine untouched models to redraw
	one is how a tycoon starts stuttering at five players.
]]
function Shop.refresh(player: Player, state: Yard.State)
	local record = shops[player]
	if not record then
		return
	end
	--: The building itself is out of date if an upgrade landed. Say so; the
	--: caller decides whether to raise it again, because raising it moves the
	--: player's own camera past a rebuilt floor.
	if record.floors ~= Yard.floors(state.shop)
			or record.perFloor ~= Yard.standsPerFloor(state.shop) then
		return false
	end

	for index, view in record.stands do
		local stand = state.shop.stands[index]
		local key = if stand
			then stand.species .. ":" .. stand.quality .. ":" .. stand.price
			else nil
		if view.shown ~= key then
			if view.model then
				view.model:Destroy()
				view.model = nil
			end
			if stand then
				view.model = Shop.carvingModel(stand.species, stand.quality,
					view.top, record.folder)
				local species = Trees.get(stand.species)
				view.tag.Text = string.format("%s\n%s\n%d",
					(species and species.name or stand.species),
					Yard.QUALITY[stand.quality].name, stand.price)
			else
				view.tag.Text = "empty"
			end
			view.shown = key
		end
	end
	return true
end

function Shop.standPosition(player: Player, index: number): Vector3?
	local record = shops[player]
	local view = record and record.stands[index]
	return if view then view.top else nil
end

function Shop.describe(): { [string]: any }
	local count = 0
	for _ in shops do
		count += 1
	end
	return { shops = count }
end

return Shop
