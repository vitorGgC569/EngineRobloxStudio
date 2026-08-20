--!strict
-- Asset creation from inside Studio.
--
-- `AssetService:CreateAssetAsync` is the shortest path this platform has to a
-- real, persistent `rbxassetid://`. It works in **local Studio plugins** and in
-- Open Cloud Luau tasks, needs no Open Cloud key, and accepts an `EditableImage`
-- directly -- which means the engine can author a texture pixel by pixel and
-- publish it without a human touching a file dialog.
--
-- Every gate around it is a real one and is reported rather than assumed:
--
--   * the beta flag "CreateAssetAsync Luau API" must be enabled in Studio
--   * the account (or group) must be 13+ and ID-verified
--   * "Allow Mesh / Image APIs" must be on in Game Settings -> Security
--   * uploads are rate limited to 30 per minute
--   * everything uploaded is moderated exactly as a Studio upload is
--
-- None of those can be worked around from here, and none of them is treated as
-- a failure of the code. They are `BLOCKED` with the specific remedy named,
-- because a pipeline that cannot say *why* it stopped costs more than one that
-- never started.

local AssetService = game:GetService("AssetService")

local Errors = require(script.Parent.Parent.Errors)

local Assets = {}

local function serviceHas(method: string): boolean
	local ok, value = pcall(function()
		return (AssetService :: any)[method]
	end)
	return ok and type(value) == "function"
end

--- What this Studio can actually do, and what stops it.
function Assets.capabilities(): any
	local blockers: { string } = {}

	local canCreateAsset = serviceHas("CreateAssetAsync")
	if not canCreateAsset then
		table.insert(blockers, "AssetService:CreateAssetAsync is unavailable; enable the "
			.. "\"CreateAssetAsync Luau API\" beta in Studio > File > Beta Features")
	end

	local canCreateImage = serviceHas("CreateEditableImageAsync") or serviceHas("CreateEditableImage")
	if not canCreateImage then
		table.insert(blockers, "EditableImage is unavailable; the experience owner must be "
			.. "13+ and ID-verified, and \"Allow Mesh / Image APIs\" must be enabled in "
			.. "Game Settings > Security")
	end

	return {
		createAsset = canCreateAsset,
		createAssetVersion = serviceHas("CreateAssetVersionAsync"),
		editableImage = canCreateImage,
		editableMesh = serviceHas("CreateEditableMeshAsync") or serviceHas("CreateEditableMesh"),
		meshPart = serviceHas("CreateMeshPartAsync"),
		rateLimitPerMinute = 30,
		supportedTypes = { "Image", "Model", "Mesh", "Plugin" },
		available = #blockers == 0,
		blockers = blockers,
	}
end

local function requireNumber(params: { [string]: any }, key: string, minimum: number, maximum: number): number
	local value = params[key]
	if type(value) ~= "number" or value % 1 ~= 0 or value < minimum or value > maximum then
		Errors.raise("E_BAD_PARAMS", string.format(
			"%s must be an integer between %d and %d", key, minimum, maximum
		))
	end
	return value
end

--- Author an image from a pixel buffer and publish it.
---
--- `pixels` arrives as a flat array of 0..255 RGBA bytes, row-major from the top
--- left, because that is what survives JSON transport without inventing an
--- encoding both sides have to agree on separately.
function Assets.createImage(params: { [string]: any }): any
	local capabilities = Assets.capabilities()
	if not capabilities.available then
		return {
			status = "BLOCKED",
			assetId = nil,
			blockers = capabilities.blockers,
		}
	end

	local width = requireNumber(params, "width", 1, 1024)
	local height = requireNumber(params, "height", 1, 1024)
	local name = params.name
	if type(name) ~= "string" or name == "" then
		Errors.raise("E_BAD_PARAMS", "name is required")
	end
	local description = if type(params.description) == "string" then params.description else ""

	local pixels = params.pixels
	if type(pixels) ~= "table" then
		Errors.raise("E_BAD_PARAMS", "pixels must be an array of RGBA bytes")
	end
	local expected = width * height * 4
	if #pixels ~= expected then
		Errors.raise("E_BAD_PARAMS", string.format(
			"pixels has %d entries but %dx%d RGBA needs %d", #pixels, width, height, expected
		))
	end

	local created, image = pcall(function()
		if serviceHas("CreateEditableImageAsync") then
			return (AssetService :: any):CreateEditableImageAsync(nil, { Size = Vector2.new(width, height) })
		end
		return (AssetService :: any):CreateEditableImage({ Size = Vector2.new(width, height) })
	end)
	if not created or image == nil then
		return {
			status = "FAILED",
			reason = if created
				then "the engine returned nil; the Editable* memory budget is exhausted"
				else tostring(image),
		}
	end

	-- `buffer` is what WritePixelsBuffer wants, and building it here rather than
	-- accepting one over the wire keeps the transport plain JSON.
	local payload = buffer.create(expected)
	for index = 1, expected do
		local value = pixels[index]
		if type(value) ~= "number" or value < 0 or value > 255 then
			pcall(function() image:Destroy() end)
			Errors.raise("E_BAD_PARAMS", string.format("pixels[%d] is not a byte", index))
		end
		buffer.writeu8(payload, index - 1, value)
	end

	local written = pcall(function()
		(image :: any):WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), payload)
	end)
	if not written then
		pcall(function() image:Destroy() end)
		return { status = "FAILED", reason = "WritePixelsBuffer rejected the payload" }
	end

	local published, result, extra = pcall(function()
		return (AssetService :: any):CreateAssetAsync(image, Enum.AssetType.Image, {
			Name = name,
			Description = description,
		})
	end)

	-- The editable is released either way. It holds a slot in a budget shared
	-- across the whole experience, so leaking one makes a later, unrelated
	-- creation fail for no visible reason.
	pcall(function() image:Destroy() end)

	if not published then
		local message = tostring(result)
		local status = "FAILED"
		if string.find(message, "429") or string.lower(message):find("rate") then
			status = "RATE_LIMITED"
		elseif string.lower(message):find("permission") or string.find(message, "403") then
			status = "BLOCKED"
		end
		return { status = status, reason = message }
	end

	local assetId = result
	if type(assetId) == "table" then
		assetId = (assetId :: any).AssetId or (assetId :: any).assetId
	end
	if assetId == nil then
		return { status = "FAILED", reason = "upload returned no asset id", detail = tostring(extra) }
	end

	return {
		status = "PUBLISHED",
		assetId = assetId,
		contentId = "rbxassetid://" .. tostring(assetId),
		width = width,
		height = height,
		name = name,
		-- Moderation is asynchronous and outside our control. Saying so here
		-- stops a freshly published id from being mistaken for an approved one.
		moderation = "PENDING",
	}
end

return Assets
