--!strict
--[[
	WeatherService — one clock for the whole ocean.

	The server owns two things: which weather phase is running, and what hour
	it is. Clients render what they are told (the sky palette, the rain) and
	ask for nothing, which is what keeps two people standing on the same pier
	under the same sky.

	The phase advances on `Config.weather.secondsPerPhase` and the day is
	tuned so one full weather cycle is exactly one full day. Sunrise happens
	in every weather, and a player who fishes through a night has genuinely
	fished through a night.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Forge = require(ReplicatedStorage:WaitForChild("Forge"))

local Net = Forge.Net
local Debug = Forge.Debug

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Roll = require(Shared.Roll)

local WeatherService = {}

--: One in-game hour, in real seconds. Four phases of
--: `Config.weather.secondsPerPhase` is 840s; 24 hours over that is 35s.
WeatherService.hourSeconds = 35
WeatherService.startHour = 8

local clock = 0

local function phaseIndex(): number
	local count = #Config.weather.sequence
	return math.floor(clock / Config.weather.secondsPerPhase) % count + 1
end

function WeatherService.phase(): string
	return Config.weather.sequence[phaseIndex()]
end

function WeatherService.hour(): number
	return (WeatherService.startHour + clock / WeatherService.hourSeconds) % 24
end

function WeatherService.modifier(): any
	return Config.weather.modifier[WeatherService.phase()] or { bite = 1, luck = 0, label = "Clear" }
end

--: Total environmental luck: the phase's bonus plus the night bonus. This is
--: injected into every catch roll, so the HUD number and the actual odds can
--: not drift apart.
function WeatherService.luckBonus(): number
	local luck = WeatherService.modifier().luck or 0
	if Roll.isNight(WeatherService.hour()) then
		luck += Config.nightLuckBonus
	end
	return luck
end

function WeatherService.isNight(): boolean
	return Roll.isNight(WeatherService.hour())
end

local function payload(): any
	local modifier = WeatherService.modifier()
	return {
		phase = WeatherService.phase(),
		label = modifier.label or WeatherService.phase(),
		hour = math.floor(WeatherService.hour() * 100) / 100,
		night = WeatherService.isNight(),
		nextPhaseIn = Config.weather.secondsPerPhase - (clock % Config.weather.secondsPerPhase),
	}
end

--: Push the sky to everyone. Called on phase change and on a slow tick for
--: the clock and late joiners.
function WeatherService.sync()
	Net.fireAll("WeatherSync", payload())
end

function WeatherService.start()
	local lastPhase = WeatherService.phase()
	task.spawn(function()
		while true do
			task.wait(1)
			clock += 1
			local phase = WeatherService.phase()
			local changed = phase ~= lastPhase
			if changed then
				lastPhase = phase
				Debug.count("weather.phases")
				Debug.info(string.format("weather -> %s (hour %.1f)", phase, WeatherService.hour()))
			end
			if changed or clock % 15 == 0 then
				WeatherService.sync()
			end
		end
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		task.delay(3, function()
			if player.Parent then
				Net.fire(player, "WeatherSync", payload())
			end
		end)
	end)

	Debug.info("weather clock started")
end

return WeatherService
