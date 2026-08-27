"""Find sounds a game can actually play, and ship them as a bank.

The problem
-----------

`Forge.Audio` groups, ducks, randomises pitch and fades music -- and arrives
with nothing to play. So every game starts mute, and every author rediscovers
alone that **Roblox user audio has been private by default since 2022**: a
search returns hundreds of ids and almost none of them load in your place. One
report spent an entire working session to end up with nine usable ids.

The fix is not a bigger search. It is searching the one creator whose audio is
public by construction.

Why `creatorTargetId=1`
-----------------------

Roblox's own audio library is public, moderated, consistent in level, and
loadable from any place. Filtering the toolbox endpoint to that creator turns
"hundreds of results, nine usable" into "ten results, ten usable".

The older filter here looked for a `(SFX)` suffix, which Roblox used to append
to its library clips and no longer does -- it now matches nothing, which is why
the audio side of `forge shop` had no `--official` worth having.

Every id is then confirmed against the web API before it reaches the bank: the
type must really be Audio, and the asset must really exist. An invented id does
not fail loudly in Roblox. It is silence.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from . import local_credentials, toolbox

BANK_PATH = Path("forge/kits/sound-bank.json")
LUA_PATH = Path("forge/luau/Forge/Audio/Bank.lua")

#: Roles a game needs before it needs anything specific, and the words that
#: find them. Several terms per role because Roblox's own library names things
#: after the file it came from -- `bfsl-minifigfoots1.mp3` is a footstep and
#: says so nowhere.
ROLES: dict[str, tuple[str, ...]] = {
    "ui.click": ("click", "button click", "ui click"),
    "ui.hover": ("hover", "ui hover"),
    "ui.open": ("open", "menu open", "whoosh"),
    "ui.close": ("close", "menu close"),
    "ui.error": ("error", "denied", "buzz"),
    "ui.success": ("success", "chime", "ding"),
    "reward.coin": ("coin", "cash", "collect"),
    "reward.pickup": ("pickup", "item", "grab"),
    "reward.levelup": ("level up", "upgrade", "fanfare"),
    "player.footstep": ("footstep", "step", "walk"),
    "player.jump": ("jump", "hop"),
    "player.land": ("land", "thud", "impact"),
    "world.door": ("door", "gate"),
    "world.water": ("water", "splash"),
    "world.fire": ("fire", "flame", "burn"),
    "combat.hit": ("hit", "punch", "impact"),
    "combat.shoot": ("shoot", "gunshot", "laser"),
    "combat.explosion": ("explosion", "blast", "boom"),
    "machine.loop": ("machine", "engine", "motor", "hum"),
    "machine.clank": ("metal", "clank", "gear"),
}

#: Roblox's AssetTypeId for Audio. Anything else in an audio search is a
#: mistake somebody uploaded under the wrong category.
AUDIO_TYPE = 3


def _confirm(asset_id: int, key: str, timeout: float = 12.0) -> dict[str, Any] | None:
    """Ask the web API what this id really is. None when it is not usable audio."""
    request = urllib.request.Request(
        f"https://apis.roblox.com/assets/v1/assets/{asset_id}",
        headers={"x-api-key": key})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except (urllib.error.HTTPError, urllib.error.URLError, OSError, json.JSONDecodeError):
        return None

    if payload.get("assetType") != "Audio":
        return None
    moderation = (payload.get("moderationResult") or {}).get("moderationState")
    if moderation not in (None, "Approved"):
        return None
    return {
        "id": str(asset_id),
        "name": payload.get("displayName") or "",
        "state": payload.get("state"),
    }


def collect(per_role: int = 3, progress: Any = print) -> dict[str, Any]:
    """Search official audio for every role and confirm each id."""
    local_credentials.load()
    import os

    key = os.environ.get(local_credentials.ENV_VAR, "")
    if not key:
        raise RuntimeError(
            f"no credential; {local_credentials.ENV_VAR} is unset and no key file was found")

    bank: dict[str, list[dict[str, Any]]] = {}
    seen: dict[str, dict[str, Any] | None] = {}
    started = time.time()

    for role, terms in ROLES.items():
        picked: list[dict[str, Any]] = []
        for term in terms:
            if len(picked) >= per_role:
                break
            try:
                results = toolbox.search(term, limit=12,
                                         category=toolbox.CATEGORY_AUDIO,
                                         official=True)
            except Exception as error:  # noqa: BLE001 - one term must not end the run
                progress(f"  {role}/{term}: search failed ({error})")
                continue

            for candidate in results:
                if len(picked) >= per_role:
                    break
                asset_id = str(candidate.get("id") or "")
                if not asset_id or any(p["id"] == asset_id for p in picked):
                    continue
                if asset_id not in seen:
                    seen[asset_id] = _confirm(int(asset_id), key)
                confirmed = seen[asset_id]
                if not confirmed:
                    continue
                picked.append({**confirmed,
                               "duration": candidate.get("duration"),
                               "foundBy": term})

        bank[role] = picked
        progress(f"  {role:18} {len(picked)}/{per_role}")

    covered = sum(1 for entries in bank.values() if entries)
    book = {
        "$comment": (
            "Audio created by Roblox, which is public by construction and loads "
            "from any place. User uploads have been private by default since "
            "2022, so a general audio search returns ids that do not play -- and "
            "an id that does not play is silence, not an error. Every entry here "
            "was confirmed against the web API as an approved Audio asset."),
        "collectedAt": time.strftime("%Y-%m-%d"),
        "roles": bank,
        "rolesCovered": covered,
        "rolesTotal": len(ROLES),
        "seconds": round(time.time() - started),
    }
    BANK_PATH.parent.mkdir(parents=True, exist_ok=True)
    BANK_PATH.write_text(json.dumps(book, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return book


_HEADER = '''--!strict
--[[
	Bank — sounds every game can play, so no game starts mute.

	Generated by `rqe.assets.soundbank`; rewritten on collection, so do not edit
	it. Feed it straight to `Audio.defineMany`:

		Forge.Audio.defineMany(Forge.Audio.Bank.specs())

	Every id is Roblox's own audio. That is not a quality preference, it is the
	only category that reliably plays: **user uploads have been private by
	default since 2022**, so most ids a search returns will not load in your
	place -- and a sound that does not load is silence, not an error, which is
	the worst way for an asset to fail.

	Each was confirmed against the web API as an approved Audio asset before it
	was written here.

	%(covered)d of %(total)d roles covered. Collected %(when)s.
]]

local Bank = {}

Bank.roles = {
%(entries)s
}
'''

_FOOTER = '''
--[[
	Every role as `Audio.define` specs, ready to hand over whole.

	One sound per role -- the first, which is the best match the search found.
	A game wanting variety reads `Bank.roles` and picks its own.
]]
function Bank.specs(): { [string]: any }
	local out: { [string]: any } = {}
	for role, entries in Bank.roles do
		local first = entries[1]
		if first then
			out[role] = {
				id = "rbxassetid://" .. first.id,
				--: UI is quieter than the world by default; a click at full
				--: volume is the loudest thing in most games and should not be.
				volume = if string.sub(role, 1, 3) == "ui." then 0.4 else 0.6,
				group = if string.sub(role, 1, 3) == "ui." then "ui" else "sfx",
				--: A little pitch scatter, because a sound played twice at the
				--: same pitch is the tell that it is a recording.
				pitch = { 0.95, 1.05 },
			}
		end
	end
	return out
end

--: Every id filed under a role, for a game that wants to vary them.
function Bank.forRole(role: string): { any }
	return Bank.roles[role] or {}
end

function Bank.covered(): { string }
	local out = {}
	for role, entries in Bank.roles do
		if #entries > 0 then
			table.insert(out, role)
		end
	end
	table.sort(out)
	return out
end

return Bank
'''


def export_lua(book: dict[str, Any] | None = None) -> tuple[Path, int]:
    """Write the bank as a Luau module."""
    data = book or json.loads(BANK_PATH.read_text(encoding="utf-8"))
    roles = data.get("roles") or {}

    blocks = []
    for role in sorted(roles):
        entries = roles[role]
        if not entries:
            continue
        rows = []
        for entry in entries:
            name = str(entry.get("name", "")).replace("\\", "\\\\").replace('"', '\\"')
            rows.append(f'\t\t{{ id = "{entry["id"]}", name = "{name}" }},')
        blocks.append(f'\t["{role}"] = {{\n' + "\n".join(rows) + "\n\t},")

    LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
    LUA_PATH.write_text(
        _HEADER % {"covered": data.get("rolesCovered", 0),
                   "total": data.get("rolesTotal", len(ROLES)),
                   "when": data.get("collectedAt", "?"),
                   "entries": "\n".join(blocks)} + _FOOTER,
        encoding="utf-8")
    return LUA_PATH, sum(1 for r in roles.values() if r)
