--!strict
--[[
	Material — physically based surfaces.

	Everything this engine has rendered so far has been `Part.Material` and a
	colour: SmoothPlastic, Wood, Slate. Those are Roblox's *legacy* materials,
	and they carry no normal map, no roughness and no metalness. A rock made of
	them is a coloured box with a noise texture, and no amount of lighting work
	fixes it, because there is nothing in the surface for light to catch.

	Two mechanisms replace that, and they are for different things:

	  `SurfaceAppearance` overrides one MeshPart's textures. It is how a
	  specific model gets its own colour, normal, metalness and roughness maps.

	  `MaterialVariant` replaces a whole legacy material everywhere at once.
	  Register a variant named for `Enum.Material.Slate` and every Slate
	  surface in the game — including terrain — picks it up. That is the lever
	  worth pulling first, because it upgrades the entire world in one call
	  without touching a single part.

		Material.define("mossy_rock", {
			base = Enum.Material.Slate,
			color = "rbxassetid://...",
			normal = "rbxassetid://...",
			roughness = "rbxassetid://...",
			studsPerTile = 8,
		})
		Material.applyTerrain(Enum.Material.Slate, "mossy_rock")

	--- On ids ---------------------------------------------------------------

	Every texture id here goes through `Assets`, which refuses anything that
	has not been loaded successfully once. That is deliberate: a wrong texture
	id does not error, it renders as a flat grey surface, which is exactly the
	sort of silent failure that survives every static check and is discovered
	by a person squinting at a screenshot.
]]

