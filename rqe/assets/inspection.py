"""Open an inserted model and look inside it, before anything uses it.

Why the search metadata is not enough
------------------------------------

`toolbox.assess` filters on what Roblox reports about an asset. That is a real
filter and it is a claim by the uploader plus a few counts. It cannot tell you
that the model's parts are unanchored, that its "1 script" is a loader for code
held somewhere else, or that a prop billed as furniture arrives 900 studs wide.

This is the stage that reads the thing itself. It runs after `assets.insert`
has put the model in ServerStorage and before any of it is copied into a game.

The one check this exists for
-----------------------------

`require(123456789)`. A model containing that fetches and runs code from an
asset its author controls, at runtime, on every server -- after the model was
reviewed, and changeable afterwards without touching the model. It is the
platform's oldest backdoor and it is three tokens long.

Roblox inserts scripts disabled and sandboxed, which is a real mitigation and
not a solution: the danger is a developer enabling one to find out what it
does. So the scan reads source and reports, and the caller decides.

What a finding here means
-------------------------

`blocked` is for what should never be enabled. `suspicious` is for what needs a
person to read it -- plenty of legitimate models use HttpService or build
RemoteEvents. The distinction is deliberate: a scanner that flags everything is
a scanner people learn to click past.
"""

from __future__ import annotations

import json
import hashlib
import secrets
from typing import Any
from ..workspace import hub_url

#: Where `assets.insert` parks what it pulls in. Named by the plugin, not here;
#: the two have to agree and only one of them gets to decide.
IMPORT_FOLDER = "RQEToolboxImports"

#: Patterns read out of script sources.
#:
#: **Lua patterns, not regular expressions.** That is a real constraint and not
#: a stylistic one: these run inside Studio, where `string.find` is what exists.
#: There is no alternation, so `a|b` is two rules; there are no `{n,m}`
#: quantifiers, so "a run of 200 characters" cannot be written here at all and
#: is measured separately below.
#:
#: Ordered most to least severe. Each is (name, pattern, severity, why).
SOURCE_PATTERNS: tuple[tuple[str, str, str, str], ...] = (
    ("require-by-id", r"require%s*%(%s*%d%d%d%d+", "blocked",
     "fetches and runs code from an asset the author controls, after review"),
    ("loadstring", r"loadstring%s*%(", "blocked",
     "compiles a string at runtime; nothing legitimate in a prop needs it"),
    ("getfenv", r"getfenv%s*%(", "blocked",
     "reaches into another scope's environment; a classic obfuscation step"),
    ("setfenv", r"setfenv%s*%(", "blocked",
     "replaces a function's environment; used to hide what a call resolves to"),
    ("http-request", r"HttpService", "suspicious",
     "talks to a server off-platform; legitimate in tools, not in a prop"),
    ("prompt-purchase", r"PromptProductPurchase", "suspicious",
     "can charge the player; check whose product id it names"),
    ("prompt-purchase-asset", r"PromptPurchase", "suspicious",
     "can charge the player; check whose asset id it names"),
    ("name-check", r"%.Name%s*==%s*[\"']", "suspicious",
     "compares a player name; the shape of an owner-only backdoor"),
    ("remote-created", r"Instance%.new%s*%(%s*[\"']Remote", "suspicious",
     "creates its own remote; check what it accepts from clients"),
)

#: The obfuscation check, which no Lua pattern can express.
#:
#: An encoded payload shows up as one enormous unbroken run of base64-ish
#: characters. Lua has no counted repetition, so the run is measured with
#: `string.find` in a loop instead. 200 is comfortably above any real identifier
#: or URL and well below a minified library, which is the other thing that looks
#: like this.
BLOB_RUN = 200

#: A model wider than this is almost certainly not the prop it claims to be.
#: Not a hard failure -- some are legitimately enormous -- but it is the single
#: most common surprise when a search result reaches a world.
LARGE_STUDS = 200

