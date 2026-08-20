--!strict
-- HTTP long-poll transport.
--
-- Studio cannot accept inbound connections, so the plugin drives the loop:
-- handshake, then poll -> execute -> report, forever. Plugins may use
-- HttpService regardless of the place's HttpEnabled setting, which is what
-- makes this work without asking the developer to change game settings.

local HttpService = game:GetService("HttpService")

local Config = require(script.Parent.Config)

local Transport = {}
Transport.__index = Transport

-- Stable for the lifetime of this plugin instance. The hub uses it to evict a
-- previous session from the same Studio when the context changes, so an agent
-- never routes a command to a session that stopped polling.
local CLIENT_ID = HttpService:GenerateGUID(false)

export type Transport = typeof(setmetatable({} :: {
	hubUrl: string,
	bearerToken: string,
	session: string?,
	connected: boolean,
	lastError: string?,
}, Transport))

function Transport.new(hubUrl: string, bearerToken: string): Transport
	return setmetatable({
		hubUrl = hubUrl,
		bearerToken = bearerToken,
		session = nil,
		connected = false,
		lastError = nil,
	}, Transport) :: any
end

function Transport:post(path: string, payload: { [string]: any }, timeout: number?): (boolean, any)
	local body
	local encodeOk, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if not encodeOk then
		return false, "could not encode request: " .. tostring(encoded)
	end
	body = encoded

	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }
	if self.bearerToken ~= "" then
		headers["Authorization"] = "Bearer " .. self.bearerToken
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = self.hubUrl .. path,
			Method = "POST",
			Headers = headers,
			Body = body,
		})
	end)

	if not ok then
		return false, tostring(response)
	end
	if not response.Success then
		return false, string.format("HTTP %d %s: %s", response.StatusCode, response.StatusMessage, string.sub(response.Body or "", 1, 300))
	end

	local decodeOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decodeOk then
		return false, "could not decode response: " .. tostring(decoded)
	end
	return true, decoded
end

--- Perform the handshake and remember the session id.
function Transport:connect(context: string): (boolean, string?)
	local ok, result = self:post("/bridge/hello", {
		protocol = Config.PROTOCOL,
		clientId = CLIENT_ID,
		pluginVersion = Config.PLUGIN_VERSION,
		studioVersion = (function()
			local versionOk, value = pcall(function()
				return version()
			end)
			return if versionOk then value else "unknown"
		end)(),
		placeName = game.Name,
		placeId = game.PlaceId,
		context = context,
	})

	if not ok then
		self.connected = false
		self.lastError = tostring(result)
		return false, self.lastError
	end

	if type(result) ~= "table" or result.session == nil then
		self.connected = false
		self.lastError = "hub did not return a session id"
		return false, self.lastError
	end

	self.session = result.session
	self.connected = true
	self.lastError = nil
	return true, result.session
end

--- Ask the hub for work. Returns the command list (possibly empty).
function Transport:poll(): (boolean, { any })
	local ok, result = self:post("/bridge/poll", {
		session = self.session,
		maxBatch = Config.MAX_BATCH,
	})
	if not ok then
		self.lastError = tostring(result)
		return false, {}
	end
	if type(result) ~= "table" then
		return false, {}
	end
	return true, result.commands or {}
end

function Transport:report(results: { any }): boolean
	if #results == 0 then
		return true
	end
	local ok, err = self:post("/bridge/result", {
		session = self.session,
		results = results,
	})
	if not ok then
		self.lastError = tostring(err)
	end
	return ok
end

function Transport:emit(events: { any }): boolean
	if #events == 0 then
		return true
	end
	local ok = self:post("/bridge/event", { session = self.session, events = events })
	return ok
end

function Transport:disconnect(): ()
	self.connected = false
	self.session = nil
end

return Transport
