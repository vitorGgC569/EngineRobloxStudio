--!strict
-- Lighting presets.
--
-- Lighting is most of what "the graphics look bad" actually means. Flat
-- ambient light with no atmosphere or shadows makes good geometry look like
-- untextured plastic, so a preset sets the whole stack together rather than
-- leaving a game to discover each property.

local Lighting = game:GetService("Lighting")

local Sky = {}

export type Preset = {
	name: string,
	clockTime: number,
	brightness: number,
	ambient: Color3,
	outdoorAmbient: Color3,
	exposure: number,
	fogEnd: number,
	atmosphereDensity: number,
	atmosphereHaze: number,
	bloomIntensity: number,
	contrast: number,
	saturation: number,
	tint: Color3,
}

--- Bright midday. The look a brick-built collector needs: flat even light, a
--- blue sky, almost no fog and no heavy bloom. Atmospheric effects that flatter
--- a dark industrial scene turn a saturated one into soup.
Sky.BrightDay = {
	name = "BrightDay",
	clockTime = 13.2,
	-- Measured: brightness 2.6 with ambient near 160 blew the scene to white.
	-- Saturated flat colours need much less fill than a dark PBR scene does.
	brightness = 1.8,
	ambient = Color3.fromRGB(72, 76, 84),
	outdoorAmbient = Color3.fromRGB(126, 132, 142),
	exposure = -0.1,
	fogEnd = 9000,
	atmosphereDensity = 0.18,
	atmosphereHaze = 0.6,
	bloomIntensity = 0.25,
	contrast = 0.05,
	saturation = 0.1,
	tint = Color3.fromRGB(255, 255, 255),
} :: Preset

--- Late afternoon: long shadows, warm key light, cool shade.
Sky.GoldenHour = {
	name = "GoldenHour",
	clockTime = 15.6,
	brightness = 3,
	ambient = Color3.fromRGB(72, 80, 92),
	outdoorAmbient = Color3.fromRGB(108, 122, 138),
	exposure = 0.12,
	fogEnd = 2800,
	atmosphereDensity = 0.32,
	atmosphereHaze = 1.6,
	bloomIntensity = 0.75,
	contrast = 0.14,
	saturation = 0.08,
	tint = Color3.fromRGB(255, 246, 236),
} :: Preset

--- Blue hour: cold, high-contrast, neon reads strongly.
Sky.DuskIndustrial = {
	name = "DuskIndustrial",
	clockTime = 18.4,
	brightness = 2.2,
	ambient = Color3.fromRGB(52, 62, 78),
	outdoorAmbient = Color3.fromRGB(78, 94, 116),
	exposure = 0.2,
	fogEnd = 2200,
	atmosphereDensity = 0.42,
	atmosphereHaze = 2.2,
	bloomIntensity = 1.1,
	contrast = 0.2,
	saturation = 0.12,
	tint = Color3.fromRGB(238, 244, 255),
} :: Preset

local function child<T>(className: string, name: string): T
	local existing = Lighting:FindFirstChildOfClass(className)
	if existing then
		return existing :: any
	end
	local created = Instance.new(className)
	created.Name = name
	created.Parent = Lighting
	return created :: any
end

--- Apply a preset to Lighting, creating the effects it needs.
function Sky.apply(preset: Preset)
	Lighting.ClockTime = preset.clockTime
	Lighting.Brightness = preset.brightness
	Lighting.Ambient = preset.ambient
	Lighting.OutdoorAmbient = preset.outdoorAmbient
	Lighting.ExposureCompensation = preset.exposure
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.35
	Lighting.EnvironmentSpecularScale = 0.25
	Lighting.FogEnd = preset.fogEnd
	Lighting.FogStart = preset.fogEnd * 0.25

	-- Future lighting is what makes point lights and materials read properly;
	-- without it the neon and metal in a palette look painted on.
	pcall(function()
		Lighting.Technology = Enum.Technology.Future
	end)

	local atmosphere: Atmosphere = child("Atmosphere", "Atmosphere")
	atmosphere.Density = preset.atmosphereDensity
	atmosphere.Haze = preset.atmosphereHaze
	atmosphere.Glare = 0.25
	atmosphere.Decay = Color3.fromRGB(126, 148, 168)

	local bloom: BloomEffect = child("BloomEffect", "Bloom")
	bloom.Intensity = preset.bloomIntensity
	bloom.Size = 24
	bloom.Threshold = 1.1

	local colour: ColorCorrectionEffect = child("ColorCorrectionEffect", "ColorCorrection")
	colour.Contrast = preset.contrast
	colour.Saturation = preset.saturation
	colour.TintColor = preset.tint
	colour.Brightness = 0

	local sunRays: SunRaysEffect = child("SunRaysEffect", "SunRays")
	sunRays.Intensity = 0.08
	sunRays.Spread = 0.9

	-- A visible sky is most of the mood in a bright build; the default grey
	-- void behind the horizon is what makes a cheerful map look unfinished.
	local sky: Sky = child("Sky", "Sky")
	sky.SkyboxBk = "rbxassetid://12064107925"
	sky.SkyboxDn = "rbxassetid://12064108157"
	sky.SkyboxFt = "rbxassetid://12064112239"
	sky.SkyboxLf = "rbxassetid://12064108876"
	sky.SkyboxRt = "rbxassetid://12064109624"
	sky.SkyboxUp = "rbxassetid://12064110871"
	sky.CelestialBodiesShown = true
	sky.SunAngularSize = 12
end

return Sky
