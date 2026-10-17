--!strict
--[[
	BuildKit — authored geometry from parts.

	The hub, the docks and the boats are built here rather than fetched: they
	are the places every player stands on and every camera points at, and a
	network fetch that times out has no fallback that is not a lie about the
	place they are standing.

	Everything returns its own container and parents nothing recursively
	unless asked. Colour comes from the caller; this module knows how wood
	and rope look, and nothing about what they are for.
]]

local BuildKit = {}

BuildKit.palette = {
	wood = Color3.fromRGB(122, 84, 54),
	woodDark = Color3.fromRGB(84, 56, 36),
	woodLight = Color3.fromRGB(162, 118, 78),
	rope = Color3.fromRGB(196, 176, 132),
	canvas = Color3.fromRGB(226, 214, 190),
	brass = Color3.fromRGB(206, 168, 96),
	metal = Color3.fromRGB(110, 116, 124),
	stone = Color3.fromRGB(126, 122, 116),
	stoneDark = Color3.fromRGB(92, 90, 88),
	waterTrim = Color3.fromRGB(64, 138, 156),
}

local WOOD_MATERIALS = {
	wood = Enum.Material.WoodPlanks,
	sand = Enum.Material.Sand,
	stone = Enum.Material.Slate,
	metal = Enum.Material.Metal,
	canvas = Enum.Material.Fabric,
	rope = Enum.Material.Fabric,
	neon = Enum.Material.Neon,
	glass = Enum.Material.Glass,
	grass = Enum.Material.Grass,
}

--: One part, all defaults stamped. `mat` picks a material by nickname so a
--: call site reads `mat = "wood"` instead of the enum's exact spelling.
function BuildKit.part(props: any): Part
	local part = Instance.new("Part")
	part.Anchored = props.anchored ~= false
	part.CanCollide = props.collide ~= false
	part.CanQuery = props.query ~= false
	part.CanTouch = props.touch == true
	part.CastShadow = props.shadow ~= false
	part.Material = WOOD_MATERIALS[props.mat or "wood"] or Enum.Material.WoodPlanks
	part.Color = props.color or BuildKit.palette.wood
	part.Size = props.size or Vector3.new(4, 1, 8)
	part.CFrame = props.cframe or CFrame.new(props.at or Vector3.zero)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Name = props.name or "Part"
	if props.transparency then
		part.Transparency = props.transparency
	end
	if props.reflectance then
		part.Reflectance = props.reflectance
	end
	part.Parent = props.parent
	return part
end

--: A welded assembly from a table of part specs, so a boat or a stall comes
--: back as one Model that can be moved with PivotTo.
function BuildKit.assemble(name: string, parent: Instance?, specs: { any }): Model
	local model = Instance.new("Model")
	model.Name = name
	local root: BasePart? = nil
	for _, spec in specs do
		local part = BuildKit.part(spec)
		part.Parent = model
		if spec.root or not root then
			root = part
		end
	end
	for _, child in model:GetChildren() do
		if child ~= root and child:IsA("BasePart") then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = child
			weld.Parent = root
		end
	end
	model.PrimaryPart = root
	model.Parent = parent
	return model
end

