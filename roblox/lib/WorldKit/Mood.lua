--!strict
-- L5: lighting mood.
--
-- The cheapest professional-looking upgrade available on this platform, and the
-- one most consistently skipped. Lighting technology, atmosphere, clouds and the
-- five post-processing effects cost nothing in assets, nothing in moderation and
-- nothing in upload, and they are the difference between a world that reads as a
-- tabletop and one that reads as a place.
--
-- Every value comes from a mood preset in the token set. Nothing here invents a
-- number, because "brightness 2.6 with ambient 160" is exactly how a map turns
-- white, and a value that lives in a token file is a value somebody can review.
--
-- `apply` is idempotent. Post-effects are Instances, so applying a second mood
-- without removing the first stacks two ColorCorrections and produces a look
-- nobody chose. Everything this module creates is tagged and swept on the next
-- apply.

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local Tokens = require(script.Parent.Tokens)

local Mood = {}

--- Marks the instances this module owns, so re-applying replaces rather than
--- accumulates, and so a hand-placed effect by a human is never destroyed.
local OWNED = "WorldKitMood"

export type Applied = {
	moodId: string,
	tokenSetId: string,
	created: number,
	removed: number,
	--- Effects the token set asked for that this engine build does not have.
	unsupported: { string },
}

local function toColor(triple: any, context: string): Color3
	if type(triple) ~= "table" or #triple ~= 3 then
		error("[WorldKit.Mood] " .. context .. " must be an array of three integers", 3)
	end
	return Color3.fromRGB(triple[1], triple[2], triple[3])
end

local function clearOwned(): number
	local removed = 0
	for _, child in ipairs(Lighting:GetChildren()) do
		if child:GetAttribute(OWNED) == true then
			child:Destroy()
			removed += 1
		end
	end
	for _, child in ipairs(Workspace.Terrain:GetChildren()) do
		if child:GetAttribute(OWNED) == true then
			child:Destroy()
			removed += 1
		end
	end
	return removed
end

local function adopt(instance: Instance, parent: Instance)
	instance:SetAttribute(OWNED, true)
	instance.Parent = parent
end

--- Assign only the properties present in `values`, tolerating engine builds that
--- lack a newer one. Reports what it could not set instead of erroring: a mood
--- that mostly applies is far better than a mood that does not apply at all, but
--- silently dropping half of it is not acceptable either.
local function assign(instance: Instance, values: { [string]: any }, unsupported: { string }, prefix: string)
	for property, value in pairs(values) do
		local ok = pcall(function()
			(instance :: any)[property] = value
		end)
		if not ok then
			table.insert(unsupported, prefix .. "." .. property)
		end
	end
end

