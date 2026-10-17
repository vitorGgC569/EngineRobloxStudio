--!strict
-- Native Studio test sessions and device simulation, exposed without UI menus.
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Errors = require(script.Parent.Parent.Errors)
local Serialize = require(script.Parent.Parent.Serialize)

local TestingCommands = {}
local active: any = nil

local function service(name: string): any
	if not RunService:IsStudio() then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT, "native tests require Studio")
	end
	local ok, value = pcall(function() return game:GetService(name :: any) end)
	if not ok then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT, "Studio API unavailable: " .. name)
	end
	return value
end

function TestingCommands.start(params: { [string]: any }): any
	local native = service("StudioTestService")
	if not native.EditModeActive then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT, "start a native test from edit mode")
	end
	if active and (active.status == "STARTING" or active.status == "RUNNING") then
		Errors.raise(Errors.BAD_PARAMS, "a native test is already active")
	end
	local mode = params.mode or "play"
	if mode ~= "play" and mode ~= "run" and mode ~= "multiplayer" then
		Errors.raise(Errors.BAD_PARAMS, "mode must be play, run or multiplayer")
	end
	local players = tonumber(params.players) or 2
	if players % 1 ~= 0 or players < 1 or players > 8 then
		Errors.raise(Errors.BAD_PARAMS, "native test player count must be between 1 and 8")
	end
	local job = { id = HttpService:GenerateGUID(false), mode = mode, status = "STARTING", startedAt = os.time() }
	active = job
	local args = { rqeTestId = job.id, data = params.args or {} }
	-- Execute*Async returns when EndTest runs. A deferred worker keeps the
	-- transport responsive and returns the job identity before the transition.
	task.delay(0.5, function()
		job.status = "RUNNING"
		local ok, result = pcall(function()
			if mode == "multiplayer" then return native:ExecuteMultiplayerTestAsync(players, args) end
			if mode == "run" then return native:ExecuteRunModeAsync(args) end
			return native:ExecutePlayModeAsync(args)
		end)
		job.status = if ok then "FINISHED" else "ERROR"
		job.result = if ok then result else nil
		job.error = if ok then nil else tostring(result)
		job.completedAt = os.time()
	end)
	return table.clone(job)
end

function TestingCommands.status(_params: { [string]: any }): any
	local native = service("StudioTestService")
	if native.EditModeActive then
		return { editModeActive = true, job = if active then table.clone(active) else nil }
	end
	return { editModeActive = false, args = native:GetTestArgs() }
end

function TestingCommands.finish(params: { [string]: any }): any
	local native = service("StudioTestService")
	local args = native:GetTestArgs()
	if type(args) ~= "table" or args.rqeTestId ~= params.testId then
		Errors.raise(Errors.BAD_PARAMS, "testId does not identify this native test")
	end
	task.delay(0.5, function() native:EndTest(params.result or {}) end)
	return { ending = true, testId = params.testId }
end

function TestingCommands.leave(_params: { [string]: any }): any
	local native = service("StudioTestService")
	if not native:CanLeaveTest() then
		return { leaving = false, reason = "StudioTestService reports that this context cannot leave the active test" }
	end
	-- Leave asynchronously so the command response clears the bridge before the
	-- DataModel transition destroys this session.
	task.delay(0.2, function() native:LeaveTest() end)
	return { leaving = true }
end

function TestingCommands.addPlayers(params: { [string]: any }): any
	local native = service("StudioTestService")
	if native.EditModeActive then
		Errors.raise(
			Errors.UNSUPPORTED_CONTEXT,
			"test.add_players requires an active Studio test"
		)
	end
	local count = tonumber(params.count)
	if not count or count % 1 ~= 0 or count < 1 or count > 8 then
		Errors.raise(Errors.BAD_PARAMS, "count must be an integer between 1 and 8")
	end
	native:AddPlayers(count)
	return {
		added = count,
		source = "StudioTestService.AddPlayers",
		args = native:GetTestArgs(),
	}
end

local function studioNetworkSettings(): any
	local ok, value = pcall(function()
		return settings():GetService("NetworkSettings")
	end)
	if not ok or value == nil then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT, "NetworkSettings is unavailable in this Studio build")
	end
	return value
end