--: A post with a signboard. `facing` is a world direction the board faces.
function BuildKit.sign(text: string, subtext: string?, at: Vector3, facing: Vector3, parent: Instance?): Model
	local height = 11
	local specs = {
		{ name = "Post", size = Vector3.new(1, height, 1), cframe = CFrame.new(at + Vector3.new(0, height / 2, 0)) },
		{ name = "Board", size = Vector3.new(0.6, 4.4, 7.2),
			cframe = CFrame.new(at + Vector3.new(0, height - 1.6, 0), at + facing * 10),
			mat = "wood", color = BuildKit.palette.woodDark },
	}
	local model = BuildKit.assemble("Sign", parent, specs)

	local board = model:FindFirstChild("Board") :: BasePart
	local surface = Instance.new("SurfaceGui")
	surface.Face = Enum.NormalId.Left
	surface.CanvasSize = Vector2.new(720, 440)
	surface.LightInfluence = 0.2
	surface.Parent = board

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.62)
	title.Font = Enum.Font.Merriweather
	title.Text = text
	title.TextColor3 = Color3.fromRGB(238, 226, 200)
	title.TextScaled = true
	title.TextWrapped = true
	title.Parent = surface

	if subtext then
		local sub = Instance.new("TextLabel")
		sub.BackgroundTransparency = 1
		sub.Position = UDim2.fromScale(0, 0.62)
		sub.Size = UDim2.fromScale(1, 0.34)
		sub.Font = Enum.Font.SourceSans
		sub.Text = subtext
		sub.TextColor3 = Color3.fromRGB(188, 176, 152)
		sub.TextScaled = true
		sub.TextWrapped = true
		sub.Parent = surface
	end
	return model
end

--[[
	A plank walkway from `from` to `to`, posts every few studs.

	The deck is a run of short planks rather than one long board so a wooden
	pier reads as built instead of extruded, and the gaps between planks are
	what make the light land on it.
]]
function BuildKit.pier(from: Vector3, to: Vector3, width: number, parent: Instance?): Model
	local delta = to - from
	local length = delta.Magnitude
	local direction = delta.Unit
	local model = Instance.new("Model")
	model.Name = "Pier"

	local plankLength = 3
	local count = math.max(math.floor(length / plankLength), 1)
	local perp = direction:Cross(Vector3.yAxis).Unit * (width / 2)

	for index = 0, count - 1 do
		local centre = from + direction * ((index + 0.5) * (length / count))
		local plank = BuildKit.part({
			name = "Plank",
			size = Vector3.new(width, 0.5, length / count - 0.35),
			cframe = CFrame.new(centre, centre + direction),
			mat = "wood",
			color = if index % 2 == 0 then BuildKit.palette.wood else BuildKit.palette.woodLight,
			parent = model,
		})
		plank.CanCollide = true
	end

	local postEvery = math.max(math.floor(6 / plankLength), 1)
	for index = 0, count, postEvery do
		local centre = from + direction * (index * (length / count))
		for _, side in { 1, -1 } do
			local foot = centre + perp * side + Vector3.new(0, -5.5, 0)
			BuildKit.part({
				name = "Post",
				size = Vector3.new(0.8, 11, 0.8),
				cframe = CFrame.new(foot),
				mat = "wood",
				color = BuildKit.palette.woodDark,
				parent = model,
			})
		end
	end

	--: A rail on one side, because a pier without one is a diving board.
	local railFrom = from + perp + Vector3.new(0, 2.6, 0)
	local railTo = to + perp + Vector3.new(0, 2.6, 0)
	BuildKit.part({
		name = "Rail",
		size = Vector3.new(0.4, 0.4, length),
		cframe = CFrame.new((railFrom + railTo) / 2, railTo),
		mat = "wood",
		color = BuildKit.palette.woodLight,
		parent = model,
	})
	for index = 0, count, postEvery do
		local base = from + direction * (index * (length / count)) + perp
		BuildKit.part({
			name = "RailPost",
			size = Vector3.new(0.5, 3, 0.5),
			cframe = CFrame.new(base + Vector3.new(0, 1.2, 0)),
			mat = "wood",
			color = BuildKit.palette.woodLight,
			parent = model,
		})
	end

	model.Parent = parent
	return model
end

