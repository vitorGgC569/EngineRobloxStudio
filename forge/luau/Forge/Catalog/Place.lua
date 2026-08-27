--!strict
--[[
	Place — put a catalogue model in the world so it looks like it belongs.

	Every game built on bought or salvaged models has to solve the same four
	problems before anything looks right, and each one produces a distinctive
	kind of broken world when it is skipped:

	  * **The pivot is not the centre.** An imported mesh's pivot is wherever
	    the pack's exporter left it -- under a tree's roots, inside a rock.
	    Placing at `ground + height/2` therefore floats or sinks every model by
	    that offset. A whole world hovering, from an assumption that reads as
	    obviously true.

	  * **Packs share no unit.** A sofa arrives 271 units tall and a castle 4.
	    `Scale` holds the answer; this applies it.

	  * **Two thirds arrive grey.** Not a failed upload -- the pack modelled
	    them with plain materials and the importer keeps geometry, not that.
	    `Tint` holds the answer; this applies it.

	  * **Fetching costs a round trip.** `LoadAsset` yields. Placing a thousand
	    props by calling it a thousand times spends minutes re-fetching models
	    already in hand.

	So:

		local Place = Forge.Catalog.Place
		Place.put({ topic = "tree", seed = 7, at = point, yaw = 1.2,
		            parent = folder })

	What stays with the game is the *arrangement* -- where a road runs, which
	side of it the houses face. That is the part worth authoring. None of what
	is below is.
]]

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rng = require(script.Parent.Parent.Core.Rng)
local Scale = require(script.Parent.Scale)
local Tint = require(script.Parent.Tint)

local Place = {}

-- ============================== measuring ===================================
--[[
	The true world box of an instance, computed from its parts.

	Not `GetExtentsSize`, and that call has cost this project two rebuilds. It
	returns the box *in the pivot's frame*, so for anything rotated, or with a
	pivot the exporter left off-centre, it describes a box the model does not
	occupy. Measuring with it and then hunting the resulting fault is a day.

	`half` is the standard oriented-box projection: each local axis contributes
	its own length times how much of that axis points along each world axis.
]]
function Place.bounds(model: Instance): (Vector3, Vector3)
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = Vector3.new(-math.huge, -math.huge, -math.huge)

	local parts: { Instance } = if model:IsA("BasePart")
		then { model }
		else model:GetDescendants()

	for _, instance in parts do
		if not instance:IsA("BasePart") then
			continue
		end
		local part = instance :: BasePart
		local frame, size = part.CFrame, part.Size
		local right, up, look = frame.RightVector, frame.UpVector, frame.LookVector
		local half = Vector3.new(
			0.5 * (math.abs(right.X) * size.X + math.abs(up.X) * size.Y
				+ math.abs(look.X) * size.Z),
			0.5 * (math.abs(right.Y) * size.X + math.abs(up.Y) * size.Y
				+ math.abs(look.Y) * size.Z),
			0.5 * (math.abs(right.Z) * size.X + math.abs(up.Z) * size.Y
				+ math.abs(look.Z) * size.Z))
		low = low:Min(frame.Position - half)
		high = high:Max(frame.Position + half)
	end

	if low.X == math.huge then
		return Vector3.zero, Vector3.zero
	end
	return low, high
end

function Place.move(model: Instance, delta: Vector3)
	if model:IsA("Model") then
		local m = model :: Model
		m:PivotTo(m:GetPivot() + delta)
	else
		local part = model :: BasePart
		part.CFrame = part.CFrame + delta
	end
end

function Place.turn(model: Instance, yaw: number)
	if model:IsA("Model") then
		local m = model :: Model
		m:PivotTo(CFrame.new(m:GetPivot().Position) * CFrame.Angles(0, yaw, 0))
	else
		local part = model :: BasePart
		part.CFrame = CFrame.new(part.Position) * CFrame.Angles(0, yaw, 0)
	end
end

-- =============================== fetching ===================================
local loaded: { [number]: Instance } = {}
local missing: { [number]: boolean } = {}

--[[
	One fetch per asset id, cloned thereafter.

	Kept in `ReplicatedStorage` rather than in a table alone, so the template
	stays parented somewhere the DataModel owns and is not collected while
	clones of it are still being made.
]]
function Place.template(assetId: number): Instance?
	if loaded[assetId] then
		return loaded[assetId]
	end
	if missing[assetId] then
		return nil
	end
	local ok, container = pcall(function()
		return InsertService:LoadAsset(assetId)
	end)
	if not ok or typeof(container) ~= "Instance" then
		missing[assetId] = true
		return nil
	end
	local first = (container :: Instance):GetChildren()[1]
	if not first then
		missing[assetId] = true;
		(container :: Instance):Destroy()
		return nil
	end
	first.Parent = ReplicatedStorage
	loaded[assetId] = first;
	(container :: Instance):Destroy()
	return first
