"""Build a catalogue of reusable Creator Store models, from vetted packs.

Why this is not a search
------------------------

The obvious version of this tool searches the store for "tree" and keeps the
first hundred results. That was the first version, and it was wrong: store
search ranks by popularity, and the most popular free model for any given word
is usually an ancient, over-parted, script-carrying upload of someone else's
work. Popular is not good, and it is definitely not safe.

So the catalogue starts from a hand-checked list of packs that Roblox
developers actually use — found by reading the developer forum, not by
guessing — and explodes each pack into its individual pieces. Every seed below
has a source thread, a named creator and a stated licence, all recorded in
`SEEDS` so the provenance travels with the asset.

The headline entry is Synty: a professional low-poly studio whose packs Roblox
paid to release free on the platform, uploaded by an official Roblox account.
That is as close to a safe default as this platform has.

Scripts
-------

Free models are the most common way a Roblox game gets backdoored, and the
payload is nearly always a small script inside an ordinary-looking prop. Every
piece is scanned, and anything carrying a `Script`, `LocalScript` or
`ModuleScript` is refused rather than stripped — deciding automatically which
scripts a model "needs" is exactly how a backdoor ships.

The pipeline
------------

    forge toolbox harvest      load each seed pack in Studio, explode, scan
    forge toolbox curate       write the approved subset as a Luau module

Studio does the loading, inside an authenticated session, so this process
never sees or needs an API key.
"""

from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
CATALOG_DIR = REPO / "forge" / "catalog"
RAW_PATH = CATALOG_DIR / "toolbox-harvest.json"
LUA_PATH = REPO / "forge" / "luau" / "Forge" / "Catalog" / "init.lua"


# ---------------------------------------------------------------------- seeds
#: Packs worth exploding, with where each one came from.
#:
#: `category` is the default for pieces whose own name gives nothing away;
#: piece names that clearly say otherwise are re-categorised during the walk.
SEEDS: list[dict[str, Any]] = [
    # Synty via Roblox's official `Rototally` account. Roblox's announcement
    # states these are "completely free to use in anything you want to create".
    {"id": 6933438443, "pack": "Synty Nature", "creator": "Rototally",
     "category": "foliage", "licence": "free for any Roblox creation (Roblox x Synty)",
     "source": "https://devforum.roblox.com/t/free-synty-asset-packs-released-in-the-marketplace/1283755"},
    {"id": 6933556508, "pack": "Synty City", "creator": "Rototally",
     "category": "structure", "licence": "free for any Roblox creation (Roblox x Synty)",
     "source": "https://devforum.roblox.com/t/free-synty-asset-packs-released-in-the-marketplace/1283755"},
    {"id": 6933790012, "pack": "Synty Dungeon: Weapons & Props", "creator": "Rototally",
     "category": "weapon", "licence": "free for any Roblox creation (Roblox x Synty)",
     "source": "https://devforum.roblox.com/t/free-synty-asset-packs-released-in-the-marketplace/1283755"},
    {"id": 6933905899, "pack": "Synty Dungeon: Basement & Goblin Camp", "creator": "Rototally",
     "category": "structure", "licence": "free for any Roblox creation (Roblox x Synty)",
     "source": "https://devforum.roblox.com/t/free-synty-asset-packs-released-in-the-marketplace/1283755"},
    {"id": 6934021345, "pack": "Synty Dungeon: Cave & Castle Interiors", "creator": "Rototally",
     "category": "structure", "licence": "free for any Roblox creation (Roblox x Synty)",
     "source": "https://devforum.roblox.com/t/free-synty-asset-packs-released-in-the-marketplace/1283755"},
    {"id": 6934081776, "pack": "Synty Dungeon: Skeletons & Bones", "creator": "Rototally",
     "category": "prop", "licence": "free for any Roblox creation (Roblox x Synty)",
     "source": "https://devforum.roblox.com/t/free-synty-asset-packs-released-in-the-marketplace/1283755"},

    {"id": 9492405836, "pack": "Ultimate Low Poly", "creator": "FaDoLuanSantana",
     "category": "prop", "licence": "free to use anywhere, credit appreciated not required",
     "source": "https://devforum.roblox.com/t/free-the-ultimate-low-poly-asset-pack-added-more-assets/1772603"},
    {"id": 12499666054, "pack": "Medieval Market", "creator": "devforum: Free Medieval Market Pack",
     "category": "prop", "licence": "free, PBR textured",
     "source": "https://devforum.roblox.com/t/free-medieval-market-pack/2185470"},
    {"id": 18817890736, "pack": "Inno's Stylized", "creator": "Innovatement",
     "category": "foliage", "licence": "personal and commercial use, no direct redistribution",
     "source": "https://devforum.roblox.com/t/free-innos-stylized-asset-pack/3107492"},
]