function TestingCommands.device(params: { [string]: any }): any
	local native = service("StudioDeviceSimulatorService")
	if params.reset == true then
		native:StopSimulationAsync()
	elseif params.deviceId then
		native:SetDeviceAsync(params.deviceId)
	end
	if params.width ~= nil or params.height ~= nil then
		local width, height = tonumber(params.width), tonumber(params.height)
		if not width or not height or width < 240 or height < 240 or width > 8192 or height > 8192 then
			Errors.raise(Errors.BAD_PARAMS, "supply width and height between 240 and 8192")
		end
		native:SetResolutionAsync(width, height)
	end
	if params.pixelDensity then native:SetPixelDensityAsync(params.pixelDensity) end
	if params.orientation then
		local orientation = Enum.ScreenOrientation[params.orientation]
		if not orientation then Errors.raise(Errors.BAD_PARAMS, "unknown screen orientation") end
		native:SetOrientationAsync(orientation)
	end
	if params.scalingMode then
		local scaling = Enum.DeviceSimulatorScalingMode[params.scalingMode]
		if not scaling then
			Errors.raise(
				Errors.BAD_PARAMS,
				"scalingMode must be ScaleToPhysicalSize, ActualResolution or FitToWindow"
			)
		end
		native:SetScalingModeAsync(scaling)
	end
	if params.memoryMb ~= nil then
		local memory = tonumber(params.memoryMb)
		if not memory or memory < 0 or memory > 262144 then
			Errors.raise(Errors.BAD_PARAMS, "memoryMb must be between 0 and 262144")
		end
		studioNetworkSettings().EmulatedTotalMemoryInMB = memory
	end
	return TestingCommands.deviceStatus({})
end

function TestingCommands.deviceStatus(_params: { [string]: any }): any
	local native = service("StudioDeviceSimulatorService")
	local device = native:GetDeviceAsync()
	local devices = native:GetDeviceListAsync()
	local network = studioNetworkSettings()
	local scalingMode = native:GetScalingModeAsync().Name
	if device == nil or device == "" or device == "default" then
		return {
			active = false,
			devices = devices,
			scalingMode = scalingMode,
			emulatedMemoryMb = network.EmulatedTotalMemoryInMB,
			freeMemoryMb = network.FreeMemoryMBytes,
			source = "StudioDeviceSimulatorService",
		}
	end
	local resolution = native:GetResolutionAsync()
	return { active = true, deviceId = device, devices = devices,
		width = resolution.X, height = resolution.Y, pixelDensity = native:GetPixelDensityAsync(),
		orientation = native:GetOrientationAsync().Name,
		scalingMode = scalingMode,
		emulatedMemoryMb = network.EmulatedTotalMemoryInMB,
		freeMemoryMb = network.FreeMemoryMBytes,
		source = "StudioDeviceSimulatorService" }
end

function TestingCommands.deviceInfo(params: { [string]: any }): any
	local native = service("StudioDeviceSimulatorService")
	local deviceId = params.deviceId
	if type(deviceId) ~= "string" or deviceId == "" then
		Errors.raise(Errors.BAD_PARAMS, "deviceId must be a non-empty string")
	end
	local ok, infoOrError = pcall(function()
		return native:GetDeviceInfoAsync(deviceId)
	end)
	if not ok then
		Errors.raise(
			Errors.NOT_FOUND,
			"StudioDeviceSimulatorService:GetDeviceInfoAsync failed: " .. tostring(infoOrError)
		)
	end
	return {
		deviceId = deviceId,
		info = Serialize.value(infoOrError),
		source = "StudioDeviceSimulatorService.GetDeviceInfoAsync",
	}
end

local NETWORK_PRESETS = {
	zero = {
		inboundLatencyMs = 0, inboundJitterMs = 0, inboundLossPercent = 0,
		outboundLatencyMs = 0, outboundJitterMs = 0, outboundLossPercent = 0,
	},
	ideal_fiber = {
		inboundLatencyMs = 8, inboundJitterMs = 0, inboundLossPercent = 0,
		outboundLatencyMs = 8, outboundJitterMs = 0, outboundLossPercent = 0,
	},
	wired_broadband = {
		inboundLatencyMs = 25, inboundJitterMs = 3, inboundLossPercent = 0,
		outboundLatencyMs = 25, outboundJitterMs = 3, outboundLossPercent = 0,
	},
	home_wifi = {
		inboundLatencyMs = 30, inboundJitterMs = 12, inboundLossPercent = 0.20,
		outboundLatencyMs = 30, outboundJitterMs = 15, outboundLossPercent = 0.30,
	},
	mobile_4g = {
		inboundLatencyMs = 45, inboundJitterMs = 20, inboundLossPercent = 0.40,
		outboundLatencyMs = 55, outboundJitterMs = 30, outboundLossPercent = 0.50,
	},
	bad_3g = {
		inboundLatencyMs = 150, inboundJitterMs = 70, inboundLossPercent = 0.50,
		outboundLatencyMs = 180, outboundJitterMs = 90, outboundLossPercent = 0.50,
	},
}

