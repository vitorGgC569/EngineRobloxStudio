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

	--[[
		Presence is not permission.

		`serviceHas` answers whether the method is on the service, and on a
		current Studio `CreateAssetAsync` is always there -- then refuses the
		call with "CreateAssetAsync and CreateAssetVersionAsync are not
		available yet" until the beta is switched on. So this reported
		`available = true`, `blockers = {}`, and the first real upload failed
		anyway.

		A capability report that cannot tell "present" from "usable" is worse
		than one that admits it: the whole point of this surface is that a
		pipeline which cannot say why it stopped costs more than one that never
		started. The only way to know is to call it, which has side effects, so
		this says so rather than guessing.
	]]
	local betaUnknown = canCreateAsset

	return {
		createAsset = canCreateAsset,
		createAssetVersion = serviceHas("CreateAssetVersionAsync"),
		--: True when the method exists but the beta gate has not been observed.
		--: The caller finds out on the first upload, and that is the honest
		--: place to find out.
		createAssetGateUnverified = betaUnknown,
		betaHint = if betaUnknown
			then "if an upload returns 'not available yet', enable the "
				.. "\"CreateAssetAsync Luau API\" beta in Studio > File > Beta Features"
			else "",
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

	--[[
		A blank canvas comes from `CreateEditableImage`, not from the Async one.

		`CreateEditableImageAsync(content, ...)` *loads* an existing image and
		its first argument is a `Content`. This called it with `nil` whenever
		the method existed -- which is always on a current Studio -- so every
		upload this project ever attempted died on "Argument 1 missing or nil"
		before it reached the network.

		That is why `assets.author.publish` sat at STATICALLY_VALIDATED with the
		note "no live publish has been executed": not an account gate, not a
		missing key. A wrong overload, never run once.
	]]
	local created, image = pcall(function()
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

	--[[
		`CreateAssetAsync` returns the *result* first and the id second.

		This read the first value as the asset id, and the first upload that
		ever completed came back with `assetId = nil` and
		`contentId = "rbxassetid://Enum.CreateAssetResult.Success"` -- an
		enum, formatted as if it were a number, in the field every caller would
		use to reference the asset. The upload worked; the answer was unusable.

		Written from the two values as they actually arrive, and neither is
		trusted to be in a particular slot: whichever of them is a number is the
		id, whichever is a `CreateAssetResult` is the outcome. That survives
		Roblox reordering them again.
	]]
	local assetId, outcome = nil, nil
	for _, value in { result, extra } do
		if type(value) == "number" then
			assetId = value
		elseif typeof(value) == "EnumItem" then
			outcome = value
		elseif type(value) == "table" then
			assetId = assetId or (value :: any).AssetId or (value :: any).assetId
		elseif type(value) == "string" and tonumber(value) then
			assetId = assetId or tonumber(value)
		end
	end

	if outcome ~= nil and outcome ~= Enum.CreateAssetResult.Success then
		return { status = "FAILED", reason = tostring(outcome) }
	end
	if assetId == nil then
		return {
			status = "FAILED",
			reason = "upload reported success but returned no asset id",
			detail = string.format("%s / %s", tostring(result), tostring(extra)),
		}
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

-- ============================== toolbox insert ==============================
--[[
	Pull one public model out of the Roblox library, into this Studio.

	Why this has to run here
	-----------------------

	Roblox's toolbox search answers unauthenticated -- the engine can find any
	free model by keyword without a credential. Downloading one is a different
	story: `assetdelivery` returns 401 to an Open Cloud API key on every route
	tried (v1 `asset`, v2 `assetId`, `cloud/v2/assets`), because model content
	is gated on a browser session rather than on a key. Open Cloud will hand
	over the name, the creator and the moderation state, and not the bytes.

	Studio is the one client on this machine that is already signed in. So the
	fetch happens here, and the agent gets to see what arrived rather than
	guessing from a name -- which matters, because toolbox search results are
	largely SEO spam and a model's title says nothing about whether it contains
	a mesh, a script, or four thousand parts.

	Edit context only. `InsertService:LoadAsset` in a running place does not
	fail when it is unhappy, it hangs -- the `Catalog` module carries a long
	comment about the afternoon that cost -- and a play session is exactly
	where nobody can afford a stall.
]]
local InsertService = game:GetService("InsertService")
local RunService = game:GetService("RunService")

--: Where fetched models are parked. Named so a human opening the place can
--: see immediately that these came from the library and are not authored here.
local IMPORT_FOLDER = "RQEToolboxImports"

function Assets.insert(params: { [string]: any }): any
	local assetId = tonumber(params.assetId)
	if not assetId or assetId <= 0 then
		Errors.raise(Errors.BAD_PARAMS, "assetId must be a positive number")
	end

	if RunService:IsRunning() then
		Errors.raise(Errors.UNSUPPORTED_CONTEXT,
			"assets.insert is edit-only: LoadAsset hangs rather than fails in a "
			.. "running place, and a hung insert stalls the whole session")
	end

	local finished, ok, result = false, false, nil
	task.spawn(function()
		ok, result = pcall(function()
			return InsertService:LoadAsset(assetId)
		end)
		finished = true
	end)

	-- Bounded for the same reason `Catalog.loadPack` is bounded: this call is
	-- the one that does not come back.
	local deadline = os.clock() + (tonumber(params.timeout) or 20)
	while not finished and os.clock() < deadline do
		task.wait(0.05)
	end

	if not finished then
		Errors.raise(Errors.EXEC,
			string.format("asset %d did not answer within the timeout", assetId))
	end
	if not ok or typeof(result) ~= "Instance" then
		Errors.raise(Errors.NOT_FOUND,
			string.format("asset %d could not be loaded: %s", assetId, tostring(result)))
	end

	local container = result :: Instance
	local roots = container:GetChildren()

	--[[
		Describe what came in, in the terms that decide whether it is usable.

		A name is worthless here. What matters is: how many parts (a prop or
		somebody's whole level), does it carry scripts (arrives disabled and
		sandboxed, and is somebody else's system), and does it contain anything
		that cannot be parented into a kit.
	]]
	local counts: { [string]: number } = {}
	local parts, scripts = 0, 0
	for _, root in roots do
		for _, item in root:GetDescendants() do
			local class = item.ClassName
			counts[class] = (counts[class] or 0) + 1
			if item:IsA("BasePart") then
				parts += 1
			elseif item:IsA("LuaSourceContainer") then
				scripts += 1
			end
		end
	end

	local parent = game:GetService("ServerStorage"):FindFirstChild(IMPORT_FOLDER)
	if not parent then
		local folder = Instance.new("Folder")
		folder.Name = IMPORT_FOLDER
		folder.Parent = game:GetService("ServerStorage")
		parent = folder
	end

	local names = {}
	for _, root in roots do
		root.Parent = parent
		table.insert(names, root.Name)
	end
	container:Destroy()

	return {
		assetId = assetId,
		roots = names,
		parts = parts,
		scripts = scripts,
		classes = counts,
		path = parent:GetFullName(),
	}
end

-- ============================== verification ================================
--[[
	Do these asset ids actually resolve, right now, in this Studio?

	Why this is a command and not a script the engine sends
	------------------------------------------------------

	It used to be Luau text pushed through `bridge.exec`, which needs
	`loadstring` -- and `loadstring` is off. So `forge assets verify` answered
	"0 of 20 load" for every id including Roblox's own built-in fonts and
	textures, and worse, *wrote that down*: twenty assets recorded as failing
	that had never been tested at all. A verifier that invents failures is
	worse than none, because the registry it writes is then trusted.

	Living here, it needs no `loadstring` and no place setting.

	An invented id is the one mistake every other gate in this repository
	misses. It compiles, it sits in a well-formed table, no test asserts on it,
	and rojo writes it into the place without comment. The first thing that
	disagrees is a player's speakers.
]]
local ContentProvider = game:GetService("ContentProvider")

function Assets.verify(params: { [string]: any }): any
	local refs = params.refs
	if type(refs) ~= "table" or #refs == 0 then
		Errors.raise(Errors.BAD_PARAMS, "refs must be a non-empty array of asset ids")
	end

	--[[
		`ContentProvider:PreloadAsync` reports the outcome, per asset, by type.

		Three probe designs came before this one and each failed for the same
		underlying reason -- the probe could not represent the asset, so a
		perfectly good id looked missing:

		  * a `Sound` alone failed all 162 images, exactly as it had once failed
		    all four fonts;
		  * a `Decal` has no `IsLoaded` at all;
		  * an `ImageLabel` in a disabled `ScreenGui` never renders, and Roblox
		    does not fetch what it will not draw, so `IsLoaded` stayed false for
		    images that were approved and were visibly working in the game.

		`PreloadAsync` asks for the content directly and hands back an
		`AssetFetchStatus` per id. It does not care what the asset is, which
		removes the guessing that produced every one of those false negatives.

		It blocks, so it runs in its own thread against a deadline: a batch that
		stalls must not take the bridge down with it.
	]]
	local out: { [string]: any } = {}
	local holder = Instance.new("Folder")
	holder.Name = "RQEAssetProbe"
	holder.Parent = workspace

	local probes: { Instance } = {}
	local byContent: { [string]: string } = {}

	for _, raw in refs do
		local ref = tostring(raw)
		if string.find(ref, "/fonts/", 1, true) then
			--: A font family is not fetchable content; constructing one is the
			--: only check available, and it is the check that matters.
			local ok, err = pcall(function()
				local label = Instance.new("TextLabel")
				label.FontFace = Font.new(ref)
				label:Destroy()
			end)
			out[ref] = { ok = ok, kind = "font", error = ok and nil or string.sub(tostring(err), 1, 160) }
		else
			--[[
				Both probes, every time, and any success counts.

				Falling back to a Decal only when the Sound *assignment* threw
				looked like it removed the guess and did not: `SoundId` accepts
				any content string and fails later, at fetch. So every image
				stayed on the audio probe and came back `Failure` -- approved
				ids, visibly rendering in the game, reported broken.

				An id does not say what it is. Asking both and taking either is
				the only answer that does not require knowing in advance.
			]]
			local sound = Instance.new("Sound")
			pcall(function()
				sound.SoundId = ref
			end)
			sound.Parent = holder
			table.insert(probes, sound)

			local decal = Instance.new("Decal")
			pcall(function()
				decal.Texture = ref
			end)
			decal.Parent = holder
			table.insert(probes, decal)

			byContent[ref] = ref
			out[ref] = { ok = false, kind = "unknown", error = "no answer from PreloadAsync" }
		end
	end

	local finished = false
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(probes, function(contentId, status)
				local ref = byContent[tostring(contentId)]
				if ref then
					local good = status == Enum.AssetFetchStatus.Success
					--: Two probes report for the same id; one success is enough,
					--: and a later failure must not overwrite an earlier pass.
					local prior = out[ref]
					if not (prior and prior.ok) then
						out[ref] = {
							ok = good,
							kind = "content",
							status = tostring(status),
							error = good and nil or tostring(status),
						}
					end
				end
			end)
		end)
		finished = true
	end)

	local deadline = os.clock() + (tonumber(params.timeout) or 30)
	while not finished and os.clock() < deadline do
		task.wait(0.15)
	end

	holder:Destroy()

	local passing = 0
	for _, row in out do
		if row.ok then
			passing += 1
		end
	end
	return { assets = out, count = #refs, passing = passing, complete = finished }
end

return Assets