LUA = """
local ServerStorage = game:GetService("ServerStorage")
local target = ServerStorage:FindFirstChild("@@FOLDER@@")
if not target then return { error = "no import folder" } end

local root = target:FindFirstChild("@@ROOT@@")
if not root then return { error = "no such root: @@ROOT@@" } end

local patterns = {@@PATTERNS@@}

local report = {
	classes = {}, parts = 0, unanchored = 0, scripts = 0,
	meshes = {}, textures = {}, findings = {}, sources = {},
	totalTriangles = 0,
}

local minV, maxV = nil, nil
local function grow(part)
	local pos, size = part.Position, part.Size
	local half = size * 0.5
	local low, high = pos - half, pos + half
	minV = minV and Vector3.new(math.min(minV.X, low.X), math.min(minV.Y, low.Y),
		math.min(minV.Z, low.Z)) or low
	maxV = maxV and Vector3.new(math.max(maxV.X, high.X), math.max(maxV.Y, high.Y),
		math.max(maxV.Z, high.Z)) or high
end

local items = root:GetDescendants()
table.insert(items, root)

for _, item in items do
	local class = item.ClassName
	report.classes[class] = (report.classes[class] or 0) + 1

	if item:IsA("BasePart") then
		report.parts += 1
		if not item.Anchored then report.unanchored += 1 end
		grow(item)
		if item:IsA("MeshPart") then
			if item.MeshId ~= "" then report.meshes[item.MeshId] = true end
			if item.TextureID ~= "" then report.textures[item.TextureID] = true end
		end
	elseif item:IsA("Decal") or item:IsA("Texture") then
		if item.Texture ~= "" then report.textures[item.Texture] = true end
	elseif item:IsA("LuaSourceContainer") then
		report.scripts += 1
		local ok, source = pcall(function() return item.Source end)
		if not ok then
			table.insert(report.findings, {
				name = "unreadable", severity = "suspicious",
				where = item:GetFullName(), detail = "source could not be read",
			})
		else
			report.sources[item:GetFullName()] = string.sub(source, 1, 400)
			for _, rule in patterns do
				if string.find(source, rule.pattern) then
					table.insert(report.findings, {
						name = rule.name, severity = rule.severity,
						where = item:GetFullName(), detail = rule.why,
					})
				end
			end

			--: The obfuscation check. Lua patterns have no counted repetition,
			--: so the longest base64-ish run is measured rather than matched.
			local longest, cursor = 0, 1
			while true do
				local from, to = string.find(source, "[%w+/=]+", cursor)
				if not from then break end
				longest = math.max(longest, to - from + 1)
				cursor = to + 1
			end
			if longest >= @@BLOB@@ then
				table.insert(report.findings, {
					name = "obfuscated-blob", severity = "suspicious",
					where = item:GetFullName(),
					detail = string.format(
						"an unbroken %d-character literal; usually encoded source", longest),
				})
			end
		end
	end
end

local meshList, textureList = {}, {}
for id in report.meshes do table.insert(meshList, id) end
for id in report.textures do table.insert(textureList, id) end
report.meshes, report.textures = meshList, textureList

if minV and maxV then
	local span = maxV - minV
	report.size = { x = span.X, y = span.Y, z = span.Z }
end
return report
"""


def _call(source: str, timeout: int = 90) -> dict[str, Any]:
    from ..hub.client import StudioBridge

    bridge = StudioBridge(hub_url(), allow_arbitrary=True)
    run_id = f"asset-inspection-{secrets.token_hex(8)}"
    with bridge.lease_scope(
        run_id=run_id,
        agent_id="rqe.assets.inspection",
        build_id=hashlib.sha256(source.encode("utf-8")).hexdigest(),
        context="edit",
        ttl_seconds=min(max(float(timeout) + 15.0, 30.0), 300.0),
        pin_timeout=min(float(timeout), 300.0),
        release_required=False,
    ):
        result = bridge.call(
            "bridge.exec",
            {"source": source, "chunkName": "rqe.asset-inspection"},
            timeout=float(timeout),
        )
    return result["returned"]


INSERT_LUA = """
local ServerStorage = game:GetService("ServerStorage")
local id = @@ASSET@@

--[[
	`game:GetObjects`, not `InsertService:LoadAsset`.

	LoadAsset refuses any asset the signed-in user does not own -- "User is not
	authorized to access Asset" -- and that covers free public models. Measured
	across 36 of them spanning 2015 to 2023: LoadAsset fetched none, GetObjects
	fetched 33. The three it missed answer HTTP 403, which is a creator
	restricting distribution rather than an API limitation.

	Driven through `bridge.exec` rather than the plugin's `assets.insert`
	because Studio only loads plugins at startup: a plugin fix is not live until
	somebody restarts, and this path is current the moment it is written.
]]
local ok, roots = pcall(function()
	return game:GetObjects("rbxassetid://" .. id)
end)
if not ok then
	return { error = string.sub(tostring(roots), 1, 200) }
end
if type(roots) ~= "table" or #roots == 0 then
	return { error = "asset loaded but contained nothing" }
end

local parent = ServerStorage:FindFirstChild("@@FOLDER@@")
if not parent then
	parent = Instance.new("Folder")
	parent.Name = "@@FOLDER@@"
	parent.Parent = ServerStorage
end

--[[
	Geometry first.

	`GetObjects` hands back everything the asset contains at top level, and for
	plenty of models that includes a `ThumbnailCamera` the uploader left in, or
	a loose `Script`. A caller taking `roots[1]` then asks a Camera for its
	extents and a Script for its pivot -- which is exactly how two bakes failed
	before this sort existed.

	Stable within each group, so the author's own ordering survives.
]]
local ordered = {}
for _, root in roots do table.insert(ordered, root) end
table.sort(ordered, function(a, b)
	local aGeom = a:IsA("Model") or a:IsA("BasePart")
	local bGeom = b:IsA("Model") or b:IsA("BasePart")
	if aGeom ~= bGeom then
		return aGeom
	end
	return false
end)
roots = ordered

local names, parts, scripts = {}, 0, 0
for _, root in roots do
	--: A name collision would leave two models sharing a name and the
	--: inspector reaching the wrong one. Whatever is already there under this
	--: id was put there by an earlier run of this same call.
	local existing = parent:FindFirstChild(root.Name)
	if existing then existing:Destroy() end

	root.Parent = parent
	table.insert(names, root.Name)
	if root:IsA("BasePart") then parts += 1 end
	for _, item in root:GetDescendants() do
		if item:IsA("BasePart") then parts += 1
		elseif item:IsA("LuaSourceContainer") then scripts += 1 end
	end
end

return { assetId = id, roots = names, parts = parts, scripts = scripts,
         path = parent:GetFullName() }
"""


