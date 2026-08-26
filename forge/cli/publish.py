"""Push a built place to Roblox as a private version.

Why this exists
---------------

Five scenarios in the live suite fail with "You must publish this place to the
web to access DataStore". They are not broken: `Save`, `Monetization` and every
piece of persistence in this engine talk to a real service that a local .rbxlx
cannot reach. The only way to test them is to publish, and the only way to
publish repeatedly is to automate it.

What Open Cloud can and cannot do
---------------------------------

It can upload a place file as a new version of an experience that already
exists. It **cannot create an experience** — there is no endpoint for it, and
that is a Roblox limitation rather than a missing feature here. Creating the
experience is a one-time action in Studio (File > Publish to Roblox As...) or
on roblox.com; after that this command owns every subsequent push.

    forge publish provingground            save a private version
    forge publish provingground --release   push it live to running servers

`Saved` is the default and `Released` is opt-in, because releasing pushes to
every live server and a default that does that eventually does it by accident.
A saved version is private: it exists in the experience's version history and
nobody is playing it, which is exactly what a persistence test needs.

Credentials
-----------

The key comes from `ROBLOX_OPEN_CLOUD_KEY` in the environment and is never
accepted as an argument, never logged and never written to a file by this
module. If a key file is configured, it is read straight into the environment
of the call — so it appears in no command line and no shell history.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
CONFIG = REPO / "forge" / "catalog" / "publish.json"

#: Where a key may be kept locally. Excluded from git by `.gitignore`'s
#: blanket `*.txt` rule, which exists for exactly this reason.
DEFAULT_KEY_FILE = REPO / "docs" / "goal" / "key.txt"


class PublishError(RuntimeError):
    pass


def load_key() -> str:
    """The Open Cloud key, from the environment or a local file.

    Returned rather than printed, and every caller passes it straight into a
    request header. Nothing in this module writes it anywhere.
    """
    key = os.environ.get("ROBLOX_OPEN_CLOUD_KEY")
    if key:
        return key.strip()
    if DEFAULT_KEY_FILE.exists():
        return DEFAULT_KEY_FILE.read_text(encoding="utf-8", errors="ignore").strip()
    raise PublishError(
        "no Open Cloud key: set ROBLOX_OPEN_CLOUD_KEY, or put one in "
        f"{DEFAULT_KEY_FILE.relative_to(REPO)}")


def targets() -> dict[str, Any]:
    """Which experience each game publishes to."""
    if not CONFIG.exists():
        return {}
    try:
        return json.loads(CONFIG.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def remember(game: str, universe_id: str, place_id: str) -> Path:
    """Record where a game publishes, so it only has to be said once."""
    data = targets()
    data[game] = {"universeId": str(universe_id), "placeId": str(place_id)}
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(data, indent=2), encoding="utf-8")
    return CONFIG


def _request(method: str, url: str, key: str, body: bytes | None = None,
             content_type: str | None = None, timeout: int = 120):
    import urllib.error
    import urllib.request

    headers = {"x-api-key": key}
    if content_type:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except urllib.error.URLError as exc:
        raise PublishError(f"cannot reach Roblox: {exc.reason}")


def check_key(universe_id: str = "1") -> dict[str, Any]:
    """Is the key valid at all?

    Distinguishes the two failures that look identical from the outside. A bad
    key answers 401; a good key pointed at a universe it has no rights over
    answers 403 or 404. Asking about a universe that certainly is not yours is
    therefore a clean test of the credential by itself, before any place id is
    known.
    """
    key = load_key()
    status, body = _request(
        "GET", f"https://apis.roblox.com/cloud/v2/universes/{universe_id}", key)
    if status == 401:
        return {"ok": False, "status": status,
                "meaning": "the key is not valid, or has expired"}
    if status in (403, 404):
        return {"ok": True, "status": status,
                "meaning": "the key authenticates; it has no rights over that universe, "
                           "which is expected for a probe"}
    if 200 <= status < 300:
        return {"ok": True, "status": status, "meaning": "the key authenticates"}
    return {"ok": False, "status": status, "meaning": body[:200]}


def publish(game: str, release: bool = False,
            universe_id: str | None = None, place_id: str | None = None) -> dict[str, Any]:
    """Upload the built place file as a new version."""
    known = targets().get(game, {})
    universe = universe_id or known.get("universeId")
    place = place_id or known.get("placeId")
    if not universe or not place:
        raise PublishError(
            f"no experience recorded for '{game}'. Create one once in Studio "
            "(File > Publish to Roblox As...), then run:\n"
            f"    forge publish {game} --universe <id> --place <id>\n"
            "The ids are in the address bar of the experience's page: "
            "roblox.com/games/<placeId>/... and the universe id is on the "
            "Creator Dashboard.")

    built = REPO / "games" / game / f"{game}.rbxlx"
    if not built.exists():
        raise PublishError(f"nothing built at {built.relative_to(REPO)}; run 'forge build {game}'")

    payload = built.read_bytes()
    version_type = "Published" if release else "Saved"
    key = load_key()

    status, body = _request(
        "POST",
        f"https://apis.roblox.com/universes/v1/{universe}/places/{place}"
        f"/versions?versionType={version_type}",
        key,
        body=payload,
        content_type="application/xml",
        timeout=600,
    )

    if 200 <= status < 300:
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"raw": body[:200]}
        remember(game, universe, place)
        return {"ok": True, "versionType": version_type,
                "versionNumber": parsed.get("versionNumber"),
                "bytes": len(payload)}

    hint = ""
    if status == 401:
        hint = "the key did not authenticate"
    elif status == 403:
        hint = ("the key authenticated but lacks universe.place:write on this "
                "experience, or its IP allow-list excludes this machine")
    elif status == 404:
        hint = "no such universe or place id"
    elif status == 409:
        # Roblox answers "Save failed. Server is busy and unable to process
        # your upload request. Please try again in a couple minutes."
        #
        # What has been ruled out, by measurement rather than by reasoning:
        #
        #   * size -- refused at 139MB and again at 1.4MB
        #   * Studio holding the place open -- refused with Studio killed
        #   * key permission -- a no-op PATCH to the same place returned 200
        #     throughout, on both this universe and another
        #   * versionType -- refused as Saved and as Published, and a run of
        #     two consecutive successes included one of each
        #
        # What is left, and what the successes have in common, is elapsed time:
        # the pair that went through followed a long gap, and the refusals
        # cluster immediately after a recent upload. So this reads as a rate
        # limit on the endpoint wearing a misleading message.
        #
        # Stated as a suspicion rather than a cause, because two confident
        # explanations were written here first and both were wrong.
        hint = ("Roblox refused the upload; this endpoint appears to rate-limit "
                "and reports it as 'server is busy'. Wait several minutes and "
                "retry -- size, Studio, versionType and key permission have all "
                "been ruled out")
    return {"ok": False, "status": status, "hint": hint, "body": body[:300]}
