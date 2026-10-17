"""Getting a game off this machine.

Every game the factory builds ends as an `.rbxlx` on disk. `sourcing_publish`
puts *assets* on the account, and that loop is proven end to end -- but an asset
is not a game. Nobody can play a file in `games/`.

`rqe/cloud/open_cloud.py` has had `publish_place` and `list_versions` for a
while and neither had a tool, which is the same shape as the seven staging
capabilities: written, tested, unreachable.

**Two honest limits, stated here rather than discovered at the API.**

Open Cloud cannot create an experience. There is no endpoint for it -- a
universe and its start place have to exist already, made once in Studio or on
the website. So these tools ship *into* a place; they do not conjure one. The
tool says so plainly instead of failing with a 404 that reads like a bug.

Saving is not releasing. `versionType=Saved` uploads a version nobody is playing
yet; `Published` pushes it to every live server immediately. The default is
Saved, and releasing takes `release: true` -- an irreversible act should need a
word, the same reason `sourcing_publish` is not a flag on `sourcing_adopt`.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .server import Tool, ToolError
from ..assets import local_credentials
from ..security import SecurityBoundaryError, resolve_inside


MAX_PLACE_BYTES = 128 * 1024 * 1024


def _key(server: Any) -> tuple[str | None, str | None]:
    """The Open Cloud key, read from disk and never returned.

    It reaches an HTTP header and nothing else: not a log line, not a tool
    result, not an argument a caller could paste into a transcript.
    """

    local_credentials.load(root=server.root)
    key = os.environ.get(local_credentials.ENV_VAR, "").strip()
    if not key:
        return None, (
            "ROBLOX_OPEN_CLOUD_KEY is unset and no credential exists at "
            f"{server.root / local_credentials.RELATIVE_KEY_PATH}"
        )
    return key, None


def register_place_tools(server: Any) -> Any:
    """Attach place publication and version listing."""

    from ..cloud.open_cloud import OpenCloudClient

    def _client() -> tuple[Any, str | None]:
        key, why = _key(server)
        if key is None:
            return None, why
        # Handed in as this client's environment, which is where it reads
        # credentials from -- so the key stays out of every call signature.
        return OpenCloudClient(
            environment={"ROBLOX_OPEN_CLOUD_KEY": key}), None

    def place_publish(arguments: dict[str, Any]) -> dict[str, Any]:
        universe = str(arguments.get("universeId") or "").strip()
        place = str(arguments.get("placeId") or "").strip()
        if not universe or not place:
            return {
                "published": False,
                "error": "universeId and placeId are both required",
                "why": (
                    "Open Cloud has no endpoint that creates an experience. The "
                    "universe and its start place must already exist -- make one "
                    "once in Studio (File > Publish to Roblox) or on "
                    "create.roblox.com, then these ids ship every later build "
                    "into it."
                ),
            }

        game_id = str(arguments.get("gameId") or "").strip()
        given = arguments.get("placeFile")
        try:
            if given:
                path = resolve_inside(
                    server.root,
                    str(given),
                    label="placeFile",
                    must_exist=True,
                    file_only=True,
                    suffixes=(".rbxl", ".rbxlx"),
                )
            elif game_id:
                game_root = resolve_inside(
                    server.root / "games",
                    game_id,
                    label="gameId",
                    must_exist=True,
                    directory_only=True,
                )
                candidates = sorted(
                    item for item in game_root.iterdir()
                    if item.is_file() and item.suffix.lower() in {".rbxl", ".rbxlx"}
                )
                if not candidates:
                    return {"published": False,
                            "error": f"no .rbxlx or .rbxl in games/{game_id}"}
                path = candidates[0]
            else:
                return {"published": False,
                        "error": "give either gameId or placeFile"}
        except SecurityBoundaryError as exc:
            raise ToolError(str(exc)) from exc

        size = path.stat().st_size
        if size > MAX_PLACE_BYTES:
            raise ToolError(f"place file exceeds the {MAX_PLACE_BYTES}-byte publication limit")
        payload = path.read_bytes()
        client, why = _client()
        if client is None:
            return {"published": False, "error": why}

        release = bool(arguments.get("release"))
        result = client.publish_place(
            universe, place, payload,
            published=release,
            # `.rbxl` is the binary format and `.rbxlx` the XML one; sending the
            # wrong content type is accepted and then fails on the far side,
            # which is the worst way for this to go wrong.
            binary=path.suffix.lower() == ".rbxl",
        )

        return {
            "published": result.outcome.name == "SUCCEEDED",
            "outcome": result.outcome.name,
            "versionType": "Published" if release else "Saved",
            "placeFile": str(path),
            "bytes": len(payload),
            "response": getattr(result, "data", None),
            "error": getattr(result, "error", None),
            "note": (
                "released to every live server"
                if release else
                "saved as a version, not released -- pass release:true to push it live"
            ),
        }

    def place_versions(arguments: dict[str, Any]) -> dict[str, Any]:
        universe = str(arguments.get("universeId") or "").strip()
        place = str(arguments.get("placeId") or "").strip()
        if not universe or not place:
            return {"error": "universeId and placeId are both required"}
        client, why = _client()
        if client is None:
            return {"error": why}
        result = client.list_versions(
            universe, place, limit=int(arguments.get("limit") or 25))
        return {
            "outcome": result.outcome.name,
            "versions": getattr(result, "data", None),
            "error": getattr(result, "error", None),
        }

    server.register(Tool(
        name="place_publish",
        description=(
            "Ship a built game into an existing Roblox experience. Saves a "
            "version by default; pass release:true to push it to every live "
            "server. Needs universeId and placeId -- Open Cloud cannot create "
            "an experience, only ship into one."
        ),
        input_schema={
            "type": "object",
            "required": ["universeId", "placeId"],
            "properties": {
                "universeId": {"type": "string"},
                "placeId": {"type": "string"},
                "gameId": {"type": "string",
                           "description": "a folder under games/; finds the place file"},
                "placeFile": {"type": "string",
                              "description": "explicit path, instead of gameId"},
                "release": {
                    "type": "boolean",
                    "description": "push live now, rather than saving a version",
                },
            },
        },
        handler=place_publish,
    ))

    server.register(Tool(
        name="place_versions",
        description=(
            "Every version of a place, newest first -- the other half of a "
            "rollback. Publishing without seeing what came before is a one-way "
            "door."
        ),
        input_schema={
            "type": "object",
            "required": ["universeId", "placeId"],
            "properties": {
                "universeId": {"type": "string"},
                "placeId": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
            },
        },
        handler=place_versions,
    ))

    return server