--: A market stall: counter, posts, a canvas awning, and a crate to lean on.
function BuildKit.stall(at: Vector3, facing: Vector3, parent: Instance?): Model
	local cframe = CFrame.lookAt(at, at + facing)
	local specs = {
		{ name = "Counter", size = Vector3.new(9, 1, 3), cframe = cframe * CFrame.new(0, 3, -1.6), mat = "wood" },
		{ name = "CounterFront", size = Vector3.new(9, 3, 0.4), cframe = cframe * CFrame.new(0, 1.5, -0.2), mat = "wood", color = BuildKit.palette.woodDark },
		{ name = "PostL", size = Vector3.new(0.6, 8, 0.6), cframe = cframe * CFrame.new(-4.2, 4, -2.4), mat = "wood", color = BuildKit.palette.woodDark },
		{ name = "PostR", size = Vector3.new(0.6, 8, 0.6), cframe = cframe * CFrame.new(4.2, 4, -2.4), mat = "wood", color = BuildKit.palette.woodDark },
		{ name = "Awning", size = Vector3.new(10.4, 0.4, 6), cframe = cframe * CFrame.new(0, 8, -0.6), mat = "canvas", color = BuildKit.palette.canvas },
		{ name = "AwningStripe", size = Vector3.new(10.4, 0.45, 1.4), cframe = cframe * CFrame.new(0, 8.05, -2.6), mat = "canvas", color = BuildKit.palette.waterTrim },
	}
	return BuildKit.assemble("Stall", parent, specs)
end

--: A lamp post: a tall post, a warm head, and an actual light.
function BuildKit.lamp(at: Vector3, parent: Instance?): Model
	local specs = {
		{ name = "Post", size = Vector3.new(0.7, 13, 0.7), cframe = CFrame.new(at + Vector3.new(0, 6.5, 0)), mat = "metal", color = BuildKit.palette.metal },
		{ name = "Head", size = Vector3.new(2, 0.8, 2), cframe = CFrame.new(at + Vector3.new(0, 13.2, 0)), mat = "metal", color = BuildKit.palette.woodDark },
		{ name = "Glow", size = Vector3.new(1.2, 1.6, 1.2), cframe = CFrame.new(at + Vector3.new(0, 12.4, 0)), mat = "neon", color = Color3.fromRGB(255, 214, 140) },
	}
	local model = BuildKit.assemble("Lamp", parent, specs)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 208, 140)
	light.Brightness = 2.2
	light.Range = 30
	light.Shadows = false
	light.Parent = model:FindFirstChild("Glow") :: BasePart
	return model
end

--: A crate stack. Sizes jitter from the stream so a row does not repeat.
function BuildKit.crates(at: Vector3, parent: Instance?, stream: any?): Model
	local specs = {}
	local rng = stream
	for index, offset in { Vector3.new(0, 0, 0), Vector3.new(3.4, 0, 0.6), Vector3.new(1.6, 3.1, 0.3) } do
		local size = if rng then rng:number(2.6, 3.4) else 3
		specs[index] = {
			name = "Crate" .. index,
			size = Vector3.new(size, size, size),
			cframe = CFrame.new(at + offset, at + offset + Vector3.new(1, 0, 0.2)),
			mat = "wood",
			color = if index == 2 then BuildKit.palette.woodLight else BuildKit.palette.wood,
		}
	end
	return BuildKit.assemble("Crates", parent, specs)
end

--: A barrel.
function BuildKit.barrel(at: Vector3, parent: Instance?): Model
	local specs = {
		{ name = "Body", size = Vector3.new(2.4, 3.4, 2.4), cframe = CFrame.new(at + Vector3.new(0, 1.7, 0)), mat = "wood" },
		{ name = "Hoop", size = Vector3.new(2.6, 0.3, 2.6), cframe = CFrame.new(at + Vector3.new(0, 2.9, 0)), mat = "metal", color = BuildKit.palette.metal },
		{ name = "HoopLow", size = Vector3.new(2.6, 0.3, 2.6), cframe = CFrame.new(at + Vector3.new(0, 0.6, 0)), mat = "metal", color = BuildKit.palette.metal },
	}
	return BuildKit.assemble("Barrel", parent, specs)
end

