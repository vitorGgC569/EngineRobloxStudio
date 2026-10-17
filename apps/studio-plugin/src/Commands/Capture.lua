--!strict
-- Background screenshot capture through Studio's plugin-only capture API.
--
-- Unlike the legacy Windows window-grab path, this command does not require
-- Roblox Studio to own the foreground. The image bytes come directly from
-- StudioCaptureService and are returned over the bridge as base64.

local EncodingService = game:GetService("EncodingService")
local StudioCaptureService = game:GetService("StudioCaptureService")

local Errors = require(script.Parent.Parent.Errors)

local CaptureCommands = {}

local function vector2(value: Vector2): { number }
	return { value.X, value.Y }
end

local function stringifyErrors(values: { any }): { string }
	local out = {}
	for _, value in ipairs(values) do
		table.insert(out, tostring(value))
	end
	return out
end

function CaptureCommands.permission(_params: { [string]: any }): any
	local alreadyGranted = StudioCaptureService:CanCaptureScreenshot()
	if alreadyGranted then
		return {
			granted = true,
			alreadyGranted = true,
			canCapture = true,
		}
	end

	local ok, grantedOrError = pcall(function()
		return StudioCaptureService:RequestScreenshotPermissionAsync()
	end)
	if not ok then
		Errors.raise(
			Errors.EXEC,
			"StudioCaptureService:RequestScreenshotPermissionAsync failed: "
				.. tostring(grantedOrError)
		)
	end

	local canCapture = StudioCaptureService:CanCaptureScreenshot()
	return {
		granted = grantedOrError == true,
		alreadyGranted = false,
		canCapture = canCapture,
	}
end

function CaptureCommands.background(params: { [string]: any }): any
	local canCapture = StudioCaptureService:CanCaptureScreenshot()
	if not canCapture then
		return {
			supported = true,
			canCapture = false,
			permissionRequired = true,
			message = "StudioCaptureService cannot capture yet; permission may be required",
		}
	end

	local options: { [string]: any } = {}
	if params.includeUi ~= nil then
		options.UICaptureMode = if params.includeUi == true
			then Enum.UICaptureMode.All
			else Enum.UICaptureMode.None
	end

	local ok, captureOrError = pcall(function()
		return StudioCaptureService:CaptureScreenshot(options)
	end)
	if not ok then
		Errors.raise(
			Errors.EXEC,
			"StudioCaptureService:CaptureScreenshot failed: " .. tostring(captureOrError)
		)
	end

	local capture = captureOrError :: StudioScreenshotCapture
	local errors = stringifyErrors(capture:GetErrors())
	local bufferStatus = tostring(capture.BufferStatus)
	local format = tostring(capture.BufferFormat)

	local bufferOk, rawOrError = pcall(function()
		return capture:GetBuffer()
	end)
	if not bufferOk then
		Errors.raise(
			Errors.EXEC,
			"StudioScreenshotCapture:GetBuffer failed: " .. tostring(rawOrError),
			{
				bufferStatus = bufferStatus,
				bufferFormat = format,
				errors = errors,
			}
		)
	end

	local raw = rawOrError :: buffer
	local encoded = EncodingService:Base64Encode(raw)

	return {
		supported = true,
		canCapture = true,
		permissionRequired = false,
		bufferStatus = bufferStatus,
		bufferFormat = format,
		resolution = vector2(capture.Resolution),
		originalSize = vector2(capture.OriginalSize),
		position = vector2(capture.Position),
		uiCaptureMode = tostring(capture.UICaptureMode),
		bytes = buffer.len(raw),
		base64Bytes = buffer.len(encoded),
		dataBase64 = buffer.tostring(encoded),
		errors = errors,
	}
end

return CaptureCommands
