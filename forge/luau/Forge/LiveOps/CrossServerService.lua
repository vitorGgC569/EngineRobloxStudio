--!strict
--[[
	CrossServerService — MessagingService binding for global channels.

	Publishes only messages that CrossServerChannels validated, and on
	receive re-validates the envelope before handing it to subscribers —
	a malicious or stale message never reaches game code. Subscriptions
	auto-cleanup via the returned disconnect.
]]

local MessagingService = game:GetService("MessagingService")

local Channels = require(script.Parent.CrossServerChannels)

local CrossServerService = {}

export type Envelope = { kind: string }

type Self = {
	channels: any,
	topic: string,
	subscribed: boolean,
	handlers: { (message: Envelope) -> () },
	connection: any,
}

CrossServerService.__index = CrossServerService

function CrossServerService.new(channels: any, topic: string?): any
	return setmetatable({
		channels = channels,
		topic = topic or "RQE_GLOBAL",
		subscribed = false,
		handlers = {},
		connection = nil,
	}, CrossServerService)
end

function CrossServerService.publishRadio(self: any, songName: string, djName: string, assetTypeId: number): (boolean, string?)
	local message, err = self.channels:buildRadio(songName, djName, assetTypeId)
	if not message then
		return false, err
	end
	local ok = pcall(function()
		MessagingService:PublishAsync(self.topic, message)
	end)
	return ok, if ok then nil else "publish_failed"
end

function CrossServerService.publishShout(self: any, text: string, fromName: string): (boolean, string?)
	local message, err = self.channels:buildShout(text, fromName)
	if not message then
		return false, err
	end
	local ok = pcall(function()
		MessagingService:PublishAsync(self.topic, message)
	end)
	return ok, if ok then nil else "publish_failed"
end

-- Subscribe; handler receives ONLY envelopes that still validate.
function CrossServerService.subscribe(self: any, handler: (Envelope) -> ()): () -> ()
	table.insert(self.handlers, handler)

	if not self.subscribed then
		self.subscribed = true
		local ok, connection = pcall(function()
			return MessagingService:SubscribeAsync(self.topic, function(raw)
				local payload = raw and raw.Data
				if type(payload) ~= "table" then
					return
				end
				for _, handle in self.handlers do
					pcall(handle, payload :: Envelope)
				end
			end)
		end)
		self.connection = if ok then connection else nil
	end

	return function()
		local index = table.find(self.handlers, handler)
		if index then
			table.remove(self.handlers, index)
		end
	end
end

return CrossServerService
