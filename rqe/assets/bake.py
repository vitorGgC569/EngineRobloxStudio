"""Turn a fetched store model into data a game can rebuild without fetching it.

The problem this solves
-----------------------

A catalogued asset id is not usable at runtime. `InsertService:LoadAsset`
refuses third-party assets, and `game:GetObjects` is a plugin call that a live
game does not have. So a shipped game cannot pull a store model in by id, which
makes a catalogue of ids a shopping list rather than a supply.

Two routes out. Bake the model into the place file, which means binary in the
repository and a rojo project that carries it. Or read the geometry once and
emit it as data the game rebuilds from primitives -- versioned, diffable, and
inspectable, which is what the rest of this engine does with everything else.

This is the second.

The mesh constraint that decides the shape
------------------------------------------

`MeshPart.MeshId` cannot be written. Not at runtime, not from a plugin: Roblox
answers "the current thread cannot write 'MeshId' (lacking capability
NotAccessible)". So a baked MeshPart cannot be rebuilt as a MeshPart.

`SpecialMesh` with `MeshType = FileMesh` **can** take a MeshId at runtime, and
that is the whole rebuild path: a Part carrying a SpecialMesh renders the same
geometry. The costs are real and worth stating -- a SpecialMesh takes no
`SurfaceAppearance`, so PBR maps are lost, and collision is the host Part's box
rather than the mesh hull. For scenery, both are the right trade. For anything
a player stands on precisely, they are not.

Scale is `Size / MeshSize`, because a FileMesh renders at its own natural size
times `Scale` and ignores the Part's size entirely. `MeshSize` is the mesh's
natural size and is readable; without dividing by it, every baked mesh comes
back at whatever size its author modelled it at.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from . import inspection

SPEC_PATH = Path("forge/kits/store-props.json")

#: Past this a model is a scene rather than a prop, and baking it produces a
#: spec nobody wants to read or place. The big ones stay in the catalogue as
#: ids for a person to insert by hand in Studio.
MAX_PARTS = 40

BAKE_LUA = """
local ServerStorage = game:GetService("ServerStorage")
local folder = ServerStorage:FindFirstChild("@@FOLDER@@")
if not folder then return { error = "no import folder" } end
--: The first child is not reliably the model -- uploads carry stray
--: ThumbnailCameras and loose Scripts. Take the first thing with geometry.
local root = nil
for _, child in folder:GetChildren() do
	if child:IsA("Model") or child:IsA("BasePart") then
		root = child
		break
	end
end
if not root then return { error = "nothing with geometry in the import" } end

--[[
	Relative to the pivot's *position*, with its rotation discarded.

	Everything is expressed relative to the model's own pivot so a placed prop
	lands where it is put rather than where its author happened to build it --
	but only the translation. Keeping the pivot's rotation expresses every part
	in a frame the rebuild does not reproduce, and the model comes back rotated:
	a crate baked this way returned 6.33 x 12.75 x 4.48 for a spec that recorded
	12.75 x 4.48 x 6.33, which is the same box lying on its side.

	Stripping the rotation keeps each part's world orientation, which is what
	the author actually built and what the rebuild lays out.
]]
local pivot = root:IsA("BasePart") and root.CFrame or root:GetPivot()
local origin = CFrame.new(pivot.Position)

local parts = {}
local items = root:IsA("BasePart") and { root } or root:GetDescendants()
for _, p in items do
	if p:IsA("BasePart") then
		if #parts >= @@MAX@@ then break end
		local rel = origin:ToObjectSpace(p.CFrame)
		local x, y, z, m00, m01, m02, m10, m11, m12, m20, m21, m22 = rel:GetComponents()
		local row = {
			cf = { x, y, z, m00, m01, m02, m10, m11, m12, m20, m21, m22 },
			size = { p.Size.X, p.Size.Y, p.Size.Z },
			color = { math.floor(p.Color.R * 255 + 0.5), math.floor(p.Color.G * 255 + 0.5),
			          math.floor(p.Color.B * 255 + 0.5) },
			material = p.Material.Name,
			transparency = p.Transparency,
			reflectance = p.Reflectance,
		}
		if p:IsA("Part") and p.Shape ~= Enum.PartType.Block then
			row.shape = p.Shape.Name
		end
		if p:IsA("MeshPart") and p.MeshId ~= "" then
			row.mesh = p.MeshId
			if p.TextureID ~= "" then row.texture = p.TextureID end
			local ok, natural = pcall(function() return p.MeshSize end)
			if ok and natural.X > 0 and natural.Y > 0 and natural.Z > 0 then
				--: A FileMesh ignores the Part's size and renders at its own
				--: natural size times Scale, so the ratio is the only thing
				--: that reproduces the original.
				row.scale = { p.Size.X / natural.X, p.Size.Y / natural.Y,
				              p.Size.Z / natural.Z }
			end
		end
		local special = p:FindFirstChildOfClass("SpecialMesh")
		if special and special.MeshId ~= "" then
			row.mesh = special.MeshId
			row.scale = { special.Scale.X, special.Scale.Y, special.Scale.Z }
			if special.TextureId ~= "" then row.texture = special.TextureId end
		end
		table.insert(parts, row)
	end
