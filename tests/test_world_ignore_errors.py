"""world.raycast / world.ground_support must not drop ignore-path errors.

A caller that names an exclude path is asking for a measurement that does not
include that instance. Resolve.instance already raises a structured error when
the path is missing. Catching that error and continuing makes the command
report success for a ray that was supposed to ignore the missing target.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORLD = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "World.lua"
TERRAIN = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Terrain.lua"


def test_world_ignore_paths_propagate_resolve_errors() -> None:
    source = WORLD.read_text(encoding="utf-8")

    assert "pcall(Resolve.instance, path)" not in source
    assert "pcall(Resolve.instance" not in source
    assert "table.insert(ignored, Resolve.instance(path))" in source


def test_region_ignore_paths_already_fail_closed() -> None:
    # The region command is the contract this fix matches: a bad ignore path
    # fails the command instead of being skipped.
    source = TERRAIN.read_text(encoding="utf-8")
    assert "table.insert(ignored, Resolve.instance(path))" in source
    assert "pcall(Resolve.instance" not in source
