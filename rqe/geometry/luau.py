"""Mesh data as a Luau module the place can carry.

The last link in the chain. Blender writes vertex data, `WorldKit.Mesh` builds a
MeshPart from it, and this turns one into the other -- a ModuleScript of plain
numeric arrays, no dependencies, no upload.

Size is the whole design problem here, because this data ships inside the place
file and is parsed on every client:

**Positions are rounded to two decimals.** A hundredth of a stud is a fifth of a
millimetre at Roblox scale; nothing is visible at that precision and the digits
cost more than the geometry. Measured on the kit: 166 KB to 96 KB.

**UVs are dropped unless the asset is textured.** Nothing in this kit is --
colour comes from the palette at placement time -- and UVs are a third of the
vertex payload.

**Normals are kept.** They are what makes a bevel read as a bevel; dropping them
returns the smooth blobs the modelling programs exist to avoid. This is the one
place the size is worth paying.

The alternative to all of this is Open Cloud: upload once, reference an asset id,
ship nothing. That path is better for a game going to production and is a
straight swap -- `Catalogue` hands out names, not backends. It needs a credential
and a creator id, and it puts the asset through moderation. This needs neither
and works now.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable


class LuauExportError(ValueError):
    """Mesh data could not be turned into a module."""


#: Past this a module is slow to parse on a low-end client and the asset should
#: go through Open Cloud instead. Not a hard refusal -- a warning the caller can
#: act on, because a single oversized hero may still be the right call.
MODULE_BYTE_BUDGET = 220_000


def _numbers(values: Iterable[float], places: int) -> str:
    """A Luau array literal, as small as the precision allows.

    Integers lose their trailing `.0`, which is most of the saving on index
    arrays and a real fraction of it on positions.
    """

    out = []
    for value in values:
        rounded = round(float(value), places)
        if rounded == int(rounded):
            out.append(str(int(rounded)))
        else:
            out.append(repr(rounded))
    return "{" + ",".join(out) + "}"


def module_source(data: dict[str, Any], *, keep_uvs: bool = False) -> str:
    """One mesh as a Luau ModuleScript."""

    for field in ("id", "positions", "indices"):
        if field not in data:
            raise LuauExportError(
                f"mesh data is missing {field!r}; it cannot be built without it"
            )
    positions = data["positions"]
    indices = data["indices"]
    if len(positions) % 3:
        raise LuauExportError(
            f"{data['id']} has {len(positions)} position values, not a multiple of 3"
        )
    if len(indices) % 3:
        raise LuauExportError(
            f"{data['id']} has {len(indices)} indices, which is not whole triangles"
        )

    lines = [
        "--!strict",
        f"-- {data['id']}: authored in Blender, built at runtime by WorldKit.Mesh.",
        "--",
        "-- Generated. Positions are in studs and Y-up already; the Blender Z-up",
        "-- conversion happens at export so nothing downstream has to know about it.",
        f"-- {len(indices) // 3} triangles, {len(positions) // 3} vertices.",
        "",
        "return {",
        f"\tid = {json.dumps(data['id'])},",
        f"\tpositions = {_numbers(positions, 2)},",
    ]
    if data.get("normals"):
        lines.append(f"\tnormals = {_numbers(data['normals'], 3)},")
    if keep_uvs and data.get("uvs"):
        lines.append(f"\tuvs = {_numbers(data['uvs'], 3)},")
    lines.append(f"\tindices = {_numbers(indices, 0)},")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def export(mesh_json: Path, destination: Path, *, keep_uvs: bool = False) -> dict[str, Any]:
    """Write one mesh module and report what it cost."""

    data = json.loads(Path(mesh_json).read_text(encoding="utf-8"))
    source = module_source(data, keep_uvs=keep_uvs)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(source, encoding="utf-8")
    size = destination.stat().st_size
    return {
        "id": data["id"],
        "path": str(destination),
        "bytes": size,
        "triangles": len(data["indices"]) // 3,
        "vertices": len(data["positions"]) // 3,
        "overBudget": size > MODULE_BYTE_BUDGET,
        "budget": MODULE_BYTE_BUDGET,
    }


def catalogue_source(entries: list[dict[str, Any]]) -> str:
    """The index the world asks for meshes through.

    Callers name a thing -- "tree", "rock" -- and get data or nil. That is the
    seam that lets the backend change: an Open Cloud build returns asset ids
    from the same names and no placement code changes.
    """

    lines = [
        "--!strict",
        "-- The authored kit, by name.",
        "--",
        "-- Generated from the Blender kit. Callers ask for a name and get mesh",
        "-- data or nil, so a world that wants a tree gets an authored one where",
        "-- the kit has it and falls back to the Part version where it does not.",
        "-- Nothing here is specific to one game: the names are the world",
        "-- grammar's own prop vocabulary.",
        "",
        "local MeshKit = {",
    ]
    for entry in sorted(entries, key=lambda item: item["id"]):
        lines.append(f"\t{entry['id']} = require(script.{entry['id']}),")
    lines.append("}")
    lines.append("")
    lines.append("--- Mesh data for a named kit entry, or nil when it has none.")
    lines.append("function MeshKit.get(name: string)")
    lines.append("\treturn (MeshKit :: any)[name]")
    lines.append("end")
    lines.append("")
    lines.append("return MeshKit")
    lines.append("")
    return "\n".join(lines)


def export_kit(source_root: Path, destination_root: Path,
               names: Iterable[str]) -> dict[str, Any]:
    """Every built kit entry as modules, plus the index."""

    entries: list[dict[str, Any]] = []
    missing: list[str] = []
    for name in names:
        mesh_json = Path(source_root) / name / "export" / f"{name}.mesh.json"
        if not mesh_json.is_file():
            missing.append(name)
            continue
        entries.append(export(mesh_json, Path(destination_root) / f"{name}.lua"))

    if entries:
        index = Path(destination_root) / "init.lua"
        index.write_text(catalogue_source(entries), encoding="utf-8")

    return {
        "entries": entries,
        "missing": missing,
        "totalBytes": sum(entry["bytes"] for entry in entries),
        "overBudget": [entry["id"] for entry in entries if entry["overBudget"]],
    }