#: Words in a piece's own name that override the pack's default category.
#: Crude on purpose — it only has to be better than filing an entire pack of
#: mixed contents under one heading.
NAME_HINTS: list[tuple[str, tuple[str, ...]]] = [
    ("foliage", ("tree", "bush", "plant", "flower", "grass", "fern", "leaf", "leaves",
                 "mushroom", "log", "clover", "lilypad", "palm", "pine", "hedge")),
    ("ground", ("rock", "stone", "boulder", "cliff", "ground", "dirt", "terrain", "gravel")),
    ("weapon", ("sword", "axe", "bow", "arrow", "shield", "dagger", "spear", "mace",
                "hammer", "staff", "blade", "knife", "gun", "rifle", "pistol")),
    ("prop", ("barrel", "crate", "chest", "box", "lantern", "torch", "candle", "sack",
              "bucket", "pot", "bottle", "book", "table", "chair", "bench", "cart",
              "anvil", "campfire", "tent", "banner", "sign", "bone", "skull", "skeleton")),
    ("structure", ("house", "wall", "door", "window", "roof", "castle", "tower", "bridge",
                   "fence", "gate", "stairs", "pillar", "arch", "building", "ruin", "floor")),
]


# --------------------------------------------------------------------- bridge
class BridgeError(RuntimeError):
    pass


def bridge_exec(source: str, timeout: int = 300) -> Any:
    """Run Luau inside the connected Studio and return what it returns.

    Shells out to the same CLI a human would use rather than importing the hub:
    one code path to keep working, and it fails the same way by hand.
    """
    payload = json.dumps({"source": source})
    proc = subprocess.run(
        [sys.executable, str(REPO / "rqe.py"), "studio", "call", "bridge.exec",
         "--allow-arbitrary", "--params", payload, "--timeout", str(timeout)],
        capture_output=True, text=True, timeout=timeout + 30, cwd=str(REPO),
    )
    if proc.returncode != 0:
        raise BridgeError((proc.stderr or proc.stdout).strip()[:400])
    # The CLI prints its result envelope on stderr, not stdout. Read whichever
    # stream actually carries JSON rather than assuming which one.
    raw = proc.stdout.strip() or proc.stderr.strip()
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BridgeError(f"bridge did not return JSON: {exc}\n{raw[:300]}")
    if not envelope.get("ok"):
        raise BridgeError(json.dumps(envelope.get("error"))[:400])
    return envelope.get("result", {}).get("returned")


# -------------------------------------------------------------------- harvest
_EXPLODE_LUAU = """
local InsertService = game:GetService("InsertService")

local ok, container = pcall(function()
	return InsertService:LoadAsset(%(id)d)
end)
if not ok or not container then
	return { error = tostring(container):sub(1, 240) }
end

-- Where the pieces actually live. A pack is usually one Model full of Models,
-- but plenty wrap that in a Folder or two, so descend until there is something
-- worth listing rather than assuming a shape.
local function pieceHolder(root)
	local best, bestCount = root, 0
	local queue = { root }
	while #queue > 0 do
		local node = table.remove(queue)
		local count = 0
		for _, child in ipairs(node:GetChildren()) do
			if child:IsA("Model") or child:IsA("BasePart") then
				count += 1
			end
			if child:IsA("Folder") or child:IsA("Model") then
				table.insert(queue, child)
			end
		end
		if count > bestCount then
			best, bestCount = node, count
		end
	end
	return best
end

local holder = pieceHolder(container)
local out = {}

for _, piece in ipairs(holder:GetChildren()) do
	if piece:IsA("Model") or piece:IsA("BasePart") then
		local parts, scripts, meshes = 0, 0, 0
		local flagged = {}

		if piece:IsA("BasePart") then
			parts = 1
			if piece:IsA("MeshPart") then meshes = 1 end
		end
		for _, d in ipairs(piece:GetDescendants()) do
			if d:IsA("BasePart") then
				parts += 1
				if d:IsA("MeshPart") then meshes += 1 end
			elseif d:IsA("LuaSourceContainer") then
				scripts += 1
				if #flagged < 4 then
					table.insert(flagged, d.ClassName .. ":" .. d.Name)
				end
			end
		end

		local size = Vector3.zero
		if piece:IsA("Model") then
			local okSize, extents = pcall(function() return piece:GetExtentsSize() end)
			if okSize and typeof(extents) == "Vector3" then size = extents end
		else
			size = (piece :: BasePart).Size
		end

		table.insert(out, {
			name = piece.Name,
			class = piece.ClassName,
			parts = parts,
			meshes = meshes,
			scripts = scripts,
			flagged = flagged,
			size = {
				math.floor(size.X * 10) / 10,
				math.floor(size.Y * 10) / 10,
				math.floor(size.Z * 10) / 10,
			},
		})
	end
end

container:Destroy()
return { pieces = out, holder = holder.Name }
"""


