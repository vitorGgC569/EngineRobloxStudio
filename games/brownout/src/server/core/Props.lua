--!strict
--[[
	Props — place a baked prop and then check what you actually got.

	`Forge.Catalog.Prop.place` takes a `targetHeight` and scales the model by
	`targetHeight / spec.extents[2]`. That is the right idea and it is not
	sufficient, for two measured reasons:

	**The baked extents and the built size disagree.** Asking for a 14-stud
	storage tank at the outpost produced one measuring 31 studs, and crates
	asked for at 2.2 came back at 9. The spec's extents are what the bake read
	off the source model; the rebuilt model's `GetExtentsSize` is what the
	player walks past, and for several props in the catalogue they are not the
	same number.

	**One axis is not a size.** `Terrible Furnace` is 48 studs wide and 8 tall.
	Scaling it to a height of 8 leaves it 48 wide, and what appeared beside the
	generator was not a furnace but a stone wall across the middle of the
	outpost, hiding the machine the whole game points at.

	So this measures the model after it is built, corrects the scale to the
	height that was actually asked for, seats it on the ground, and refuses
	anything whose footprint is still absurd for its height. Fifteen lines, and
	the difference between a yard of props that belong together and a scene with
	a wall in it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Debug = Forge.Debug
local Prop = Forge.Catalog.Prop

local Props = {}

export type Options = {
	height: number,
	parent: Instance?,
	canCollide: boolean?,
	name: string?,
	--: Widest the prop may be relative to its height before it is refused.
	--: Scenery gets a generous 3.5; anything standing in the outpost where the
	--: player needs to see past it gets tighter.
	maxAspect: number?,
}

--[[
	Rescale a built model about its own pivot.

	Every part's size and its offset from the pivot scale together, and the
	rotation basis does not — scaling a basis shears the part. A `SpecialMesh`
	renders at its own `Scale` and ignores the Part's size, so it is scaled
	alongside or the mesh and its collision box come apart.
]]
local function rescale(model: Model, factor: number)
	local pivot = model:GetPivot()
	for _, part in model:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end
		local relative = pivot:ToObjectSpace(part.CFrame)
		local rotation = relative - relative.Position
		part.Size *= factor
		part.CFrame = pivot * (CFrame.new(relative.Position * factor) * rotation)

		local mesh = part:FindFirstChildWhichIsA("SpecialMesh")
		if mesh then
			mesh.Scale *= factor
		end
	end
end

--[[
	Place one prop standing on a point, at the height you asked for.

	Most topics in the catalogue hold more than one prop and `Prop.place` picks
	between them by `seed % count`, so a refusal is retried at `seed + 1`, which
	is the next variant rather than the same one again. That matters more than
	it sounds: an audit of the 28 baked props found a wall-shaped variant filed
	under `bush`, `conveyor`, `furnace`, `log` and `pipe` — the "Camping Log
	Seat" is eight studs long and one tall — so without the retry, a seed that
	landed on the bad half simply left a hole in the scene.
]]
function Props.place(topic: string, seed: number, ground: Vector3, options: Options): Model?
	local model = Props.attempt(topic, seed, ground, options)
	if model then
		return model
	end
	return Props.attempt(topic, seed + 1, ground, options)
end

--: One attempt at one variant. Nil when the topic has nothing baked under it,
--: or when what came out was the wrong shape for the role it was asked for.
function Props.attempt(topic: string, seed: number, ground: Vector3, options: Options): Model?
	local model = Prop.place(topic, seed, ground, {
		targetHeight = options.height,
		parent = options.parent,
		canCollide = options.canCollide,
		name = options.name,
	})
	if not model then
		--: Logged rather than swallowed. A topic with no baked props is almost
		--: always a typo, and a typo here is an invisible no-op that leaves a
		--: hole in the scene nobody can trace back to a line of code.
		Debug.count("props.missingTopic")
		return nil
	end

	local size = model:GetExtentsSize()
	if size.Y > 0.01 then
		local correction = options.height / size.Y
		--: Only when it is actually wrong. Rescaling by 1.0 is a pile of
		--: pointless CFrame writes on every prop in the world.
		if correction < 0.95 or correction > 1.05 then
			rescale(model, correction)
			size = model:GetExtentsSize()
		end
	end

	--: The footprint check, after the height is right. A prop that is still
	--: four times wider than it is tall is a wall wearing a furnace's name.
	local maxAspect = options.maxAspect or 3.5
	local footprint = math.max(size.X, size.Z)
	if size.Y > 0.01 and footprint / size.Y > maxAspect then
		Debug.warn(string.format(
			"refused '%s' (%s): %.0f wide by %.0f tall reads as a wall",
			topic, model.Name, footprint, size.Y))
		model:Destroy()
		return nil
	end

	--: Reseated. Rescaling moves the model's base, and a prop that was standing
	--: on the ground before the correction is buried or floating after it.
	local pivot = model:GetPivot()
	local bottom = pivot.Position.Y - size.Y * 0.5
	local sink = math.min(size.Y * 0.06, 0.5)
	model:PivotTo(pivot + Vector3.new(0, ground.Y - bottom - sink, 0))

	return model
end

return Props
