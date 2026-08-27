--!strict
--[[
	VisualIcons — token-keyed icon registry.

	Assets enter the UI by semantic token, never by a raw id scattered in
	code: VisualIcons.get("nav.shop"). Unknown tokens fail loudly -- a
	silent nil becomes a blank image nobody notices until release.

	Where the art comes from
	------------------------

	The tokens below are the vocabulary; they are not the art. Every one of
	them shipped as `rbxassetid://0` for as long as this file has existed,
	which renders as a blank square -- the exact failure the paragraph above
	warns about, committed into the default.

	`ItchIcons` is the generated catalogue of CC0 art published to this
	account, and it is consulted first. A token it knows resolves to real art
	without anybody registering anything; a token it does not falls through to
	whatever a game registered, and then to the placeholder.

	It is optional on purpose. The catalogue is generated output, so a checkout
	that has not run the publisher has no `ItchIcons` at all, and an engine
	that hard-required it would fail to load rather than degrade.

	Why `apply` exists
	------------------

	Most UI packs ship ninety icons as one sprite sheet, and Roblox crops one
	out with `ImageRectOffset` and `ImageRectSize`. So an icon is not always an
	id -- it can be an id plus a rectangle, and `get` returning a string cannot
	say so.

	`get` still returns a string, because callers depend on that. But a caller
	that assigns it to `ImageLabel.Image` and stops will show the *entire
	sheet* where it wanted one glyph. `apply` sets all three properties and is
	what UI code should call.

		VisualIcons.apply(button.Icon, "action.close")
]]

local VisualIcons = {}

--: Resolved once, and absent without complaint. `FindFirstChild` rather than
--: a fixed `require`: the catalogue is generated output, and a checkout that
--: has published nothing does not have it.
local catalogue: any = nil
do
	local module = script.Parent:FindFirstChild("ItchIcons")
	if module and module:IsA("ModuleScript") then
		local ok, loaded = pcall(require, module)
		if ok then
			catalogue = loaded
		end
	end
end

local PLACEHOLDER = "rbxassetid://0"

--[[
	The vocabulary a game may rely on.

	Still the contract, and mostly still placeholders -- these are the tokens
	`get` promises to answer for. What *resolves* them is the catalogue above;
	what this table guarantees is that the name is stable.
]]
local REGISTRY: { [string]: string } = {
	["nav.home"] = PLACEHOLDER,
	["nav.shop"] = PLACEHOLDER,
	["nav.settings"] = PLACEHOLDER,
	["action.close"] = PLACEHOLDER,
	["action.confirm"] = PLACEHOLDER,
	["economy.coin"] = PLACEHOLDER,
	["economy.gem"] = PLACEHOLDER,
	["status.error"] = PLACEHOLDER,
	["status.success"] = PLACEHOLDER,
}

local function fromCatalogue(token: string): any
	if not catalogue then
		return nil
	end
	return catalogue.get(token)
end

function VisualIcons.get(token: string): string
	local drawn = fromCatalogue(token)
	if drawn then
		return drawn.image
	end
	local asset = REGISTRY[token]
	assert(asset, ("unknown icon token %q"):format(token))
	return asset
end

--[[
	Set an image control from a token. Returns whether it found real art.

	The return value is the point. A blank square is the failure this module
	exists to prevent and it is invisible at a glance, so a caller that would
	rather show a text label can ask instead of guessing.
]]
function VisualIcons.apply(label: any, token: string): boolean
	local drawn = fromCatalogue(token)
	if drawn then
		label.Image = drawn.image
		label.ImageRectOffset = drawn.rectOffset
		label.ImageRectSize = drawn.rectSize
		return true
	end

	local asset = REGISTRY[token]
	assert(asset, ("unknown icon token %q"):format(token))
	label.Image = asset
	label.ImageRectOffset = Vector2.zero
	label.ImageRectSize = Vector2.zero
	return asset ~= PLACEHOLDER
end

--[[
	Register art for a token.

	Overwrites a placeholder, refuses to overwrite real art. The original
	refused both -- which meant the nine tokens above, every one a placeholder,
	could never be filled by the game that needed them.
]]
function VisualIcons.register(token: string, assetId: string): ()
	local existing = REGISTRY[token]
	assert(existing == nil or existing == PLACEHOLDER,
		("icon %q already registered"):format(token))
	REGISTRY[token] = assetId
end

--: Every token that resolves to something a player would actually see.
function VisualIcons.resolved(): { string }
	local out: { string } = {}
	for _, token in VisualIcons.tokens() do
		if fromCatalogue(token) or REGISTRY[token] ~= PLACEHOLDER then
			table.insert(out, token)
		end
	end
	return out
end

function VisualIcons.tokens(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for token in REGISTRY do
		if not seen[token] then
			seen[token] = true
			table.insert(out, token)
		end
	end
	if catalogue then
		for _, token in catalogue.tokens() do
			if not seen[token] then
				seen[token] = true
				table.insert(out, token)
			end
		end
	end
	table.sort(out)
	return out
end

function VisualIcons.describe(): { [string]: any }
	return {
		tokens = #VisualIcons.tokens(),
		resolved = #VisualIcons.resolved(),
		catalogue = if catalogue then catalogue.describe() else nil,
	}
end

return VisualIcons
