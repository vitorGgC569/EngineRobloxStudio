--!strict
--[[
	VisualIcons — token-keyed icon registry.

	Assets enter the UI by semantic token, never by a raw id scattered in
	code: VisualIcons.get("nav.shop"). Unknown tokens fail loudly -- a
	silent nil becomes a blank image nobody notices until release.
]]

local VisualIcons = {}

local REGISTRY: { [string]: string } = {
	["nav.home"] = "rbxassetid://0",
	["nav.shop"] = "rbxassetid://0",
	["nav.settings"] = "rbxassetid://0",
	["action.close"] = "rbxassetid://0",
	["action.confirm"] = "rbxassetid://0",
	["economy.coin"] = "rbxassetid://0",
	["economy.gem"] = "rbxassetid://0",
	["status.error"] = "rbxassetid://0",
	["status.success"] = "rbxassetid://0",
}

function VisualIcons.get(token: string): string
	local asset = REGISTRY[token]
	assert(asset, ("unknown icon token %q"):format(token))
	return asset
end

function VisualIcons.register(token: string, assetId: string): ()
	assert(not REGISTRY[token], ("icon %q already registered"):format(token))
	REGISTRY[token] = assetId
end

function VisualIcons.tokens(): { string }
	local out: { string } = {}
	for token in REGISTRY do
		table.insert(out, token)
	end
	table.sort(out)
	return out
end

return VisualIcons
