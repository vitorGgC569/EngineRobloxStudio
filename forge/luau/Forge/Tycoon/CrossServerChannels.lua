--!strict
--[[
	CrossServerChannels — global radio, shouts and ad rotation.

	Global features ride one MessagingService-style topic contract:
	publish returns the message envelope, receive validates it before
	use. Ads rotate deterministically by time slot; the radio validates
	asset type before broadcasting.
]]

local CrossServerChannels = {}

export type RadioMessage = {
	kind: "radio",
	assetTypeId: number,
	songName: string,
	djName: string,
	at: number,
}

export type ShoutMessage = {
	kind: "shout",
	text: string,
	fromName: string,
	at: number,
}

type Self = {
	radioCostCurrency: string?,
	radioCostAmount: number?,
	allowedAssetTypeId: number,
	shoutMaxLength: number,
	ads: { string },
	adSlotSeconds: number,
	clock: () -> number,
}

CrossServerChannels.__index = CrossServerChannels

function CrossServerChannels.new(config: {
	allowedAssetTypeId: number?,
	shoutMaxLength: number?,
	ads: { string }?,
	adSlotSeconds: number?,
	clock: (() -> number)?,
}): Self
	return setmetatable({
		radioCostCurrency = nil,
		radioCostAmount = 0,
		allowedAssetTypeId = config.allowedAssetTypeId or 3, -- rbxassetid audio
		shoutMaxLength = config.shoutMaxLength or 140,
		ads = config.ads or {},
		adSlotSeconds = config.adSlotSeconds or 300,
		clock = config.clock or os.time,
	}, CrossServerChannels)
end

-- Only whitelisted asset types may broadcast globally.
function CrossServerChannels.buildRadio(self: Self, songName: string, djName: string, assetTypeId: number): (RadioMessage?, string?)
	if assetTypeId ~= self.allowedAssetTypeId then
		return nil, "asset_type_not_allowed"
	end
	if #songName == 0 or #songName > 80 then
		return nil, "invalid_song_name"
	end
	return { kind = "radio", assetTypeId = assetTypeId, songName = songName, djName = djName, at = self.clock() }, nil
end

-- Text is already chat-filtered upstream (server responsibility).
function CrossServerChannels.buildShout(self: Self, text: string, fromName: string): (ShoutMessage?, string?)
	if #text == 0 or #text > self.shoutMaxLength then
		return nil, "invalid_length"
	end
	return { kind = "shout", text = text, fromName = fromName, at = self.clock() }, nil
end

-- Deterministic rotation: same slot index picks the same ad everywhere.
function CrossServerChannels.currentAd(self: Self): string?
	if #self.ads == 0 then
		return nil
	end
	local slot = math.floor(self.clock() / self.adSlotSeconds)
	return self.ads[(slot % #self.ads) + 1]
end

return CrossServerChannels