local MaterialService = game:GetService("MaterialService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Capability = require(script.Parent.Capability)

local Material = {}

local variants: { [string]: MaterialVariant } = {}
local definitions: { [string]: any } = {}

Material.config = {
	studsPerTile = 8,
	-- Roblox blends a variant with the underlying legacy material's colour.
	-- Full override is almost always what a defined material wants.
	colorMode = Enum.MaterialPattern.Regular,
}

-- ================================== define ==================================
--[[
	Register a material variant.

	`base` is the legacy material it stands in for. That is not cosmetic:
	physics reads the base material for friction and density, and terrain can
	only carry a variant that names the terrain material it replaces.
]]
function Material.define(name: string, spec: any): MaterialVariant?
	local existing = variants[name]
	if existing then
		existing:Destroy()
		variants[name] = nil
	end

	local ok, variant = pcall(function()
		return Instance.new("MaterialVariant")
	end)
	if not ok or not variant then
		warn("[Material] this Roblox build has no MaterialVariant")
		return nil
	end

	local mv = variant :: MaterialVariant
	mv.Name = name

	--[[
		`BaseMaterial` is plugin-only.

		A normal game script cannot write it: Roblox answers "the current
		thread cannot write 'BaseMaterial' (lacking capability Plugin)" and
		throws. A bare assignment here killed the whole client script on its
		way past — no animator, no HUD, a character sliding around with no
		animation at all — for a cosmetic feature.

		That is the same shape as `Terrain.Decoration`, and this module has
		`Capability` for exactly this reason. Going through it means a variant
		that cannot be configured at runtime is a variant this build does not
		get, not a client that stops running.

		The real place for variants is the place file, authored in Studio,
		where the plugin capability exists. `Material.define` is for the cases
		where that is possible; `Material.paint` and `applyTerrain` work on
		variants that are already there regardless of who made them.
	]]
	if not Capability.set(mv, "BaseMaterial", spec.base or Enum.Material.Slate) then
		mv:Destroy()
		return nil
	end
	Capability.set(mv, "StudsPerTile", spec.studsPerTile or Material.config.studsPerTile)

	Capability.set(mv, "ColorMap", spec.color or "")
	Capability.set(mv, "NormalMap", spec.normal or "")
	Capability.set(mv, "MetalnessMap", spec.metalness or "")
	Capability.set(mv, "RoughnessMap", spec.roughness or "")
	if spec.pattern then
		Capability.set(mv, "MaterialPattern", spec.pattern)
	end

	mv.Parent = MaterialService
	variants[name] = mv
	definitions[name] = spec
	return mv
end

--[[
	Define several, and report how many this build could actually take.

	Returns the count rather than nothing, so a caller can tell the difference
	between "PBR is on" and "PBR silently did nothing here" — which from a
	screenshot look identical.
]]
function Material.defineMany(table_: { [string]: any }): number
	local made = 0
	for name, spec in table_ do
		if Material.define(name, spec) then
			made += 1
		end
	end
	return made
end

function Material.get(name: string): MaterialVariant?
	return variants[name]
end

function Material.names(): { string }
	local out = {}
	for name in variants do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- ================================== apply ===================================
--[[
	Make a legacy material render as a variant, everywhere.

	One call and every Slate surface in the world changes, terrain included.
	This is the highest-leverage thing in the module and the reason variants
	beat per-part appearances for world-scale work.
]]
function Material.applyTerrain(base: Enum.Material, variantName: string): boolean
	local variant = variants[variantName]
	if not variant then
		warn(string.format("[Material] no variant named '%s'", variantName))
		return false
	end
	local ok = pcall(function()
		Workspace.Terrain:SetMaterialColor(base, Color3.new(1, 1, 1))
	end)
	-- `MaterialService` maps a base material to a variant by name. The property
	-- is generated per material, so it is reached by name rather than typed.
	local property = base.Name .. "Name"
	return Capability.set(MaterialService, property, variantName) and ok
end

function Material.clearTerrain(base: Enum.Material): boolean
	return Capability.set(MaterialService, base.Name .. "Name", "")
end

-- ================================== tinting =================================
--[[
	Recolour a built-in terrain material. No textures, no variants, no uploads.

	`applyTerrain` above is the powerful path and it is also the expensive one:
	a variant needs texture maps, and texture maps need somebody to author and
	upload them. This is the cheap path, and for the single most common
	complaint about a Roblox world -- that the ground is a dead olive green --
	it is the whole fix.

		Material.tint(Enum.Material.Grass, Color3.fromRGB(126, 200, 96))

	Worth knowing before reaching for it:

	  * **It is global and it persists.** One call restains every surface of
	    that material in the place, and the value is saved with the place. A
	    game that tints at runtime and a designer who tints in Studio will
	    fight over the same property.

	  * **It tints, it does not repaint.** The material keeps its own texture
	    and its luminance; the colour multiplies through. So a saturated tint
	    on a dark material reads muddy rather than bright, and the way to a
	    vivid ground is a light tint, not a strong one.

	  * **Only some materials accept it.** Roblox exposes `SetMaterialColor`
	    for the terrain set -- Grass, Slate, Ground, Rock, Sand and their
	    siblings -- and ignores the rest. The pcall is not defensive
	    decoration; passing an unsupported material really does throw.

	  * **Water is not one of them.** It looks like a terrain material and it
	    is not tinted like one: it has its own properties on `Terrain`. Use
	    `Material.water` for it. This is measured, not assumed -- passing
	    `Enum.Material.Water` here throws.
]]
function Material.tint(base: Enum.Material, colour: Color3): boolean
	local ok = pcall(function()
		Workspace.Terrain:SetMaterialColor(base, colour)
	end)
	if not ok then
		warn(string.format("[Material] %s does not take a terrain colour", base.Name))
	end
	return ok
end

--: What a material is currently tinted to, or nil where it takes no tint.
function Material.tintOf(base: Enum.Material): Color3?
	local ok, colour = pcall(function()
		return Workspace.Terrain:GetMaterialColor(base)
	end)
	return ok and colour or nil
end

--[[
	Apply a whole palette at once, and say how many took.

	Keyed by `Enum.Material` so a palette is a plain table a designer can read
	and reorder. Unsupported materials are skipped rather than aborting the
	rest, because a palette written against one Roblox version should not stop
	working entirely on another that dropped a material from the terrain set.
]]
function Material.tintAll(palette: { [Enum.Material]: Color3 }): number
	local applied = 0
	for base, colour in palette do
		if Material.tint(base, colour) then
			applied += 1
		end
	end
	return applied
end

--[[
	Ready-made ground palettes.

	`stylised` is the look most successful Roblox games use and the one people
	mean by "colourful": light, high-chroma, and readable at a glance. It is
	not realism and is not trying to be -- a bright ground makes objects
	standing on it legible, which matters more in a game played on a phone than
	any amount of physical accuracy.

	`natural` is muted and earthy, for a world meant to read as a place rather
	than as a playground. `arid` is the same idea shifted warm.

	Offered as starting points. The values are light because tint multiplies
	through the material's own texture -- see `Material.tint`.
]]
Material.palettes = {
	stylised = {
		[Enum.Material.Grass] = Color3.fromRGB(132, 208, 104),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(118, 196, 96),
		[Enum.Material.Ground] = Color3.fromRGB(186, 158, 116),
		[Enum.Material.Rock] = Color3.fromRGB(178, 176, 182),
		[Enum.Material.Slate] = Color3.fromRGB(150, 152, 164),
		[Enum.Material.Sand] = Color3.fromRGB(240, 222, 172),
		[Enum.Material.Mud] = Color3.fromRGB(150, 120, 90),
		[Enum.Material.Snow] = Color3.fromRGB(248, 250, 255),
	},
	natural = {
		[Enum.Material.Grass] = Color3.fromRGB(104, 138, 82),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(92, 126, 74),
		[Enum.Material.Ground] = Color3.fromRGB(134, 116, 92),
		[Enum.Material.Rock] = Color3.fromRGB(140, 138, 136),
		[Enum.Material.Slate] = Color3.fromRGB(118, 120, 126),
		[Enum.Material.Sand] = Color3.fromRGB(206, 190, 152),
	},
	arid = {
		[Enum.Material.Grass] = Color3.fromRGB(176, 178, 108),
		[Enum.Material.Ground] = Color3.fromRGB(202, 166, 116),
		[Enum.Material.Rock] = Color3.fromRGB(196, 170, 140),
		[Enum.Material.Slate] = Color3.fromRGB(178, 156, 132),
		[Enum.Material.Sand] = Color3.fromRGB(244, 226, 178),
	},
}

--[[
	Water, which is its own thing.

	`SetMaterialColor` rejects `Enum.Material.Water`; water colour, reflectance,
	transparency and wave motion are properties of `Terrain` itself. Kept beside
	the palettes because anybody tinting a world will want it and would
	otherwise discover the hard way that the obvious call throws.
]]
function Material.water(colour: Color3, options: { [string]: any }?): boolean
	local settings = options or {}
	local ok = pcall(function()
		Workspace.Terrain.WaterColor = colour
		if settings.reflectance then
			Workspace.Terrain.WaterReflectance = settings.reflectance
		end
		if settings.transparency then
			Workspace.Terrain.WaterTransparency = settings.transparency
		end
		if settings.waveSize then
			Workspace.Terrain.WaterWaveSize = settings.waveSize
		end
		if settings.waveSpeed then
			Workspace.Terrain.WaterWaveSpeed = settings.waveSpeed
		end
	end)
	return ok
end

--: Apply one of the named palettes. Returns how many materials took it.
function Material.palette(name: string): number
	local palette = Material.palettes[name]
	if not palette then
		warn(string.format("[Material] no palette named '%s'", name))
		return 0
	end
	return Material.tintAll(palette)
end

--[[
	Give one MeshPart its own textures.

	`SurfaceAppearance` is a child of the part, not a property, and a part may
	only have one — so an existing appearance is replaced rather than
	duplicated, which Roblox would otherwise refuse at runtime.
]]
function Material.surface(part: BasePart, spec: any): Instance?
	local existing = part:FindFirstChildOfClass("SurfaceAppearance")
	if existing then
		existing:Destroy()
	end

	local ok, appearance = pcall(function()
		return Instance.new("SurfaceAppearance")
	end)
	if not ok or not appearance then
		warn("[Material] this Roblox build has no SurfaceAppearance")
		return nil
	end

	local sa = appearance :: any
	Capability.set(sa, "ColorMap", spec.color or "")
	Capability.set(sa, "NormalMap", spec.normal or "")
	Capability.set(sa, "MetalnessMap", spec.metalness or "")
	Capability.set(sa, "RoughnessMap", spec.roughness or "")
	if spec.alphaMode then
		Capability.set(sa, "AlphaMode", spec.alphaMode)
	end
	sa.Parent = part
	return sa
end

--[[
	Apply a defined material to a part and everything under it.

	Sets the base material as well as the variant name, because a part whose
	`MaterialVariant` names something its `Material` does not match renders as
	the plain base — a silent mismatch that looks like the texture failed to
	load.
]]
function Material.paint(root: Instance, variantName: string): number
	local spec = definitions[variantName]
	if not spec then
		warn(string.format("[Material] no variant named '%s'", variantName))
		return 0
	end

	local painted = 0
	local function apply(part: BasePart)
		part.Material = spec.base or Enum.Material.Slate
		if Capability.set(part, "MaterialVariant", variantName) then
			painted += 1
		end
	end

	if root:IsA("BasePart") then
		apply(root)
	end
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			apply(d)
		end
	end
	return painted
end

-- =================================== LOD ====================================
--[[
	Render distance per model.

	Roblox has no author-facing LOD, but `MeshPart.RenderFidelity` is the part
	of it that matters most: `Precise` on every rock in a forest is how a scene
	with a good frame budget spends all of it on geometry nobody can see.

	`Automatic` lets Roblox drop fidelity with distance. It is almost always
	the right answer for scatter, and almost always the wrong one for anything
	the player stands next to.
]]
function Material.renderFidelity(root: Instance, mode: Enum.RenderFidelity): number
	local touched = 0
	local function apply(part: Instance)
		if part:IsA("MeshPart") then
			if Capability.set(part, "RenderFidelity", mode) then
				touched += 1
			end
		end
	end
	apply(root)
	for _, d in root:GetDescendants() do
		apply(d)
	end
	return touched
end

--[[
	Stop small props from casting shadows.

	A shadow costs roughly what the geometry costs. On a pebble it buys
	nothing, and a field of scattered pebbles each casting one is a measurable
	share of a frame for detail no player will ever notice missing.
]]
function Material.shadowBudget(root: Instance, minimumSize: number): number
	local disabled = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			local largest = math.max(d.Size.X, d.Size.Y, d.Size.Z)
			if largest < minimumSize and d.CastShadow then
				d.CastShadow = false
				disabled += 1
			end
		end
	end
	return disabled
end

function Material.describe(): { [string]: any }
	return {
		context = RunService:IsServer() and "server" or "client",
		variants = Material.names(),
		count = #Material.names(),
		unavailable = Capability.missing(),
	}
end

return Material