end

function Place.fetched(): number
	local n = 0
	for _ in loaded do
		n += 1
	end
	return n
end

function Place.unavailable(): number
	local n = 0
	for _ in missing do
		n += 1
	end
	return n
end

--: For a game that regenerates its world repeatedly in one session and wants
--: the second run to cost what the first did.
function Place.forget()
	for _, template in loaded do
		template:Destroy()
	end
	table.clear(loaded)
	table.clear(missing)
end

-- ================================ placing ===================================
export type Spec = {
	assetId: number,
	topic: string,
	at: Vector3,
	parent: Instance,
	yaw: number?,
	jitter: number?,     -- multiplies the target height, for variety
	solid: boolean?,     -- collision; default false, see below
	sink: number?,       -- fraction of height buried, default 0.04
	tint: boolean?,      -- default true
	stream: any?,
	sizes: { [string]: Scale.Kind }?,  -- per-game overrides
}

--[[
	Place one model, already chosen.

	Collision defaults to **off**, which surprises people until they see the
	alternative. A pack models a house as a shell; a shell given collision is a
	solid box you cannot walk into, because Roblox's default fidelity boxes it.
	Only things a player is meant to stand *on* should ask for `solid`, and
	those usually want authored geometry anyway.
]]
function Place.build(spec: Spec): Instance?
	local source = Place.template(spec.assetId)
	if not source then
		return nil
	end

	local model = source:Clone()

	--: Turned first, then measured, then scaled, then measured again. Rotation
	--: changes the world box, so a measurement taken before turning describes
	--: something other than the thing being placed.
	Place.turn(model, spec.yaw or 0)

	local low, high = Place.bounds(model)
	local factor = Scale.factor(spec.topic, high - low, spec.jitter, spec.sizes)
	if model:IsA("Model") then
		(model :: Model):ScaleTo(factor)
	else
		local part = model :: BasePart
		part.Size = part.Size * factor
	end

	low, high = Place.bounds(model)
	local size = high - low

	--: The bottom of the box on the ground, the footprint's centre over the
	--: point, whatever the pivot thinks. Sunk very slightly, so an uneven base
	--: does not stand on a visible seam.
	local sink = math.min(size.Y * (spec.sink or 0.04), 0.5)
	local centre = (low + high) * 0.5
	Place.move(model, Vector3.new(
		spec.at.X - centre.X,
		spec.at.Y - low.Y - sink,
		spec.at.Z - centre.Z))

	local solid = spec.solid == true
	local castShadow = size.Y > 6
	local parts: { Instance } = if model:IsA("BasePart")
		then { model }
		else model:GetDescendants()
	for _, instance in parts do
		if instance:IsA("BasePart") then
			local part = instance :: BasePart
			part.Anchored = true
			part.CanCollide = solid
			part.CanTouch = false
			--: Shadows only where the silhouette is big enough to read one.
			--: A thousand props each casting one is the cheapest way to make a
			--: pretty world unplayable on a phone.
			part.CastShadow = castShadow
		end
	end

	if spec.tint ~= false then
		Tint.applyVaried(model, spec.topic, spec.stream or Rng.stream("place.tint"))
	end

	model.Parent = spec.parent
	return model
end

--[[
	Choose from a catalogue and place it.

	`catalogue` is anything with `pick(topic, seed, texturedOnly)` -- which is
	`Forge.Catalog.ItchAssets`, and is a small enough surface that a game with
	its own asset table can satisfy it.

	Textured is preferred and not required: for most topics in most catalogues
	there is no coloured member at all, and refusing to place anything is a
	worse answer than placing something `Tint` will colour.
]]
function Place.put(catalogue: any, spec: Spec & { seed: number }): Instance?
	local assetId = catalogue.pick(spec.topic, spec.seed, true)
		or catalogue.pick(spec.topic, spec.seed, false)
	if not assetId then
		return nil
	end
	local built: any = spec
	built.assetId = assetId
	return Place.build(built)
end

function Place.describe(): { [string]: any }
	return {
		templatesFetched = Place.fetched(),
		assetsUnavailable = Place.unavailable(),
	}
end

return Place