def insert(asset_id: int | str, timeout: int = 60) -> dict[str, Any]:
    """Pull one asset into ServerStorage. Edit sessions only.

    Raises with Roblox's own message on refusal, because the message is the
    useful part: HTTP 403 means the creator restricted distribution, and that
    is a different problem from a bad id.
    """
    source = (INSERT_LUA
              .replace("@@ASSET@@", str(int(asset_id)))
              .replace("@@FOLDER@@", IMPORT_FOLDER))
    result = _call(source, timeout=timeout)
    if result.get("error"):
        raise RuntimeError(f"asset {asset_id}: {result['error']}")
    return result


def _lua_patterns() -> str:
    rows = []
    for name, pattern, severity, why in SOURCE_PATTERNS:
        escaped = pattern.replace("\\", "\\\\").replace('"', '\\"')
        rows.append(
            f'{{ name = "{name}", pattern = "{escaped}", '
            f'severity = "{severity}", why = "{why}" }}')
    return ", ".join(rows)


def inspect(root_name: str, folder: str = IMPORT_FOLDER) -> dict[str, Any]:
    """Walk an already-inserted model and report what is actually in it.

    Built by token substitution rather than by any of Python's formatting: the
    Lua body is made of `%` (patterns) and `{}` (tables), which are exactly the
    two characters `%`-formatting and `str.format` claim.
    """
    source = (LUA
              .replace("@@FOLDER@@", folder)
              .replace("@@ROOT@@", root_name)
              .replace("@@PATTERNS@@", _lua_patterns())
              .replace("@@BLOB@@", str(BLOB_RUN)))
    return _call(source)


def judge(report: dict[str, Any], role: str = "prop") -> dict[str, Any]:
    """Turn an inspection into a verdict, with the reasons kept separate.

    `blocked` findings are a refusal on their own. Everything else accumulates
    as something for a person to read, because the alternative -- a single
    pass/fail -- teaches people to stop reading the reasons.
    """
    blocked = [f for f in report.get("findings", []) if f["severity"] == "blocked"]
    suspicious = [f for f in report.get("findings", []) if f["severity"] == "suspicious"]
    notes: list[str] = []

    size = report.get("size") or {}
    widest = max(size.get("x", 0), size.get("y", 0), size.get("z", 0))
    if widest > LARGE_STUDS:
        notes.append(f"{widest:.0f} studs across; larger than a prop")

    unanchored = int(report.get("unanchored") or 0)
    if unanchored:
        #: Every unanchored part is a physics body the server simulates for as
        #: long as the model exists. A decorative model has no reason to have
        #: any, and a hundred of them is a frame-rate problem that arrives
        #: quietly a week later.
        notes.append(f"{unanchored} unanchored parts; each one is simulated")

    parts = int(report.get("parts") or 0)
    if role == "scatter" and parts > 12:
        notes.append(f"{parts} parts; heavy for something placed by the hundred")

    if blocked:
        verdict = "blocked"
    elif suspicious:
        verdict = "read-it"
    elif notes:
        verdict = "caveats"
    else:
        verdict = "ok"

    return {
        "verdict": verdict,
        "blocked": blocked,
        "suspicious": suspicious,
        "notes": notes,
        "parts": parts,
        "scripts": int(report.get("scripts") or 0),
        "meshes": len(report.get("meshes") or []),
        "textures": len(report.get("textures") or []),
        "size": size,
    }


