--!strict
--- Real Roblox assets, instead of geometry assembled from boxes.
---
--- Everything a player calls "good looking" in a Roblox game comes from
--- artist-made content: real body meshes, real clothing, real animation clips,
--- real props. None of it needs `InsertService` -- the one thing a third-party
--- plugin genuinely cannot use, and which this engine wrongly treated as a
--- reason to generate the entire world out of primitives instead.
---
--- **Measured, not assumed.** Every constraint below was probed in a live
--- Studio before it was written down, because none of them is what the
--- documentation implies:
---
---   * `MeshPart.MeshId` cannot be written from a plugin thread. It fails with
---     "The current thread cannot write 'MeshId' (lacking capability
---     NotAccessible)". The classic `SpecialMesh` path *is* open, so props go
---     through that instead.
---   * `Players:CreateHumanoidModelFromDescription` works in edit mode and
---     returns a genuine R15 body: fifteen MeshParts, FaceControls, WrapTarget
---     for layered clothing, BodyColors, and the default Animate script with
---     twenty-seven animations already attached.
---   * Modern R15 rigs are driven by `AnimationConstraint`, **not** `Motor6D`.
---     Counting motors to decide whether a model can animate reports zero on a
---     rig that animates perfectly.
---   * `Animation.AnimationId` loads real clips by public asset id with no
---     upload at all: Roblox's own idle measured 4.3 seconds, already cached.
---   * Animations do not evaluate in edit mode. A limb that does not move in
---     the editor is a stopped world, not a broken rig.
---
--- **Nothing here decides anything.** These are constructors and lookups. Pass
--- a different id, a different description, a different clip; copy any of it
--- and change it. The point is only that reaching for real content is now the
--- easy path rather than the impossible one.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local Asset = {}

-- -- animation ------------------------------------------------------------------

--- Roblox's own R15 animation set, by public asset id.
---
--- These are the clips every default character already plays, which is why they
--- are always available and always cached. Listed here so nobody has to guess
--- an id or dig a rig apart to find one.
Asset.animations = {
	idle = "rbxassetid://507766666",
	idleLook = "rbxassetid://507766951",
	idleShift = "rbxassetid://507766388",
	walk = "rbxassetid://507777826",
	run = "rbxassetid://507767714",
	jump = "rbxassetid://507765000",
	fall = "rbxassetid://507767968",
	climb = "rbxassetid://507765644",
	swim = "rbxassetid://507784897",
	wave = "rbxassetid://507770239",
	point = "rbxassetid://507770453",
	cheer = "rbxassetid://507770677",
	laugh = "rbxassetid://507770818",
	dance = "rbxassetid://507771019",
}

--- The `Animator` a rig animates through, made if it is missing.
function Asset.animator(model: Model): Animator?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	return animator
end

--- Load a clip and wait for the asset to actually arrive.
---
--- `LoadAnimation` returns immediately with a track whose `Length` is zero
--- until the download lands. Playing it inside that window plays nothing, with
--- no error, which reads exactly like a broken rig.
function Asset.clip(model: Model, id: string, timeout: number?): AnimationTrack?
	local animator = Asset.animator(model)
	if animator == nil then
		return nil
	end
	local resolved = (Asset.animations :: any)[id] or id
	local animation = Instance.new("Animation")
	animation.AnimationId = resolved

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or track == nil then
		return nil
	end

	local waited, limit = 0, tonumber(timeout) or 5
	while track.Length == 0 and waited < limit do
		task.wait(0.1)
		waited += 0.1
	end
	return track
end

--- Play a clip on a rig. Returns the track, so the caller can stop or blend it.
function Asset.play(model: Model, id: string, options: { [string]: any }?): AnimationTrack?
	local opts = options or {}
	local track = Asset.clip(model, id)
	if track == nil then
		return nil
	end
	track.Looped = opts.looped ~= false
	track.Priority = opts.priority or Enum.AnimationPriority.Idle
	track:Play(tonumber(opts.fade) or 0.2, tonumber(opts.weight) or 1,
		tonumber(opts.speed) or 1)
	return track
end

-- -- people ---------------------------------------------------------------------

--- A real appearance, read off a real account.
---
--- Guessing catalogue ids produces invisible clothing and no error to say so.
--- A description read from an account that already exists cannot be wrong about
--- what a shirt id means, and gives every character a complete outfit.
function Asset.appearanceOf(userId: number): HumanoidDescription?
	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(userId)
	end)
	if ok and description ~= nil then
		return description
	end
	return nil
end