def _categorise(name: str, fallback: str) -> str:
    lowered = name.lower()
    for category, words in NAME_HINTS:
        if any(word in lowered for word in words):
            return category
    return fallback


def _approve(piece: dict) -> tuple[bool, str]:
    """The bar for entering the catalogue, and why something missed it."""
    if piece["scripts"] > 0:
        return False, "carries a script"
    if piece["parts"] < 1:
        return False, "no parts"
    if piece["parts"] > 300:
        return False, "too heavy to drop into a scene"
    largest = max(piece["size"]) if piece["size"] else 0
    if largest < 0.2:
        return False, "smaller than a stud"
    if largest > 400:
        return False, "map-sized, not a prop"
    return True, ""


def harvest() -> dict:
    """Load every seed pack, explode it, scan the pieces, write the report."""
    CATALOG_DIR.mkdir(parents=True, exist_ok=True)
    entries: list[dict] = []
    packs: list[dict] = []

    for seed in SEEDS:
        print(f"\n{seed['pack']} ({seed['id']})", flush=True)
        try:
            report = bridge_exec(_EXPLODE_LUAU % {"id": seed["id"]}) or {}
        except BridgeError as exc:
            print(f"  FALHOU: {exc}", flush=True)
            packs.append({**seed, "ok": False, "error": str(exc)[:240]})
            continue

        if report.get("error"):
            print(f"  FALHOU: {report['error']}", flush=True)
            packs.append({**seed, "ok": False, "error": report["error"]})
            continue

        pieces = report.get("pieces") or []
        kept = 0
        for piece in pieces:
            approved, reason = _approve(piece)
            entry = {
                "pack": seed["pack"],
                "packId": seed["id"],
                "creator": seed["creator"],
                "licence": seed["licence"],
                "source": seed["source"],
                "name": piece["name"],
                "class": piece["class"],
                "category": _categorise(piece["name"], seed["category"]),
                "parts": piece["parts"],
                "meshes": piece["meshes"],
                "scripts": piece["scripts"],
                "flagged": piece.get("flagged") or [],
                "size": piece["size"],
                "approved": approved,
                "rejectedBecause": reason,
            }
            entries.append(entry)
            kept += 1 if approved else 0

        packs.append({**seed, "ok": True, "pieces": len(pieces), "approved": kept,
                      "holder": report.get("holder")})
        print(f"  {len(pieces)} pecas, {kept} aprovadas", flush=True)

    scripted = sum(1 for e in entries if e["scripts"] > 0)
    catalogue = {
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "packs": packs,
        "pieces": len(entries),
        "approved": sum(1 for e in entries if e["approved"]),
        "carryingScripts": scripted,
        "entries": entries,
    }
    RAW_PATH.write_text(json.dumps(catalogue, indent=2, ensure_ascii=False), encoding="utf-8")
    return catalogue


# --------------------------------------------------------------------- curate
_HEADER = '''--!strict
--[[
	Catalog — Creator Store models this project has verified.

	Generated by `forge toolbox curate`. Do not hand-edit; regenerate it.

	Where these came from matters as much as what they are. They are not search
	results: each one was taken from a pack that Roblox developers actually use,
	found by reading the developer forum, and the pack's creator, licence and
	source thread travel with every piece. Most of them are Synty — a
	professional low-poly studio whose packs Roblox paid to release free, under
	an official Roblox account.

	Every entry was loaded inside Studio, measured and scanned. `parts`,
	`meshes` and `size` are readings off the real thing after insertion, not
	descriptions. Every entry has no scripts, because anything carrying one was
	refused rather than stripped: free-model scripts are the most common way a
	Roblox game gets backdoored, and deciding automatically which ones a model
	"needs" is exactly how that ships.

		local Catalog = Forge.Catalog

		local trees = Catalog.byCategory("foliage")
		local model = Catalog.load(trees[1])

	An id absent from this file has not been checked, and `Assets` refuses it.
]]

local InsertService = game:GetService("InsertService")

local Catalog = {}

Catalog.generated = %(generated)s

-- The packs every entry below was taken out of.
Catalog.packs = {
%(packs)s
}

Catalog.entries = {
%(entries)s
}

'''

