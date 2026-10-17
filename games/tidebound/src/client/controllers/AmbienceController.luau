--!strict
--[[
	AmbienceController — the sky and the sea, rendered from a broadcast.

	The server decides the weather phase and the hour; this file makes them
	visible and audible. `Weather` draws the rain and moves the light;
	`Sky` places the sun where the server's hour says it is, and the sun
	moving is the day passing.

	One extra condition is defined here, not on the server: "breeze" is a
	render, not a rule.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local Weather = Forge.Weather
local Sky = Forge.Visual.Sky

local state = require(script.Parent.Parent.state)
local audio = require(script.Parent.Parent.audio)

local AmbienceController = {}

local player = Players.LocalPlayer

function AmbienceController.start()
	Weather.installDefaults()
	Weather.define("breeze", {
		rain = 0,
		wind = 0.3,
		brightness = 0.92,
		cloudCover = 0.42,
		fog = { density = 0.12 },
	})
	Sky.install()

	--[[
		The sea is this game's main square, and the engine's generic water
		came back dark, glassy and half-transparent in the first live capture
		-- the horizon read as grey soup. Water properties are client-local,
		so this wins over both the place file and `Sky.install`; nothing else
		in the sky pass touches them, which is why setting it once is enough.
	]]
	local Terrain = workspace.Terrain
	Terrain.WaterColor = Color3.fromRGB(48, 132, 148)
	Terrain.WaterTransparency = 0.34
	Terrain.WaterReflectance = 0.32
	Terrain.WaterWaveSize = 0.22
	Terrain.WaterWaveSpeed = 7

	Net.on("WeatherSync", function(payload: any)
		if payload.phase then
			Weather.set(payload.phase, { transition = 18 })
			--: The same phase drives the wind and rain loops; the sky and the
			--: sea answer the same broadcast so they can never disagree.
			audio.setWeather(payload.phase)
		end
		if payload.hour then
			Sky.applyHour(payload.hour)
		end
	end)

	--: A music bed is wired but silent: `MusicSpecs` ships with empty ids
	--: (uploads are private by default), so this is the documented no-op
	--: path. The Settings "Master music" slider moves the `music` group
	--: either way, so the day a track lands the slider already works.
	audio.setMusic("calm")

	--: Volumes follow the settings in the save, and the sea follows the body.
	state.changed:Connect(function(profile: any)
		audio.setVolumes(profile.settings)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			audio.water(root)
		end
	end)

	local function follow(character: Model)
		character:WaitForChild("HumanoidRootPart", 10)
		local root = character:FindFirstChild("HumanoidRootPart")
		if root then
			audio.water(root)
		end
	end
	if player.Character then
		task.spawn(follow, player.Character)
	end
	player.CharacterAdded:Connect(follow)
end

return AmbienceController
