"""Verify every asset id a game references, by loading it.

The hole this closes
--------------------

An invented asset id passes everything. It is a syntactically perfect string,
so the compiler is happy; it is in a well-formed table, so the doctor is happy;
no test asserts anything about it, so the suite is happy; `rojo` writes it into
the place without comment. The first thing that ever disagrees is a player's
speakers, and what they get is silence plus a line in a log nobody reads.

That happened three times in one session here. Marketplace ids that were pure
invention. Then `rbxasset://` filenames written from memory — eight of them,
and not one existed; the real directory holds eleven files with different
names. Confidence was never the missing ingredient, and no amount of care
while writing would have caught it. Only loading the thing catches it.

So: ids get loaded inside Studio, the results are written to a registry, and
the doctor refuses any id in game source that is not in the registry and
passing. An id nobody has verified cannot ship.

    forge assets scan       find every id referenced in game source
    forge assets verify     load each one in Studio, record the verdict
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
REGISTRY = REPO / "forge" / "catalog" / "assets-verified.json"

#: `rbxassetid://123`, `rbxasset://sounds/x.mp3`, and bare `rbxthumb` etc.
ID_PATTERN = re.compile(r"rbxassetid://(\d+)|rbxasset://([A-Za-z0-9_\-./]+)")

#: Comment stripping, so an id mentioned in prose while explaining a past
#: mistake is not treated as a live reference. This file's own history makes
#: that a real case rather than a hypothetical one.
BLOCK_COMMENT = re.compile(r"--\[\[.*?\]\]", re.S)
LINE_COMMENT = re.compile(r"--[^\n]*")


def scan(roots: list[Path]) -> dict[str, list[str]]:
    """Every asset reference in live code, with where it was found."""
    found: dict[str, list[str]] = {}
    for root in roots:
        for path in sorted(root.rglob("*.lua")):
            text = path.read_text(encoding="utf-8", errors="ignore")
            text = LINE_COMMENT.sub("", BLOCK_COMMENT.sub("", text))
            for match in ID_PATTERN.finditer(text):
                ref = (f"rbxassetid://{match.group(1)}" if match.group(1)
                       else f"rbxasset://{match.group(2)}")
                found.setdefault(ref, []).append(str(path.relative_to(REPO)))
    return found


# --------------------------------------------------------------------- verify
_VERIFY_LUAU = """
local refs = %(refs)s
local out = {}
local pending = {}

--[[
	Start every fetch, then wait once.

	`ContentProvider:PreloadAsync` was the obvious call and the wrong one: it
	blocks until each asset resolves, and twenty blocking fetches overran the
	bridge's own timeout, so every id came back "failed" for a reason that had
	nothing to do with the id. Kicking all of them off and polling afterwards
	costs one wait for the whole batch instead of one per asset.
]]
local fonts = {}

for _, ref in ipairs(refs) do
	if ref:find("/fonts/", 1, true) then
		--[[
			Fonts need their own probe.

			The first version pushed everything through a Sound, and all four
			font families came back failing — not because they are missing, but
			because a font family is not a sound and never could be. A verifier
			whose false negatives look exactly like real failures is worse than
			no verifier: it trains you to ignore it.
		]]
		local ok, err = pcall(function()
			local face = Font.new(ref)
			local label = Instance.new("TextLabel")
			label.FontFace = face
			label:Destroy()
		end)
		fonts[ref] = { ok = ok, err = ok and nil or tostring(err):sub(1, 160) }
	else
		-- A Sound is the cheapest probe that exercises the whole path: the id
		-- is resolved, fetched and decoded, and a wrong *type* fails here just
		-- as loudly as a missing id. "Asset type does not match requested
		-- type" was how the first invented id in this project announced itself.
		local sound = Instance.new("Sound")
		local ok, err = pcall(function()
			sound.SoundId = ref
		end)
		sound.Parent = workspace
		pending[ref] = { sound = sound, ok = ok, err = ok and nil or tostring(err):sub(1, 160) }
	end
end

local deadline = os.clock() + 6
repeat
	local waiting = false
	for _, row in pairs(pending) do
		if row.ok and not row.sound.IsLoaded then
			waiting = true
			break
		end
	end
	if not waiting then
		break
	end
	task.wait(0.1)
until os.clock() > deadline

for ref, row in pairs(pending) do
	out[ref] = {
		ok = row.ok and row.sound.IsLoaded,
		loaded = row.sound.IsLoaded,
		kind = "sound",
		error = row.err,
		seconds = row.sound.TimeLength,
	}
	row.sound:Destroy()
end

for ref, row in pairs(fonts) do
	out[ref] = { ok = row.ok, kind = "font", error = row.err }
end

return out
"""


class BridgeError(RuntimeError):
    pass


def bridge_exec(source: str, timeout: int = 300) -> Any:
    proc = subprocess.run(
        [sys.executable, str(REPO / "rqe.py"), "studio", "call", "bridge.exec",
         "--params", json.dumps({"source": source}), "--timeout", str(timeout)],
        capture_output=True, text=True, timeout=timeout + 30, cwd=str(REPO),
    )
    raw = proc.stdout.strip() or proc.stderr.strip()
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BridgeError(f"bridge did not return JSON: {exc}\n{raw[:300]}")
    if not envelope.get("ok"):
        raise BridgeError(json.dumps(envelope.get("error"))[:300])
    return envelope.get("result", {}).get("returned")


def _lua_list(refs: list[str]) -> str:
    return "{" + ", ".join('"' + r.replace('"', '\\"') + '"' for r in refs) + "}"


def verify(refs: list[str]) -> dict:
    """Load each reference in Studio and write the registry."""
    results: dict[str, Any] = {}
    # Batched: one bridge round trip per twenty ids rather than per id.
    for start in range(0, len(refs), 20):
        chunk = refs[start:start + 20]
        try:
            report = bridge_exec(_VERIFY_LUAU % {"refs": _lua_list(chunk)}) or {}
        except BridgeError as exc:
            report = {ref: {"ok": False, "error": str(exc)[:160]} for ref in chunk}
        results.update(report)
        for ref in chunk:
            row = results.get(ref) or {}
            mark = "OK " if row.get("ok") else "NAO"
            print(f"  {mark} {ref}  {row.get('error') or ''}", flush=True)

    registry = {
        "verifiedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "count": len(results),
        "passing": sum(1 for r in results.values() if r.get("ok")),
        "assets": results,
    }
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY.write_text(json.dumps(registry, indent=2, ensure_ascii=False), encoding="utf-8")
    return registry


def load_registry() -> dict[str, Any]:
    if not REGISTRY.exists():
        return {}
    try:
        return json.loads(REGISTRY.read_text(encoding="utf-8")).get("assets", {})
    except (json.JSONDecodeError, OSError):
        return {}