def screen(asset_id: int | str, role: str = "prop") -> dict[str, Any]:
    """Insert one asset and judge it. The whole gate, in one call."""
    inserted = insert(asset_id)
    roots = inserted.get("roots") or []
    if not roots:
        return {"assetId": asset_id, "verdict": "blocked",
                "blocked": [{"name": "empty", "detail": "asset contained nothing"}],
                "suspicious": [], "notes": []}

    report = inspect(roots[0], folder=inserted.get("path", "").split(".")[-1] or IMPORT_FOLDER)
    verdict = judge(report, role=role)
    verdict["assetId"] = asset_id
    verdict["root"] = roots[0]
    verdict["report"] = report
    return verdict


#: Enumerate what is inside a pack, one row per child model.
#:
#: The official library is mostly packs: `House Props Pack` is 288 models and
#: 286 meshes behind a single asset id. Judging that as one object answers the
#: wrong question -- nobody wants "the pack", they want the eleven chairs in it.
CATALOGUE_LUA = """
local ServerStorage = game:GetService("ServerStorage")
local target = ServerStorage:FindFirstChild("@@FOLDER@@")
if not target then return { error = "no import folder" } end
local root = target:FindFirstChild("@@ROOT@@")
if not root then return { error = "no such root: @@ROOT@@" } end

local rows = {}

local function measure(model)
	local parts, unanchored, meshes = 0, 0, 0
	local minV, maxV = nil, nil
	for _, item in model:GetDescendants() do
		if item:IsA("BasePart") then
			parts += 1
			if not item.Anchored then unanchored += 1 end
			if item:IsA("MeshPart") then meshes += 1 end
			local half = item.Size * 0.5
			local low, high = item.Position - half, item.Position + half
			minV = minV and Vector3.new(math.min(minV.X, low.X), math.min(minV.Y, low.Y),
				math.min(minV.Z, low.Z)) or low
			maxV = maxV and Vector3.new(math.max(maxV.X, high.X), math.max(maxV.Y, high.Y),
				math.max(maxV.Z, high.Z)) or high
		end
	end
	local span = (minV and maxV) and (maxV - minV) or Vector3.zero
	return parts, unanchored, meshes, span
end

--[[
	Descend through Folders; stop at the first Model.

	An official pack is Folders of Folders of Models -- `Fashion / Sewing|Tools
	/ Scissors` -- so the folder path is a category taxonomy its author wrote,
	and it is worth keeping.

	Stopping at the first Model matters as much as finding it. Models nest:
	`SewingMachine` contains `Thread_Green`. The outermost one is the prop
	somebody wants; the inner ones are its pieces, and listing those as separate
	props produces a catalogue of table legs.
]]
local function collect(node, path, depth)
	if depth > 8 then return end
	for _, child in node:GetChildren() do
		if child:IsA("Model") then
			local parts, unanchored, meshes, span = measure(child)
			table.insert(rows, {
				name = child.Name,
				category = path,
				parts = parts, unanchored = unanchored, meshes = meshes,
				width = span.X, height = span.Y, depth = span.Z,
			})
		elseif child:IsA("Folder") then
			collect(child, path == "" and child.Name or (path .. "/" .. child.Name), depth + 1)
		elseif child:IsA("BasePart") and not child:FindFirstAncestorOfClass("Model") then
			--: A loose part at pack level is a prop in its own right. One that
			--: sits under a Model is a piece of it and was counted there.
			local half = child.Size * 0.5
			table.insert(rows, {
				name = child.Name, category = path,
				parts = 1, unanchored = child.Anchored and 0 or 1,
				meshes = child:IsA("MeshPart") and 1 or 0,
				width = child.Size.X, height = child.Size.Y, depth = child.Size.Z,
			})
		end
	end
end

collect(root, "", 0)
return { root = root.Name, count = #rows, items = rows }
"""


def catalogue(root_name: str, folder: str = IMPORT_FOLDER) -> dict[str, Any]:
    """List the individually usable models inside an inserted pack."""
    source = (CATALOGUE_LUA
              .replace("@@FOLDER@@", folder)
              .replace("@@ROOT@@", root_name))
    return _call(source)


DISCARD_LUA = """
local ServerStorage = game:GetService("ServerStorage")
local folder = ServerStorage:FindFirstChild("@@FOLDER@@")
if not folder then return { removed = 0 } end
local removed = 0
for _, child in folder:GetChildren() do
	child:Destroy()
	removed += 1
end
return { removed = removed }
"""


def discard(folder: str = IMPORT_FOLDER) -> int:
    """Empty the import folder.

    Not housekeeping -- a budget. Inspecting a few hundred models means loading
    a few hundred models' worth of mesh and texture into one Studio process, and
    nothing releases that until the instances go. A sweep that does not discard
    is a sweep that dies partway through with no catalogue to show for it.
    """
    return int(_call(DISCARD_LUA.replace("@@FOLDER@@", folder)).get("removed") or 0)
