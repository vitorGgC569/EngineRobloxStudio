--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SkinCatalog = require(ReplicatedStorage.Shared.SkinCatalog)
local WeaponCatalog = require(ReplicatedStorage.Shared.WeaponCatalog)

local WeaponModeler = {}

local function createPart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.Anchored = false
	part.CanCollide = false
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function weldParts(part0: BasePart, part1: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part0
	weld.Part1 = part1
	weld.Parent = part0
end

function WeaponModeler.build(weaponId: string, skinId: string?): Model
	local weaponDef = WeaponCatalog.get(weaponId) or WeaponCatalog.Weapons.service_pistol
	local skinDef = SkinCatalog.get(skinId or "default_factory") or SkinCatalog.Skins.default_factory

	local model = Instance.new("Model")
	model.Name = weaponDef.name .. "_" .. skinDef.id

	local root = Instance.new("Part")
	root.Name = "Handle"
	root.Size = Vector3.new(0.4, 0.6, 0.8)
	root.Transparency = 1
	root.CanCollide = false
	root.Anchored = false
	root.Parent = model
	model.PrimaryPart = root

	local pColor = skinDef.primaryColor
	local sColor = skinDef.secondaryColor
	local aColor = skinDef.accentColor
	local mat = skinDef.material

	if weaponDef.category == "Melee" then
		local hilt = createPart("Hilt", Vector3.new(0.2, 0.8, 0.2), root.CFrame * CFrame.new(0, -0.2, 0), sColor, Enum.Material.Leather, model)
		weldParts(root, hilt)

		local guard = createPart("Guard", Vector3.new(0.6, 0.15, 0.3), root.CFrame * CFrame.new(0, 0.25, 0), aColor, Enum.Material.Metal, model)
		weldParts(root, guard)

		local blade = createPart("Blade", Vector3.new(0.08, 1.4, 0.35), root.CFrame * CFrame.new(0, 1.0, 0), pColor, mat, model)
		weldParts(root, blade)

		if skinDef.emissive and skinDef.neonColor then
			local edge = createPart("NeonEdge", Vector3.new(0.09, 1.35, 0.08), root.CFrame * CFrame.new(0, 1.0, -0.15), skinDef.neonColor, Enum.Material.Neon, model)
			weldParts(root, edge)
		end
	elseif weaponDef.category == "Pistol" then
		local grip = createPart("Grip", Vector3.new(0.25, 0.6, 0.3), root.CFrame * CFrame.Angles(math.rad(-15), 0, 0) * CFrame.new(0, -0.2, 0.1), sColor, Enum.Material.Fabric, model)
		weldParts(root, grip)

		local receiver = createPart("Receiver", Vector3.new(0.28, 0.35, 0.8), root.CFrame * CFrame.new(0, 0.15, -0.1), pColor, mat, model)
		weldParts(root, receiver)

		local slide = createPart("Slide", Vector3.new(0.3, 0.25, 0.85), root.CFrame * CFrame.new(0, 0.38, -0.12), aColor, Enum.Material.Metal, model)
		weldParts(root, slide)

		local muzzle = createPart("Muzzle", Vector3.new(0.18, 0.18, 0.2), root.CFrame * CFrame.new(0, 0.35, -0.6), Color3.fromRGB(20, 20, 20), Enum.Material.Metal, model)
		weldParts(root, muzzle)
	elseif weaponDef.category == "Rifle" or weaponDef.category == "Heavy" then
		local receiver = createPart("Receiver", Vector3.new(0.35, 0.5, 1.4), root.CFrame * CFrame.new(0, 0.1, -0.2), pColor, mat, model)
		weldParts(root, receiver)

		local grip = createPart("Grip", Vector3.new(0.25, 0.7, 0.3), root.CFrame * CFrame.Angles(math.rad(-18), 0, 0) * CFrame.new(0, -0.35, 0.2), sColor, Enum.Material.Fabric, model)
		weldParts(root, grip)

		local stock = createPart("Stock", Vector3.new(0.3, 0.55, 0.9), root.CFrame * CFrame.new(0, 0.05, 0.85), sColor, Enum.Material.SmoothPlastic, model)
		weldParts(root, stock)

		local barrel = createPart("Barrel", Vector3.new(0.2, 0.2, 1.2), root.CFrame * CFrame.new(0, 0.2, -1.3), aColor, Enum.Material.Metal, model)
		weldParts(root, barrel)

		local mag = createPart("Magazine", Vector3.new(0.22, 0.8, 0.4), root.CFrame * CFrame.Angles(math.rad(10), 0, 0) * CFrame.new(0, -0.45, -0.2), sColor, Enum.Material.Metal, model)
		weldParts(root, mag)

		if skinDef.emissive and skinDef.neonColor then
			local rail = createPart("EnergyRail", Vector3.new(0.1, 0.08, 1.2), root.CFrame * CFrame.new(0, 0.38, -0.2), skinDef.neonColor, Enum.Material.Neon, model)
			weldParts(root, rail)
		end
	else
		local body = createPart("Chassis", Vector3.new(0.32, 0.45, 1.8), root.CFrame * CFrame.new(0, 0.1, -0.4), pColor, mat, model)
		weldParts(root, body)

		local stock = createPart("Stock", Vector3.new(0.28, 0.6, 0.9), root.CFrame * CFrame.new(0, -0.05, 0.8), sColor, Enum.Material.Wood, model)
		weldParts(root, stock)

		local longBarrel = createPart("LongBarrel", Vector3.new(0.18, 0.18, 1.6), root.CFrame * CFrame.new(0, 0.2, -1.8), aColor, Enum.Material.Metal, model)
		weldParts(root, longBarrel)

		local scope = createPart("TacticalScope", Vector3.new(0.25, 0.3, 0.7), root.CFrame * CFrame.new(0, 0.48, -0.4), Color3.fromRGB(15, 15, 18), Enum.Material.Metal, model)
		weldParts(root, scope)
	end

	return model
end

return WeaponModeler