--- Apply a mood preset from the token set.
function Mood.apply(tokens: Tokens.TokenSet, moodId: string): Applied
	local mood = tokens:mood(moodId)
	local unsupported: { string } = {}
	local removed = clearOwned()
	local created = 0

	-- lighting -----------------------------------------------------------
	local lighting = mood.lighting
	local technology = (Enum.Technology :: any)[lighting.technology]
	if typeof(technology) ~= "EnumItem" then
		error("[WorldKit.Mood] unknown Enum.Technology: " .. tostring(lighting.technology), 2)
	end

	local lightingValues: { [string]: any } = {
		Technology = technology,
		Brightness = lighting.brightness,
		ClockTime = lighting.clockTime,
		Ambient = toColor(lighting.ambient, "lighting.ambient"),
		OutdoorAmbient = toColor(lighting.outdoorAmbient, "lighting.outdoorAmbient"),
		ExposureCompensation = lighting.exposureCompensation,
	}
	if lighting.geographicLatitude ~= nil then
		lightingValues.GeographicLatitude = lighting.geographicLatitude
	end
	if lighting.colorShiftTop ~= nil then
		lightingValues.ColorShift_Top = toColor(lighting.colorShiftTop, "lighting.colorShiftTop")
	end
	if lighting.colorShiftBottom ~= nil then
		lightingValues.ColorShift_Bottom = toColor(lighting.colorShiftBottom, "lighting.colorShiftBottom")
	end
	if lighting.environmentDiffuseScale ~= nil then
		lightingValues.EnvironmentDiffuseScale = lighting.environmentDiffuseScale
	end
	if lighting.environmentSpecularScale ~= nil then
		lightingValues.EnvironmentSpecularScale = lighting.environmentSpecularScale
	end
	if lighting.shadowSoftness ~= nil then
		lightingValues.ShadowSoftness = lighting.shadowSoftness
	end
	assign(Lighting, lightingValues, unsupported, "Lighting")

	-- atmosphere ---------------------------------------------------------
	local atmosphereSpec = mood.atmosphere
	local atmosphere = Instance.new("Atmosphere")
	local atmosphereValues: { [string]: any } = {
		Density = atmosphereSpec.density,
		Offset = atmosphereSpec.offset,
		Haze = atmosphereSpec.haze,
		Glare = atmosphereSpec.glare,
	}
	if atmosphereSpec.color ~= nil then
		atmosphereValues.Color = toColor(atmosphereSpec.color, "atmosphere.color")
	end
	if atmosphereSpec.decay ~= nil then
		atmosphereValues.Decay = toColor(atmosphereSpec.decay, "atmosphere.decay")
	end
	assign(atmosphere, atmosphereValues, unsupported, "Atmosphere")
	adopt(atmosphere, Lighting)
	created += 1

	-- clouds -------------------------------------------------------------
	-- Parented to Terrain, not Lighting. Putting them under Lighting silently
	-- does nothing, which is a very easy hour to lose.
	if mood.clouds ~= nil then
		local clouds = Instance.new("Clouds")
		local cloudValues: { [string]: any } = {
			Cover = mood.clouds.cover,
			Density = mood.clouds.density,
		}
		if mood.clouds.color ~= nil then
			cloudValues.Color = toColor(mood.clouds.color, "clouds.color")
		end
		assign(clouds, cloudValues, unsupported, "Clouds")
		adopt(clouds, Workspace.Terrain)
		created += 1
	end

	-- sky ----------------------------------------------------------------
	if mood.sky ~= nil then
		local sky = Instance.new("Sky")
		local skyValues: { [string]: any } = {}
		if mood.sky.starCount ~= nil then
			skyValues.StarCount = mood.sky.starCount
		end
		if mood.sky.sunAngularSize ~= nil then
			skyValues.SunAngularSize = mood.sky.sunAngularSize
		end
		if mood.sky.moonAngularSize ~= nil then
			skyValues.MoonAngularSize = mood.sky.moonAngularSize
		end
		assign(sky, skyValues, unsupported, "Sky")
		adopt(sky, Lighting)
		created += 1
	end

	-- post-processing ----------------------------------------------------
	local post = mood.post

	local bloom = Instance.new("BloomEffect")
	assign(bloom, {
		Intensity = post.bloom.intensity,
		Size = post.bloom.size,
		Threshold = post.bloom.threshold,
	}, unsupported, "Bloom")
	adopt(bloom, Lighting)
	created += 1

	local correction = Instance.new("ColorCorrectionEffect")
	local correctionValues: { [string]: any } = {
		Brightness = post.colorCorrection.brightness,
		Contrast = post.colorCorrection.contrast,
		Saturation = post.colorCorrection.saturation,
	}
	if post.colorCorrection.tintColor ~= nil then
		correctionValues.TintColor = toColor(post.colorCorrection.tintColor, "post.colorCorrection.tintColor")
	end
	assign(correction, correctionValues, unsupported, "ColorCorrection")
	adopt(correction, Lighting)
	created += 1

	if post.sunRays ~= nil then
		local rays = Instance.new("SunRaysEffect")
		assign(rays, {
			Intensity = post.sunRays.intensity,
			Spread = post.sunRays.spread,
		}, unsupported, "SunRays")
		adopt(rays, Lighting)
		created += 1
	end

	if post.depthOfField ~= nil then
		local dof = Instance.new("DepthOfFieldEffect")
		assign(dof, {
			FarIntensity = post.depthOfField.farIntensity,
			FocusDistance = post.depthOfField.focusDistance,
			InFocusRadius = post.depthOfField.inFocusRadius,
			NearIntensity = post.depthOfField.nearIntensity,
		}, unsupported, "DepthOfField")
		adopt(dof, Lighting)
		created += 1
	end

	-- Published where the mood id already is, so any prop light can read how
	-- dark the world it stands in actually is.
	Lighting:SetAttribute("WorldKitLightBoost", tonumber(mood.lightBoost) or 1)
	Lighting:SetAttribute("WorldKitMoodId", moodId)
	Lighting:SetAttribute("WorldKitTokenSet", tokens.id)
	Lighting:SetAttribute("WorldKitTokenRevision", tokens.revision)

	return {
		moodId = moodId,
		tokenSetId = tokens.id,
		created = created,
		removed = removed,
		unsupported = unsupported,
	}
end

--- Remove everything this module owns and forget the mood.
function Mood.clear(): number
	local removed = clearOwned()
	Lighting:SetAttribute("WorldKitMoodId", nil)
	Lighting:SetAttribute("WorldKitTokenSet", nil)
	Lighting:SetAttribute("WorldKitTokenRevision", nil)
	return removed
end

--- Which mood is currently applied, if any.
function Mood.current(): string?
	local value = Lighting:GetAttribute("WorldKitMoodId")
	return if type(value) == "string" then value else nil
end

--- Point lights are the one part of a mood that is budgeted rather than set.
---
--- Measured on this project: 49 point lights plus Neon material produced a
--- yellow wash that made the whole map unreadable. The fix was one light. This
--- returns the count so a caller can assert on it rather than discover it.
function Mood.countLights(root: Instance): number
	local count = 0
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("Light") then
			count += 1
		end
	end
	return count
end

return Mood