--- A real R15 body: fifteen artist-made meshes, jointed and ready to animate.
---
--- `appearance` takes a `HumanoidDescription`, a userId to copy, or nothing for
--- the default body. Proportions go through the description rather than through
--- part resizes, because that is the only route clothing and accessories follow.
function Asset.person(parent: Instance, options: { [string]: any }?): Model
	local opts = options or {}

	local description: HumanoidDescription
	local given = opts.appearance
	if typeof(given) == "Instance" and (given :: Instance):IsA("HumanoidDescription") then
		description = given :: HumanoidDescription
	elseif type(given) == "number" then
		description = Asset.appearanceOf(given :: number) or Instance.new("HumanoidDescription")
	else
		description = Instance.new("HumanoidDescription")
	end

	if opts.height ~= nil then description.HeightScale = tonumber(opts.height) :: number end
	if opts.width ~= nil then description.WidthScale = tonumber(opts.width) :: number end
	if opts.head ~= nil then description.HeadScale = tonumber(opts.head) :: number end
	if opts.depth ~= nil then description.DepthScale = tonumber(opts.depth) :: number end

	local model = Players:CreateHumanoidModelFromDescription(
		description, Enum.HumanoidRigType.R15)
	model.Name = opts.name or "Person"

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		humanoid.DisplayName = opts.displayName or opts.name or model.Name
		humanoid.MaxHealth = tonumber(opts.maxHealth) or 100
		humanoid.Health = tonumber(opts.health) or humanoid.MaxHealth
		humanoid.WalkSpeed = tonumber(opts.speed) or 12
		-- Townsfolk should not wear a health bar; enemies should.
		humanoid.HealthDisplayType = if opts.showHealth == true
			then Enum.HumanoidHealthDisplayType.AlwaysOn
			else Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.NameDisplayDistance = tonumber(opts.nameDistance) or 120
	end

	model.Parent = parent
	if opts.cframe ~= nil then
		model:PivotTo(opts.cframe)
	elseif opts.position ~= nil then
		model:PivotTo(CFrame.new(opts.position))
	end

	-- A standing character with no clip playing is a mannequin. The default
	-- `Animate` script drives a *player* character; an NPC has to be told.
	if opts.idle ~= false then
		task.defer(function()
			Asset.play(model, opts.idleClip or "idle",
				{ priority = Enum.AnimationPriority.Idle })
		end)
	end
	return model
end

-- -- props ----------------------------------------------------------------------

--- A prop built on a real mesh, through the path a plugin is allowed to use.
---
--- `MeshPart` is closed to us; `Part` plus `SpecialMesh` is not, and renders the
--- same artist-made geometry with the same texture.
function Asset.prop(parent: Instance, meshId: string, options: { [string]: any }?): BasePart
	local opts = options or {}

	local part = Instance.new("Part")
	part.Name = opts.name or "Prop"
	part.Anchored = opts.anchored ~= false
	part.CanCollide = opts.canCollide ~= false
	part.CanQuery = opts.canQuery ~= false
	part.Size = opts.size or Vector3.new(4, 4, 4)

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = meshId
	if opts.textureId ~= nil then
		mesh.TextureId = opts.textureId
	end
	mesh.Scale = opts.scale or Vector3.one
	if opts.offset ~= nil then
		mesh.Offset = opts.offset
	end
	mesh.Parent = part

	part.Parent = parent
	if opts.cframe ~= nil then
		part:PivotTo(opts.cframe)
	elseif opts.position ~= nil then
		part.Position = opts.position
	end
	return part
end

-- -- the sky --------------------------------------------------------------------

--- Light and air: the cheapest large improvement available to any place.
---
--- Flat ambient light on untextured geometry is most of the reason a blockout
--- reads as unfinished. Atmosphere, a sun that casts, and a little grading cost
--- nothing and change every frame.
function Asset.atmosphere(options: { [string]: any }?)
	local opts = options or {}

	-- `Technology` is Studio-only and throws in a running game, which must not
	-- take the rest of the lighting down with it.
	pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)
	Lighting.Brightness = tonumber(opts.brightness) or 2
	Lighting.ExposureCompensation = tonumber(opts.exposure) or 0.25
	Lighting.ClockTime = tonumber(opts.clockTime) or 15.5
	Lighting.GeographicLatitude = tonumber(opts.latitude) or 41
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.6
	Lighting.OutdoorAmbient = opts.ambient or Color3.fromRGB(95, 100, 115)
	Lighting.Ambient = Color3.fromRGB(0, 0, 0)

	local function ensure(class: string, name: string): Instance
		local found = Lighting:FindFirstChild(name)
		if found == nil or not found:IsA(class) then
			if found ~= nil then
				found:Destroy()
			end
			found = Instance.new(class)
			found.Name = name
			found.Parent = Lighting
		end
		return found :: Instance
	end

	local air = ensure("Atmosphere", "Atmosphere") :: Atmosphere
	air.Density = tonumber(opts.density) or 0.36
	air.Offset = 0.1
	air.Color = opts.airColour or Color3.fromRGB(199, 209, 224)
	air.Decay = opts.decay or Color3.fromRGB(106, 112, 125)
	air.Glare = tonumber(opts.glare) or 0.35
	air.Haze = tonumber(opts.haze) or 1.6

	local bloom = ensure("BloomEffect", "Bloom") :: BloomEffect
	bloom.Intensity = tonumber(opts.bloom) or 0.55
	bloom.Size = 24
	bloom.Threshold = 1.1

	local grade = ensure("ColorCorrectionEffect", "Grade") :: ColorCorrectionEffect
	grade.Saturation = tonumber(opts.saturation) or 0.12
	grade.Contrast = tonumber(opts.contrast) or 0.12
	grade.TintColor = opts.tint or Color3.fromRGB(255, 250, 242)

	local sun = ensure("SunRaysEffect", "SunRays") :: SunRaysEffect
	sun.Intensity = tonumber(opts.sunRays) or 0.06
	sun.Spread = 0.8

	if opts.sky ~= false then
		local sky = ensure("Sky", "Sky") :: Sky
		sky.SunAngularSize = 12
		sky.MoonAngularSize = 11
	end

	return {
		lighting = Lighting,
		atmosphere = air,
		bloom = bloom,
		grade = grade,
	}
end

return Asset