_FOOTER = '''
-- ================================= lookup ===================================
function Catalog.byCategory(category: string): { any }
	local out = {}
	for _, entry in Catalog.entries do
		if entry.category == category then
			table.insert(out, entry)
		end
	end
	return out
end

function Catalog.byPack(pack: string): { any }
	local out = {}
	for _, entry in Catalog.entries do
		if entry.pack == pack then
			table.insert(out, entry)
		end
	end
	return out
end

function Catalog.find(text: string): { any }
	local needle = text:lower()
	local out = {}
	for _, entry in Catalog.entries do
		if entry.name:lower():find(needle, 1, true) then
			table.insert(out, entry)
		end
	end
	return out
end

function Catalog.categories(): { string }
	local seen, out = {}, {}
	for _, entry in Catalog.entries do
		if not seen[entry.category] then
			seen[entry.category] = true
			table.insert(out, entry.category)
		end
	end
	table.sort(out)
	return out
end

-- Whether a pack id may be inserted at all. `Assets` calls this before
-- anything reaches the world, which is what stops an invented id from
-- reaching a player.
function Catalog.verifiedPack(packId: number): boolean
	for _, pack in Catalog.packs do
		if pack.id == packId then
			return true
		end
	end
	return false
end

--[[
	Insert a piece and hand back a clone of it.

	Packs are loaded once and cached: a pack is a single asset containing
	dozens of pieces, so fetching it again for the second tree is dozens of
	needless round trips.
]]
local packCache: { [number]: Instance } = {}

local function loadPack(packId: number): Instance?
	if packCache[packId] then
		return packCache[packId]
	end
	if not Catalog.verifiedPack(packId) then
		warn(string.format("[Catalog] pack %d is not in the verified list", packId))
		return nil
	end
	local ok, container = pcall(function()
		return InsertService:LoadAsset(packId)
	end)
	if not ok or not container then
		warn(string.format("[Catalog] pack %d failed to load: %s", packId, tostring(container)))
		return nil
	end
	packCache[packId] = container
	return container
end

function Catalog.load(entry: any): Instance?
	local container = loadPack(entry.packId)
	if not container then
		return nil
	end
	local found = container:FindFirstChild(entry.name, true)
	if not found then
		warn(string.format("[Catalog] '%s' is not inside pack %d any more", entry.name, entry.packId))
		return nil
	end
	return found:Clone()
end

function Catalog.describe(): { [string]: any }
	local byCategory: { [string]: number } = {}
	for _, entry in Catalog.entries do
		byCategory[entry.category] = (byCategory[entry.category] or 0) + 1
	end
	return {
		generated = Catalog.generated,
		entries = #Catalog.entries,
		packs = #Catalog.packs,
		categories = byCategory,
	}
end

return Catalog
'''


def _lua_string(value: Any) -> str:
    text = str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")
    # Plain ASCII: store names are full of emoji, and a catalogue that will not
    # compile under someone else's encoding is worthless.
    text = "".join(ch if 32 <= ord(ch) < 127 else "?" for ch in text)
    return '"' + text + '"'


def curate(cap: int = 200) -> tuple[Path, int]:
    """Write the approved subset as a Luau module, balanced across categories."""
    data = json.loads(RAW_PATH.read_text(encoding="utf-8"))
    approved = [e for e in data["entries"] if e["approved"]]

    buckets: dict[str, list[dict]] = {}
    for entry in approved:
        buckets.setdefault(entry["category"], []).append(entry)
    for items in buckets.values():
        # Fewer parts first: a scene made of 4-part props streams and renders
        # very differently from one made of 200-part props.
        items.sort(key=lambda e: (e["parts"], e["name"].lower()))

    picked: list[dict] = []
    order = sorted(buckets)
    cursor = 0
    while len(picked) < cap and any(buckets[c] for c in order):
        category = order[cursor % len(order)]
        if buckets[category]:
            picked.append(buckets[category].pop(0))
        cursor += 1

    used_packs = {e["packId"] for e in picked}
    pack_lines = "\n".join(
        "\t{ id = %d, name = %s, creator = %s, licence = %s, source = %s }," % (
            seed["id"], _lua_string(seed["pack"]), _lua_string(seed["creator"]),
            _lua_string(seed["licence"]), _lua_string(seed["source"]))
        for seed in SEEDS if seed["id"] in used_packs
    )

    entry_lines = "\n".join(
        "\t{ name = %s, pack = %s, packId = %d, category = %s, parts = %d, meshes = %d, "
        "size = Vector3.new(%s, %s, %s) }," % (
            _lua_string(e["name"]), _lua_string(e["pack"]), e["packId"],
            _lua_string(e["category"]), e["parts"], e["meshes"],
            e["size"][0], e["size"][1], e["size"][2])
        for e in sorted(picked, key=lambda e: (e["category"], e["name"].lower()))
    )

    LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
    LUA_PATH.write_text(
        _HEADER % {"generated": _lua_string(data["generatedAt"]),
                   "packs": pack_lines, "entries": entry_lines} + _FOOTER,
        encoding="utf-8")
    return LUA_PATH, len(picked)