end

--[[
	Extents measured from the parts, not from `GetExtentsSize`.

	`Model:GetExtentsSize()` returns the bounding box **oriented to the model's
	pivot**, and the rebuild lays parts out on world axes. Recording one and
	reproducing the other is why a crate asked to stand five studs tall came
	back at fourteen: its recorded height was another axis of the same box.

	So the box is accumulated here in the frame the rebuild actually uses. A
	rotated part contributes its rotated half-extents to each axis, which is the
	sum of its own half-sizes weighted by the absolute rotation terms -- the
	standard world-AABB of an oriented box.
]]
local lowX, lowY, lowZ = math.huge, math.huge, math.huge
local highX, highY, highZ = -math.huge, -math.huge, -math.huge
for _, row in parts do
	local c, sz = row.cf, row.size
	local hx = math.abs(c[4]) * sz[1] + math.abs(c[5]) * sz[2] + math.abs(c[6]) * sz[3]
	local hy = math.abs(c[7]) * sz[1] + math.abs(c[8]) * sz[2] + math.abs(c[9]) * sz[3]
	local hz = math.abs(c[10]) * sz[1] + math.abs(c[11]) * sz[2] + math.abs(c[12]) * sz[3]
	hx, hy, hz = hx * 0.5, hy * 0.5, hz * 0.5
	lowX = math.min(lowX, c[1] - hx) highX = math.max(highX, c[1] + hx)
	lowY = math.min(lowY, c[2] - hy) highY = math.max(highY, c[2] + hy)
	lowZ = math.min(lowZ, c[3] - hz) highZ = math.max(highZ, c[3] + hz)
end

local extents = { 0, 0, 0 }
if #parts > 0 then
	extents = { highX - lowX, highY - lowY, highZ - lowZ }
end