--: A floating buoy with a neon cap. Colour says which water it marks.
function BuildKit.buoy(at: Vector3, color: Color3, parent: Instance?): Model
	local specs = {
		{ name = "Base", size = Vector3.new(3, 1.6, 3), cframe = CFrame.new(at), mat = "metal", color = BuildKit.palette.woodDark },
		{ name = "Pole", size = Vector3.new(0.5, 4, 0.5), cframe = CFrame.new(at + Vector3.new(0, 2.6, 0)), mat = "metal", color = BuildKit.palette.metal },
		{ name = "Cap", size = Vector3.new(1, 1, 1), cframe = CFrame.new(at + Vector3.new(0, 4.8, 0)), mat = "neon", color = color },
	}
	local model = BuildKit.assemble("Buoy", parent, specs)
	model:FindFirstChild("Base").CanCollide = true
	return model
end

--: A mooring post where a boat ties up: post, ring, cleat.
function BuildKit.mooring(at: Vector3, parent: Instance?): Model
	local specs = {
		{ name = "Post", size = Vector3.new(1.2, 7, 1.2), cframe = CFrame.new(at + Vector3.new(0, 3.5, 0)), mat = "wood", color = BuildKit.palette.woodDark },
		{ name = "Cap", size = Vector3.new(1.7, 0.7, 1.7), cframe = CFrame.new(at + Vector3.new(0, 7.2, 0)), mat = "wood" },
		{ name = "Ring", size = Vector3.new(1.6, 1.6, 0.4), cframe = CFrame.new(at + Vector3.new(0, 5.6, 0)), mat = "metal", color = BuildKit.palette.brass },
	}
	return BuildKit.assemble("Mooring", parent, specs)
end