local function networkSettings(): any
	if not RunService:IsStudio() then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT, "network simulation requires Studio")
	end
	return studioNetworkSettings()
end

local function boundedNumber(value: any, name: string, minimum: number, maximum: number): number?
	if value == nil then
		return nil
	end
	local numeric = tonumber(value)
	if not numeric or numeric < minimum or numeric > maximum then
		Errors.raise(
			Errors.BAD_PARAMS,
			string.format("%s must be between %.2f and %.2f", name, minimum, maximum)
		)
	end
	return numeric
end

function TestingCommands.networkStatus(_params: { [string]: any }): any
	local network = networkSettings()
	return {
		inboundLatencyMs = network.InboundNetworkMinDelayMs,
		inboundJitterMs = network.InboundNetworkJitterMs,
		inboundLossPercent = network.InboundNetworkLossPercent,
		outboundLatencyMs = network.OutboundNetworkMinDelayMs,
		outboundJitterMs = network.OutboundNetworkJitterMs,
		outboundLossPercent = network.OutboundNetworkLossPercent,
		randomizeJoinInstanceOrder = network.RandomizeJoinInstanceOrder,
		emulatedMemoryMb = network.EmulatedTotalMemoryInMB,
		freeMemoryMb = network.FreeMemoryMBytes,
		source = "NetworkSettings",
	}
end

function TestingCommands.network(params: { [string]: any }): any
	local network = networkSettings()
	local requested = {}

	if params.reset == true then
		requested = table.clone(NETWORK_PRESETS.zero)
	elseif params.preset ~= nil then
		if type(params.preset) ~= "string" or NETWORK_PRESETS[params.preset] == nil then
			Errors.raise(
				Errors.BAD_PARAMS,
				"preset must be zero, ideal_fiber, wired_broadband, home_wifi, mobile_4g or bad_3g"
			)
		end
		requested = table.clone(NETWORK_PRESETS[params.preset])
	end

	local overrides = {
		inboundLatencyMs = boundedNumber(params.inboundLatencyMs, "inboundLatencyMs", 0, 1000),
		inboundJitterMs = boundedNumber(params.inboundJitterMs, "inboundJitterMs", 0, 1000),
		inboundLossPercent = boundedNumber(params.inboundLossPercent, "inboundLossPercent", 0, 0.5),
		outboundLatencyMs = boundedNumber(params.outboundLatencyMs, "outboundLatencyMs", 0, 1000),
		outboundJitterMs = boundedNumber(params.outboundJitterMs, "outboundJitterMs", 0, 1000),
		outboundLossPercent = boundedNumber(params.outboundLossPercent, "outboundLossPercent", 0, 0.5),
	}
	for key, value in overrides do
		if value ~= nil then
			requested[key] = value
		end
	end

	local randomizeJoinOrder = params.randomizeJoinInstanceOrder
	if randomizeJoinOrder ~= nil and type(randomizeJoinOrder) ~= "boolean" then
		Errors.raise(Errors.BAD_PARAMS, "randomizeJoinInstanceOrder must be boolean")
	end

	if next(requested) == nil and randomizeJoinOrder == nil then
		Errors.raise(
			Errors.BAD_PARAMS,
			"provide preset, reset=true, randomizeJoinInstanceOrder, or at least one explicit network value"
		)
	end

	local ok, err = pcall(function()
		if requested.inboundLatencyMs ~= nil then
			network.InboundNetworkMinDelayMs = requested.inboundLatencyMs
		end
		if requested.inboundJitterMs ~= nil then
			network.InboundNetworkJitterMs = requested.inboundJitterMs
		end
		if requested.inboundLossPercent ~= nil then
			network.InboundNetworkLossPercent = requested.inboundLossPercent
		end
		if requested.outboundLatencyMs ~= nil then
			network.OutboundNetworkMinDelayMs = requested.outboundLatencyMs
		end
		if requested.outboundJitterMs ~= nil then
			network.OutboundNetworkJitterMs = requested.outboundJitterMs
		end
		if requested.outboundLossPercent ~= nil then
			network.OutboundNetworkLossPercent = requested.outboundLossPercent
		end
		if randomizeJoinOrder ~= nil then
			network.RandomizeJoinInstanceOrder = randomizeJoinOrder
		end
	end)
	if not ok then
		Errors.raise(
			Errors.EXEC,
			"NetworkSettings rejected the requested simulation values: " .. tostring(err)
		)
	end

	local result = TestingCommands.networkStatus({})
	result.preset = params.preset
	result.reset = params.reset == true
	return result
end

return TestingCommands
