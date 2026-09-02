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
local RunService = game:GetService("RunService")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Arsenal = require(ReplicatedStorage.Shared.Arsenal)

local Place = Forge.Catalog.Place
local Rig = Forge.Rig
local Itch = Forge.Catalog.ItchAssets

local Guns = {}

--[[
	Which catalogue model stands in for which gun.

	Matched by name rather than by topic, because a topic gives four pistols
	and this needs *the* pistol. The catalogue holds no submachine gun, so the
	MP5 borrows the plain rifle cut down -- a compromise worth writing down
	rather than hiding.

	`length` is the weapon along its longest axis, in studs. These are not real
	proportions and are not trying to be: a correctly scaled M9 is a third of a
	stud and vanishes inside a fist, and even at true Roblox proportion -- about
	two studs against a five-stud character -- it reads as a detail rather than
	as the thing the whole game is about. A shooter's weapon is the largest
	object on the screen, so these are sized to be seen first.
]]
local MODELS = {
	m9 = { needle = "Pistol Compact", length = 8.0 },
	mp5 = { needle = "Rifle", length = 9.0 },
	m4 = { needle = "Rifle Assault", length = 11.0 },
	m870 = { needle = "Rifle Battle", length = 11.0 },
	sks = { needle = "Rifle Battle", length = 11.5 },
	m24 = { needle = "Sniper Rifle", length = 13.0 },
}

--: Gunmetal, because every one of these arrives untextured and grey-brown.
--: Two tones so a barrel reads as separate from a stock at arm's length.
local METAL = Color3.fromRGB(52, 54, 58)
local FURNITURE = Color3.fromRGB(74, 62, 50)

--[[
	Make the thing copyable.

	Models fetched through `InsertService` arrive with `Archivable = false` on
	their contents, and `Clone()` silently skips anything non-archivable -- so
	cloning one gives back a Model with no parts in it, no error, and nothing to
	suggest what happened. The first-person weapon was invisible for exactly
	this reason: the copy existed, was positioned correctly every frame, and was
	empty.
]]
local function archivable(model: Instance)
	model.Archivable = true
	for _, instance in model:GetDescendants() do
		instance.Archivable = true
	end
end

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
		--[[
			Anchored until somebody says otherwise.

			These arrive unanchored, get parented to a character at the origin,
			and are welded to a hand seven studs away one frame later. On a rig
			built from ball sockets that snap is a large impulse handed straight
			to the physics solver, and the solver answers by throwing the
			character over the valley -- which is what "the character still
			flies" was. Anchored parts cannot violate a constraint they are not
			participating in yet.
		]]
		part.Anchored = true
		--: Welded to a hand, this becomes part of the character's physics
		--: assembly. A rifle's worth of mass hanging off one arm is a character
		--: that walks badly and sinks into ground it should stand on.
		part.Massless = true
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
	Take the rig out of the weapon.

	The catalogue's guns are articulated: eight mesh parts joined by Motor6Ds to
	a root, driven by bones and an `AnimationController`, with a folder of
	initial poses and named moving pieces -- slide, hammer, trigger, magazine.
	Somebody built these to be animated, and one day that will be worth using.

	Today it is actively harmful. A skinned mesh follows its bones, not its
	part's CFrame, so a rigged model welded to a hand goes where the rig says
	rather than where it was put -- and a rig with no animation playing says
	"the pose I was exported in". Welding every part to a primary on top of that
	leaves two systems arguing about the same geometry.

	Stripped to plain meshes it is a prop, which is all a weapon needs to be
	until this game has hold animations to drive the rig with.
]]
local function strip(model: Instance)
	for _, instance in model:GetDescendants() do
		if instance:IsA("Motor6D") or instance:IsA("Bone")
				or instance:IsA("AnimationController")
				or instance:IsA("Animator")
				or (instance:IsA("Folder") and instance.Name == "InitialPoses") then
			instance:Destroy()
		end
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

	--[[
		Lie the weapon along the axis everything else assumes.

		These models are exported with their length on X, and every offset that
		places one -- in a hand, in front of a camera, on a floor -- wants to
		think in "forward". Turning the model once here means one convention
		instead of a rotation guess at each of the three call sites.
	]]
	do
		local l, h = Place.bounds(model)
		local extent = h - l
		if extent.X > extent.Z then
			Place.turn(model, math.pi / 2)
		end
	end

	model.Name = "Gun_" .. id
	strip(model)
	archivable(model)
	dress(model)
	model.Parent = parent

	--: A `Model` either way, because a caller welding this wants one thing to
	--: pivot and one primary part to weld through.
	if model:IsA("Model") then
		local built = model :: Model
		--: `RootPart` is the rig's own root and the one part every other is
		--: positioned against, so it is the honest thing to pivot and weld
		--: through even after the rig itself is gone.
		built.PrimaryPart = built:FindFirstChild("RootPart") :: BasePart?
			or built.PrimaryPart
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
local grips: { [Model]: any } = {}

--[[
	Put it in the hand, and take the last one away.

	`RightHand` on R15, `Right Arm` on R6. Checking both is four lines and the
	alternative is a game that silently arms nobody on half the avatars in
	Roblox.
]]
function Guns.hold(character: Model, id: string): Model?
	Guns.clear(character)
	local model = Guns.build(id, character)
	if not model then
		return nil
	end

	--[[
		Joined into one rigid body first.

		`Rig.grip` welds the primary part to the hand, which is the whole job for
		the code-built weapons it was written for -- those are single parts. A
		catalogue gun is eight meshes, so without this the grip carries one of
		them and leaves the other seven standing in the field.
	]]
	local primary = model.PrimaryPart
	if not primary then
		model:Destroy()
		return nil
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= primary then
			local join = Instance.new("WeldConstraint")
			join.Part0 = primary
			join.Part1 = descendant
			join.Parent = descendant
		end
	end
	--: Released only once every weld exists, so the assembly enters the
	--: simulation consistent instead of being built inside it.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
	end

	--[[
		`Rig.grip` does the rest, and did before any of it was written here.

		The hand-rolled version was a weld to `RightHand`, a fallback to
		`Right Arm`, `Massless` on every part so the arm is not weighed down,
		`CanCollide` off, and a hard-coded offset -- which is `Rig.grip`, line
		for line, minus the R6 hand lookup it gets right and the `release(keep)`
		that drops a weapon on the floor instead of destroying it.

		Reaching for the engine first would have cost one grep.
	]]
	local handle = Rig.grip(character, model, { parent = character })
	if not handle then
		model:Destroy()
		return nil
	end
	grips[character] = handle
	held[character] = model
	return model
end

function Guns.clear(character: Model)
	local handle = grips[character]
	if handle then
		--: Destroyed rather than dropped: `Caches` owns what appears on a floor,
		--: and a weapon left behind by a swap would be loot nobody placed.
		handle:release(false)
	end
	grips[character] = nil
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
