--!strict
--[[
	Guns — the thing in your hands, and the thing on the floor.

	`Fight` owns what a gun does. This owns what one looks like, in both places
	it is ever seen: welded to a hand, and lying in a building waiting to be
	picked up.

	The same model in both places, and that is the point
	----------------------------------------------------

	A dropped weapon drawn as a coloured box is a dropped weapon nobody
	recognises from across a room. The whole loot loop depends on being able to
	tell an M24 from a magazine at ten metres without walking over to read a
	label -- so the floor shows the gun, at the size the gun is, and the label
	is a confirmation rather than the only information.

	Welded, not a Tool
	------------------

	Roblox `Tool` brings a backpack, an equip animation, a drop key and a
	handle it wants to own. None of that is wanted here: the weapon is decided
	by `Fight`, there is one of it, and it should never leave the hand except
	by being replaced. A weld to the right hand is the whole mechanism.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Arsenal = require(ReplicatedStorage.Shared.Arsenal)

local Place = Forge.Catalog.Place
local Itch = Forge.Catalog.ItchAssets

local Guns = {}

--[[
	Which catalogue model stands in for which gun.

	Matched by name rather than by topic, because a topic gives four pistols
	and this needs *the* pistol. The catalogue holds no submachine gun, so the
	MP5 borrows the plain rifle cut down -- a compromise worth writing down
	rather than hiding.

	`length` is the weapon along its longest axis, in studs, against a character
	who is about five of them tall. These are the proportions a Roblox avatar
	reads correctly rather than the millimetres a real M9 measures: scaled
	honestly, a pistol is a third of a stud and disappears inside a fist.
]]
local MODELS = {
	m9 = { needle = "Pistol Compact", length = 1.9 },
	mp5 = { needle = "Rifle", length = 2.9 },
	m4 = { needle = "Rifle Assault", length = 4.0 },
	m870 = { needle = "Rifle Battle", length = 4.2 },
	sks = { needle = "Rifle Battle", length = 4.3 },
	m24 = { needle = "Sniper Rifle", length = 4.9 },
}

--: Gunmetal, because every one of these arrives untextured and grey-brown.
--: Two tones so a barrel reads as separate from a stock at arm's length.
local METAL = Color3.fromRGB(52, 54, 58)
local FURNITURE = Color3.fromRGB(74, 62, 50)

local function dress(model: Instance)
	local parts: { Instance } = if model:IsA("BasePart") then { model }
		else model:GetDescendants()
	for _, instance in parts do
		if not instance:IsA("BasePart") then
			continue
		end
		local part = instance :: BasePart
		part.CanCollide = false
		part.CanQuery = false
		part.CastShadow = false
		if part:IsA("MeshPart") and (part :: MeshPart).TextureID ~= "" then
			continue
		end
		local name = string.lower(part.Name)
		local wood = string.find(name, "stock", 1, true)
			or string.find(name, "grip", 1, true)
			or string.find(name, "wood", 1, true)
		part.Color = if wood then FURNITURE else METAL
		part.Material = if wood then Enum.Material.Wood else Enum.Material.Metal
	end
end

--[[
	One gun, built at the origin, for whoever wants to place it.

	Returns nil when the catalogue has nothing for that id -- a caller that
	falls back to a box is better than one that gets a silent empty model and
	welds nothing to a hand.
]]
function Guns.build(id: string, parent: Instance): Model?
	local spec = MODELS[id]
	if not spec then
		return nil
	end
	local assetId = Itch.named("pistol", spec.needle)
		or Itch.named("rifle", spec.needle)
	if not assetId then
		return nil
	end

	--[[
		Built from the template rather than through `Place.build`.

		`Place` grounds what it places, anchors it and scales it into its topic's
		size band -- all three correct for a tree in a field and all three wrong
		for something about to be welded to a moving hand. What is wanted here is
		the model at a known length, unanchored, pivoted by the caller.
	]]
	local source = Place.template(assetId)
	if not source then
		return nil
	end
	local model = source:Clone()
	local low, high = Place.bounds(model)
	local size = high - low
	local longest = math.max(size.X, size.Y, size.Z)
	if longest > 0.01 then
		local factor = spec.length / longest
		if model:IsA("Model") then
			(model :: Model):ScaleTo(factor)
		else
			local part = model :: BasePart
			part.Size = part.Size * factor
		end
	end

	model.Name = "Gun_" .. id
	dress(model)
	model.Parent = parent

	--: A `Model` either way, because a caller welding this wants one thing to
	--: pivot and one primary part to weld through.
	if model:IsA("Model") then
		local built = model :: Model
		built.PrimaryPart = built.PrimaryPart
			or built:FindFirstChildWhichIsA("BasePart")
		return built
	end
	local wrapper = Instance.new("Model")
	wrapper.Name = model.Name
	model.Parent = wrapper
	wrapper.PrimaryPart = model :: BasePart
	wrapper.Parent = parent
	return wrapper
end

-- ================================= in hand ==================================
local held: { [Model]: Model } = {}

--[[
	Put it in the hand, and take the last one away.

	`RightHand` on R15, `Right Arm` on R6. Checking both is four lines and the
	alternative is a game that silently arms nobody on half the avatars in
	Roblox.
]]
function Guns.hold(character: Model, id: string): Model?
	Guns.clear(character)
	local hand = character:FindFirstChild("RightHand")
		or character:FindFirstChild("Right Arm")
	if not (hand and hand:IsA("BasePart")) then
		return nil
	end
	local model = Guns.build(id, character)
	if not model then
		return nil
	end
	local primary = model.PrimaryPart
	if not primary then
		model:Destroy()
		return nil
	end

	--: Forward along the hand, rolled so the sights sit up. Hand-tuned once and
	--: kept here rather than per gun: every model in the catalogue is built to
	--: the same axis, and a per-gun offset table would be six numbers that all
	--: turn out to be the same.
	local offset = CFrame.new(0, -0.4, -1.1) * CFrame.Angles(0, math.rad(90), 0)
	model:PivotTo(hand.CFrame * offset)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = primary
	weld.Parent = primary

	--: Everything that is not the primary is welded to it, or the model comes
	--: apart the moment the arm moves.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= primary then
			local join = Instance.new("WeldConstraint")
			join.Part0 = primary
			join.Part1 = descendant
			join.Parent = descendant
			descendant.Anchored = false
		end
	end
	primary.Anchored = false
	held[character] = model
	return model
end

function Guns.clear(character: Model)
	local model = held[character]
	if model then
		model:Destroy()
	end
	held[character] = nil
	for _, child in character:GetChildren() do
		if child:IsA("Model") and string.match(child.Name, "^Gun_") then
			child:Destroy()
		end
	end
end

--: Where the muzzle is, for a tracer that starts at the gun rather than at the
--: player's forehead. The far end of the model along its own look axis.
function Guns.muzzle(character: Model): Vector3?
	local model = held[character]
	if not model then
		return nil
	end
	local cf, size = model:GetBoundingBox()
	return (cf * CFrame.new(0, 0, -size.Z / 2 - 0.2)).Position
end

-- ================================ on the floor ==============================
--[[
	A gun lying where it was spilled.

	Laid flat and turned, rather than standing on end -- a rifle balanced
	upright reads as a bug even to somebody who could not say why.
]]
function Guns.lay(id: string, at: Vector3, yaw: number, parent: Instance): Model?
	local model = Guns.build(id, parent)
	if not model then
		return nil
	end
	model:PivotTo(CFrame.new(at)
		* CFrame.Angles(0, yaw, math.rad(90)))
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanQuery = true
		end
	end
	return model
end

function Guns.describe(): { [string]: any }
	local mapped, missing = 0, {}
	for id in MODELS do
		if Arsenal.get(id) then
			mapped += 1
		end
	end
	for _, gun in Arsenal.guns do
		if not MODELS[gun.id] then
			table.insert(missing, gun.id)
		end
	end
	return { mapped = mapped, missing = missing }
end

return Guns
