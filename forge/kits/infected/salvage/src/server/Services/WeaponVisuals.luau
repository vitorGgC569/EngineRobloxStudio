--!strict
-- Server-built weapon models welded to characters, tinted by the owner's equipped
-- skin (the cosmetic payoff). Everyone gets a gun model — including the hidden
-- Patient Zero, who must look identical to survivors. Zombies get claw-tinted arms
-- instead. Pure parts; no assets to moderate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SkinCatalog = require(Shared.SkinCatalog)

local WeaponVisuals = {}

local function skinById(id: string?)
	if id == nil then
		return nil
	end
	for _, skin in SkinCatalog do
		if skin.id == id then
			return skin
		end
	end
	return nil
end

local function findRightHand(character: Model): BasePart?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then
		return hand
	end
	return nil
end

local function weld(a: BasePart, b: BasePart)
	local weldConstraint = Instance.new("WeldConstraint")
	weldConstraint.Part0 = a
	weldConstraint.Part1 = b
	weldConstraint.Parent = a
end

local function makePart(size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Size = size
	part.Color = color
	part.Material = material
	part.CanCollide = false
	part.CanQuery = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

function WeaponVisuals.removeFrom(character: Model)
	local existing = character:FindFirstChild("WeaponModel")
	if existing then
		existing:Destroy()
	end
end

-- Blocky rifle silhouette: body + barrel + grip, welded to the right hand.
function WeaponVisuals.attachGun(character: Model, gunSkinId: string?)
	WeaponVisuals.removeFrom(character)
	local hand = findRightHand(character)
	if hand == nil then
		return
	end
	local skin = skinById(gunSkinId)
	local color = skin and Color3.fromRGB(skin.color[1], skin.color[2], skin.color[3])
		or Color3.fromRGB(50, 52, 56)
	local material = skin and (Enum.Material :: any)[skin.material] or Enum.Material.Metal

	local model = Instance.new("Model")
	model.Name = "WeaponModel"

	local body = makePart(Vector3.new(0.35, 0.45, 1.6), color, material)
	body.CFrame = hand.CFrame * CFrame.new(0, -0.2, -0.6)
	body.Parent = model
	weld(hand, body)

	local barrel = makePart(Vector3.new(0.18, 0.18, 0.9), color, material)
	barrel.CFrame = body.CFrame * CFrame.new(0, 0.08, -1.1)
	barrel.Parent = model
	weld(body, barrel)

	local grip = makePart(Vector3.new(0.22, 0.5, 0.28), Color3.fromRGB(35, 32, 30), Enum.Material.WoodPlanks)
	grip.CFrame = body.CFrame * CFrame.new(0, -0.42, 0.45) * CFrame.Angles(math.rad(15), 0, 0)
	grip.Parent = model
	weld(body, grip)

	model.Parent = character
end

-- Knife visual used for the throw effect (client renders flight; this is the
-- template builder shared for consistency).
function WeaponVisuals.knifeColor(knifeSkinId: string?): (Color3, Enum.Material)
	local skin = skinById(knifeSkinId)
	if skin then
		return Color3.fromRGB(skin.color[1], skin.color[2], skin.color[3]),
			(Enum.Material :: any)[skin.material]
	end
	return Color3.fromRGB(190, 195, 200), Enum.Material.Metal
end

return WeaponVisuals