return {
	name = root.Name,
	parts = parts,
	extents = extents,
	truncated = #parts >= @@MAX@@,
}
"""


def bake_one(asset_id: int, max_parts: int = MAX_PARTS) -> dict[str, Any]:
    """Fetch one asset and read its geometry out as a spec."""
    inspection.discard()
    inspection.insert(asset_id)
    source = (BAKE_LUA
              .replace("@@FOLDER@@", inspection.IMPORT_FOLDER)
              .replace("@@MAX@@", str(max_parts)))
    spec = inspection._call(source, timeout=60)
    inspection.discard()
    if spec.get("error"):
        raise RuntimeError(f"asset {asset_id}: {spec['error']}")
    spec["id"] = asset_id
    return spec


def bake(picks: list[dict[str, Any]], max_parts: int = MAX_PARTS,
         progress: Any = print) -> dict[str, Any]:
    """Bake a list of catalogue rows. Returns the spec book.

    Anchoring is decided here rather than copied. A store model's own anchored
    flags are whatever its author left behind, and 102 of the catalogued 365
    carry unanchored parts -- every one a physics body the server simulates for
    as long as it exists. Scenery does not need any of them, so baked props are
    anchored, and a game that wants a prop to fall can say so at placement.
    """
    specs: dict[str, Any] = {}
    failed: list[dict[str, Any]] = []

    from .sweep import _LOST_SESSION, _revive

    for row in picks:
        spec = None
        for attempt in (1, 2):
            try:
                spec = bake_one(int(row["id"]), max_parts=max_parts)
                break
            except Exception as error:  # noqa: BLE001 - one bad asset must not end the run
                #: The same failure the sweep hit: Studio drops its bridge
                #: session partway through a long run. Without this a bake of
                #: 29 props produced 3, and the 26 "failures" were all the same
                #: dead session rather than 26 bad assets.
                if _LOST_SESSION in str(error) and attempt == 1 and _revive(progress):
                    continue
                failed.append({"id": row["id"], "name": row.get("name"),
                               "error": str(error)[:120]})
                progress(f"  {row.get('topic')}/{row.get('name', '')[:24]}: {error}")
                break
        if spec is None:
            continue

        specs[str(row["id"])] = {
            "id": row["id"],
            "name": spec["name"],
            "topic": row.get("topic"),
            "kind": row.get("kind"),
            "role": row.get("role"),
            "parts": spec["parts"],
            "extents": spec["extents"],
            "truncated": spec.get("truncated", False),
            "meshes": sum(1 for p in spec["parts"] if p.get("mesh")),
        }
        progress(f"  {row.get('topic')}/{spec['name'][:24]}: "
                 f"{len(spec['parts'])} parts, "
                 f"{sum(1 for p in spec['parts'] if p.get('mesh'))} meshed")

    book = {
        "$comment": (
            "Geometry read out of Creator Store models so a game can rebuild "
            "them from primitives, with no InsertService and no binary in the "
            "repository. Meshed parts rebuild as a Part carrying a SpecialMesh, "
            "because MeshPart.MeshId cannot be written at runtime -- which means "
            "no SurfaceAppearance and box collision. Everything is relative to "
            "the model's pivot and is anchored on rebuild."),
        "props": specs,
        "failed": failed,
        "count": len(specs),
    }
    SPEC_PATH.parent.mkdir(parents=True, exist_ok=True)
    SPEC_PATH.write_text(json.dumps(book, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return book


#: How wide a thing of each role should be **in plan**, in studs.
#:
#: A gate the metadata cannot provide, and one the catalogue needed: a search
#: for "bush" returned a model called "Кусты" -- bushes, plural -- which is a
#: 33-stud strip of hedge. The bake reproduced it faithfully, and 110 of them
#: scattered across a quarry would have looked exactly as wrong as it sounds.
#:
#: Footprint, not the largest dimension. A first version measured
#: `max(x, y, z)` and threw away every tree in the catalogue, because a tree is
#: thirty studs tall and that is the whole point of a tree.
ROLE_FOOTPRINT = {
    "scatter": 16,
    "prop": 32,
    "character": 22,
    "hero": 70,
    "structure": 500,
}

#: Height is generous everywhere. Tall is a silhouette; wide is a footprint,
#: and only one of them is in anybody's way.
ROLE_HEIGHT = {
    "scatter": 45,
    "prop": 60,
    "character": 40,
    "hero": 120,
    "structure": 500,
}

#: Widest horizontal over narrowest. Past this a prop is a strip, and a strip
#: scattered a hundred times reads as the same long stamp a hundred times.
MAX_ASPECT = 5.0

#: Topics where being a strip is the correct shape. A fence that is not long is
#: a fence post; a pipe that is not long is a washer. Applying the aspect rule
#: to these rejected every single candidate, which is how it was found.
LINEAR_TOPICS = frozenset({
    "fence", "pipe", "conveyor", "conveyor platform", "road", "wall", "bridge",
    "ladder", "mine cart", "platform", "barricade", "sandbag", "pickaxe",
    "sword", "magic staff", "rifle", "street lamp",
})


def _proportioned(row: dict[str, Any]) -> str | None:
    """Why this row is the wrong shape for its role, or None if it is fine."""
    size = row.get("size") or {}
    x, y, z = size.get("x", 0), size.get("y", 0), size.get("z", 0)
    if not (x and y and z):
        return None  #: nothing measured; the bake will find out

    role = row.get("role", "prop")
    footprint = max(x, z)
    limit = ROLE_FOOTPRINT.get(role, ROLE_FOOTPRINT["prop"])
    if footprint > limit:
        return f"{footprint:.0f} studs in plan, over the {role} limit of {limit}"

    tall = ROLE_HEIGHT.get(role, ROLE_HEIGHT["prop"])
    if y > tall:
        return f"{y:.0f} studs tall, over the {role} limit of {tall}"

    if (row.get("topic") or "").lower() not in LINEAR_TOPICS:
        flat = footprint / max(min(x, z), 0.01)
        if flat > MAX_ASPECT:
            return f"{flat:.0f}:1 in plan; a strip rather than a prop"
    return None


def pick_from_catalogue(topics: list[str], per_topic: int = 2,
                        clean_only: bool = True,
                        progress: Any = print) -> list[dict[str, Any]]:
    """The best few of each named topic, from what the sweep already judged."""
    from .sweep import CATALOGUE

    catalogue = json.loads(CATALOGUE.read_text(encoding="utf-8"))
    wanted = {t.lower() for t in topics}
    picks: list[dict[str, Any]] = []

    for topic in topics:
        rows = []
        for row in catalogue["assets"]:
            if row["topic"].lower() != topic.lower():
                continue
            if clean_only and row["verdict"] != "ok":
                continue
            #: A prop with a hundred parts is a set piece; baking it makes a
            #: spec nobody reads and a rebuild nobody wants per instance.
            if row.get("parts", 0) > MAX_PARTS:
                continue
            wrong = _proportioned(row)
            if wrong:
                progress(f"  skip {topic}/{row['name'][:22]}: {wrong}")
                continue
            rows.append(row)

        rows.sort(key=lambda a: -a["score"])
        picks.extend(rows[:per_topic])

    missing = wanted - {p["topic"].lower() for p in picks}
    if missing:
        progress(f"  nothing clean and well-proportioned for: {', '.join(sorted(missing))}")
    return picks


LUA_PATH = Path("forge/luau/Forge/Catalog/StoreProps.lua")

_HEADER = '''--!strict
--[[
	StoreProps — geometry read out of real Creator Store models.

	Generated by `rqe.assets.bake`; rewritten on every bake, so do not edit it.
	`Forge.Catalog.Prop` turns one of these into instances.

	Each part carries its offset from the model's pivot as twelve numbers in
	`CFrame.new` order, its size, colour and material, and -- where the original
	was a MeshPart -- the mesh id and the scale that reproduces its size. That
	scale is `Size / MeshSize`, because a FileMesh renders at its own natural
	size and ignores the Part's.

	%(count)d props across %(topics)d topics. Baked %(baked)s.
]]

local StoreProps = {}

StoreProps.count = %(count)d

StoreProps.props = {
%(entries)s
}
'''

_FOOTER = '''
local byTopic: { [string]: { any } } = {}
for _, spec in StoreProps.props do
	local list = byTopic[spec.topic]
	if not list then list = {} byTopic[spec.topic] = list end
	table.insert(list, spec)
end

local byId: { [string]: any } = {}
for _, spec in StoreProps.props do
	byId[tostring(spec.id)] = spec
end

--: By id first, then by topic. A caller naming a topic wants "any rock" and a
--: caller naming an id wants that one, and both spellings are a string.
function StoreProps.get(which: string): any?
	local direct = byId[which]
	if direct then
		return direct
	end
	local list = byTopic[which]
	return list and list[1] or nil
end

function StoreProps.byTopic(topic: string): { any }
	return byTopic[topic] or {}
end

function StoreProps.topics(): { string }
	local out = {}
	for topic in byTopic do
		table.insert(out, topic)
	end
	table.sort(out)
	return out
end

return StoreProps
'''


def _numbers(values: list[float], places: int = 4) -> str:
    return ", ".join(f"{round(float(v), places):g}" for v in values)


def _lua_string(value: str) -> str:
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def export_lua(book: dict[str, Any] | None = None) -> tuple[Path, int]:
    """Write the baked specs as a Luau module."""
    import time

    data = book or json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    props = data.get("props") or {}

    blocks = []
    for spec in sorted(props.values(), key=lambda s: (s.get("topic") or "", s["id"])):
        rows = []
        for part in spec["parts"]:
            fields = [
                f"cf = {{ {_numbers(part['cf'])} }}",
                f"size = {{ {_numbers(part['size'])} }}",
                f"color = {{ {_numbers(part['color'], 0)} }}",
                f"material = {_lua_string(part['material'])}",
            ]
            if part.get("shape"):
                fields.append(f"shape = {_lua_string(part['shape'])}")
            if part.get("transparency"):
                fields.append(f"transparency = {round(part['transparency'], 3):g}")
            if part.get("reflectance"):
                fields.append(f"reflectance = {round(part['reflectance'], 3):g}")
            if part.get("mesh"):
                fields.append(f"mesh = {_lua_string(part['mesh'])}")
                if part.get("texture"):
                    fields.append(f"texture = {_lua_string(part['texture'])}")
                if part.get("scale"):
                    fields.append(f"scale = {{ {_numbers(part['scale'])} }}")
            rows.append("\t\t\t{ " + ", ".join(fields) + " },")

        blocks.append(
            "\t{\n"
            f"\t\tid = {spec['id']}, name = {_lua_string(spec['name'])},\n"
            f"\t\ttopic = {_lua_string(spec.get('topic') or '')}, "
            f"kind = {_lua_string(spec.get('kind') or '')},\n"
            f"\t\textents = {{ {_numbers(spec['extents'])} }},\n"
            "\t\tparts = {\n" + "\n".join(rows) + "\n\t\t},\n"
            "\t},")

    topics = {s.get("topic") for s in props.values()}
    LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
    LUA_PATH.write_text(
        _HEADER % {"count": len(props), "topics": len(topics),
                   "baked": time.strftime("%Y-%m-%d"),
                   "entries": "\n".join(blocks)} + _FOOTER,
        encoding="utf-8")
    return LUA_PATH, len(props)