--: The fallback tree for when the catalogue cannot answer. Takes a scale and
--: a foliage colour so a grove still varies.
function BuildKit.tree(at: Vector3, scale: number, foliage: Color3, parent: Instance?): Model
	local trunkHeight = 9 * scale
	local model = Instance.new("Model")
	model.Name = "Tree"

	local trunk = Instance.new("Part")
	trunk.Name = "Trunk"
	trunk.Shape = Enum.PartType.Cylinder
	trunk.Size = Vector3.new(trunkHeight, 1.6 * scale, 1.6 * scale)
	trunk.CFrame = CFrame.new(at + Vector3.new(0, trunkHeight / 2 - 0.4, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	trunk.Color = BuildKit.palette.woodDark
	trunk.Material = Enum.Material.Wood
	trunk.Anchored = true
	trunk.CanCollide = false
	trunk.CastShadow = false
	trunk.Parent = model

	local crown = Instance.new("Part")
	crown.Name = "Crown"
	crown.Shape = Enum.PartType.Ball
	crown.Size = Vector3.new(9 * scale, 11 * scale, 9 * scale)
	crown.CFrame = CFrame.new(at + Vector3.new(0, trunkHeight + 2.4 * scale, 0))
	crown.Color = foliage
	crown.Material = Enum.Material.Grass
	crown.Anchored = true
	crown.CanCollide = false
	crown.CastShadow = true
	crown.Parent = model

	model.PrimaryPart = trunk
	model.Parent = parent
	return model
end

function BuildKit.bush(at: Vector3, scale: number, tone: Color3, parent: Instance?): Part
	return BuildKit.part({
		name = "Bush",
		size = Vector3.new(4 * scale, 3 * scale, 4 * scale),
		cframe = CFrame.new(at + Vector3.new(0, 1.1 * scale, 0)) * CFrame.Angles(0, scale * 3, 0),
		mat = "grass",
		color = tone,
		collide = false,
		shadow = false,
		parent = parent,
	})
end

function BuildKit.rock(at: Vector3, scale: number, tone: Color3, parent: Instance?): Part
	local part = BuildKit.part({
		name = "Rock",
		size = Vector3.new(5 * scale, 3.2 * scale, 4.2 * scale),
		cframe = CFrame.new(at + Vector3.new(0, 0.8 * scale, 0)) * CFrame.Angles(scale * 0.4, scale * 2.1, scale * 0.2),
		mat = "stone",
		color = tone,
		parent = parent,
	})
	part.CanCollide = true
	return part
end

--[[
	A villager: eight blocks, a hat, and a nameplate.

	Eight and not a catalogue model, because an NPC is somewhere between
	decoration and a service counter and has to exist even when the asset
	pipeline doesn't answer. `RestPivot` is stamped on the model so the idle
	sway can always find its way home -- the pose it is standing in now *is*
	the rest pose, and nothing else records it.

	The nameplate is two labels rather than one, so the name and the
	one-line title never fight for a row.
]]
function BuildKit.npc(def: any, at: Vector3, facing: Vector3, parent: Instance?): Model
	local cframe = CFrame.lookAt(at, at + facing)
	local p = def.palette
	local specs = {
		{ name = "Torso", size = Vector3.new(2, 2.2, 1), cframe = cframe * CFrame.new(0, 3.1, 0), mat = "canvas", color = p.shirt, root = true },
		{ name = "Head", size = Vector3.new(1.5, 1.5, 1.5), cframe = cframe * CFrame.new(0, 4.95, 0), mat = "canvas", color = p.skin },
		{ name = "HatBrim", size = Vector3.new(2.3, 0.25, 2.3), cframe = cframe * CFrame.new(0, 5.8, 0), mat = "canvas", color = p.hat },
		{ name = "HatTop", size = Vector3.new(1.3, 0.65, 1.3), cframe = cframe * CFrame.new(0, 6.2, 0), mat = "canvas", color = p.hat },
		{ name = "ArmL", size = Vector3.new(0.7, 2.1, 0.7), cframe = cframe * CFrame.new(-1.35, 3.1, 0), mat = "canvas", color = p.shirt },
		{ name = "ArmR", size = Vector3.new(0.7, 2.1, 0.7), cframe = cframe * CFrame.new(1.35, 3.1, 0), mat = "canvas", color = p.shirt },
		{ name = "LegL", size = Vector3.new(0.8, 2, 0.8), cframe = cframe * CFrame.new(-0.55, 1, 0), mat = "canvas", color = p.pants },
		{ name = "LegR", size = Vector3.new(0.8, 2, 0.8), cframe = cframe * CFrame.new(0.55, 1, 0), mat = "canvas", color = p.pants },
	}
	local model = BuildKit.assemble("Npc_" .. tostring(def.id), parent, specs)

	local head = model:FindFirstChild("Head") :: BasePart?
	if head then
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Nameplate"
		billboard.Size = UDim2.fromOffset(220, 50)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0)
		billboard.LightInfluence = 0
		billboard.MaxDistance = 90
		billboard.Parent = head

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "Title"
		nameLabel.BackgroundTransparency = 1
		nameLabel.Size = UDim2.new(1, 0, 0, 28)
		nameLabel.Font = Enum.Font.Merriweather
		nameLabel.Text = tostring(def.name)
		nameLabel.TextColor3 = Color3.fromRGB(240, 232, 214)
		nameLabel.TextScaled = true
		nameLabel.TextStrokeTransparency = 0.4
		nameLabel.Parent = billboard

		local subLabel = Instance.new("TextLabel")
		subLabel.Name = "Subtitle"
		subLabel.BackgroundTransparency = 1
		subLabel.Position = UDim2.fromScale(0, 0.6)
		subLabel.Size = UDim2.new(1, 0, 0, 18)
		subLabel.Font = Enum.Font.SourceSans
		subLabel.Text = tostring(def.title or "")
		subLabel.TextColor3 = Color3.fromRGB(168, 190, 196)
		subLabel.TextScaled = true
		subLabel.TextStrokeTransparency = 0.55
		subLabel.Parent = billboard
	end

	model:SetAttribute("RestPivot", model:GetPivot())
	return model
end

return BuildKit
