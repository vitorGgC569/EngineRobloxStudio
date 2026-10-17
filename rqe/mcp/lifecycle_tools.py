"""The last of the twelve families: Studio lifecycle, assets and release.

All of it worked already. None of it was reachable through the protocol, which
meant an agent driving the engine had to shell out to reach the layer supposed
to be driving it.

Two tools here can destroy work or do something irreversible -- `studio_open`
replaces a running session, and `release_evaluate` is the gate itself. Both say
so, and the destructive one refuses without explicit confirmation. A tool that
discards unsaved edits on a default argument is a tool that will eventually do
it by accident.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .server import EngineMcpServer, Tool, ToolError
from ..security import SecurityBoundaryError, resolve_inside
from ..workspace import hub_url


def _inside(root: Path, relative: str, label: str, **checks: Any) -> Path:
    try:
        return resolve_inside(root, relative, label=label, **checks)
    except SecurityBoundaryError as exc:
        raise ToolError(str(exc)) from exc


def _bridge(arguments: dict[str, Any]):
    from ..hub.client import StudioBridge

    return StudioBridge(
        arguments.get("hub") or hub_url(),
        token=os.environ.get("RQE_BRIDGE_TOKEN"),
    )


def register_lifecycle_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    # ------------------------------------------------------------- lifecycle

    def studio_open(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..hub import lifecycle

        if arguments.get("confirmColdLaunch") is not True:
            raise ToolError(
                "cold-launching Studio can raise a visible window even when background mode "
                "is requested. Use studio_ensure first; pass confirmColdLaunch=true only "
                "when opening Studio is explicitly acceptable."
            )

        place = _inside(root, arguments["place"], "place", must_exist=True, file_only=True, suffixes=(".rbxl", ".rbxlx"))

        if lifecycle.studio_running() and arguments.get("confirmReplaceSession") is not True:
            # Opening a place while Studio is running either opens a second
            # window or replaces the session, and both lose whatever the first
            # one had not saved.
            raise ToolError(
                "Studio is already running; opening a place may discard unsaved work. "
                "Pass confirmReplaceSession=true to proceed, or use studio_status first."
            )

        detail = lifecycle.launch_studio(place, background=arguments.get("background", True))
        return {
            "place": str(place.relative_to(root)),
            "background": arguments.get("background", True),
            "detail": detail,
            # Launched is not attached. The plugin has to connect before any
            # command will reach this session.
            "note": "Studio was launched; the bridge is not attached until the plugin polls",
        }

    server.register(Tool(
        name="studio_open",
        description=(
            "Explicit cold launch of Roblox Studio. This may briefly create a visible window even "
            "in background mode, so confirmColdLaunch=true is required. Routine automation "
            "should use studio_ensure and reuse a persistent session."
        ),
        input_schema={
            "type": "object",
            "required": ["place"],
            "additionalProperties": False,
            "properties": {
                "place": {"type": "string", "minLength": 1},
                "background": {"type": "boolean"},
                "confirmColdLaunch": {"type": "boolean"},
                "confirmReplaceSession": {"type": "boolean"},
            },
        },
        handler=studio_open,
    ))



    def studio_ensure(arguments: dict[str, Any]) -> dict[str, Any]:
        """Reuse one compatible Studio session without surprising the user."""
        from ..hub import lifecycle

        place = _inside(
            root,
            arguments["place"],
            "place",
            must_exist=True,
            file_only=True,
            suffixes=(".rbxl", ".rbxlx"),
        )
        archive_root = _inside(
            root,
            arguments.get("archiveRoot", ".tmp/studio-recovery"),
            "archiveRoot",
        )
        archive_root.mkdir(parents=True, exist_ok=True)

        try:
            detail = lifecycle.ensure_studio_session(
                place,
                archive_root,
                _bridge(arguments),
                wait_seconds=float(arguments.get("waitSeconds", 45)),
                background=bool(arguments.get("background", True)),
                allow_cold_launch=bool(arguments.get("allowColdLaunch", False)),
            )
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        return {
            "place": str(place.relative_to(root)),
            "ready": bool(detail.get("ready")),
            "reused": bool(detail.get("reused")),
            "coldLaunched": bool(detail.get("coldLaunched")),
            "detail": detail,
        }

    server.register(Tool(
        name="studio_ensure",
        description=(
            "Reuse a compatible persistent Studio bridge session without foreground focus. "
            "By default this FAILS CLOSED instead of opening Studio. Pass allowColdLaunch=true "
            "only when a one-time cold Studio launch is explicitly acceptable."
        ),
        input_schema={
            "type": "object",
            "required": ["place"],
            "additionalProperties": False,
            "properties": {
                "place": {"type": "string", "minLength": 1},
                "archiveRoot": {"type": "string"},
                "waitSeconds": {"type": "number", "exclusiveMinimum": 0, "maximum": 180},
                "background": {"type": "boolean"},
                "allowColdLaunch": {"type": "boolean"},
                "hub": {"type": "string"},
            },
        },
        handler=studio_ensure,
    ))

    def studio_restart(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..hub import lifecycle

        if arguments.get("confirmDiscardUnsavedWork") is not True:
            raise ToolError(
                "restarting kills the running Studio and discards unsaved work; "
                "pass confirmDiscardUnsavedWork=true to proceed"
            )
        place = _inside(root, arguments["place"], "place", must_exist=True, file_only=True, suffixes=(".rbxl", ".rbxlx"))

        archive_root = _inside(
            root,
            arguments.get("archiveRoot", ".tmp/studio-recovery"),
            "archiveRoot",
        )
        archive_root.mkdir(parents=True, exist_ok=True)

        try:
            detail = lifecycle.restart_for_bridge(
                place,
                archive_root,
                bridge=_bridge(arguments),
                wait_seconds=float(arguments.get("waitSeconds", 180)),
                background=bool(arguments.get("background", True)),
            )
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc
        return {"place": str(place.relative_to(root)), "detail": detail}

    server.register(Tool(
        name="studio_restart",
        description=(
            "Stop Studio, archive recovery files, clear the place lock and relaunch on a "
            "clean place, then wait for the plugin. DESTRUCTIVE: unsaved work is lost."
        ),
        input_schema={
            "type": "object",
            "required": ["place"],
            "additionalProperties": False,
            "properties": {
                "place": {"type": "string", "minLength": 1},
                "archiveRoot": {"type": "string"},
                "waitSeconds": {"type": "number", "exclusiveMinimum": 0, "maximum": 300},
                "background": {"type": "boolean"},
                "hub": {"type": "string"},
                "confirmDiscardUnsavedWork": {"type": "boolean"},
            },
        },
        handler=studio_restart,
    ))

    def studio_play(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..hub import lifecycle

        bridge = _bridge(arguments)
        try:
            if arguments.get("stop"):
                detail = lifecycle.stop_play_solo(bridge)
                action = "stop"
            else:
                detail = lifecycle.start_play_solo(bridge, restart=arguments.get("restart", False))
                action = "start"
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc
        return {"action": action, "detail": detail}

    server.register(Tool(
        name="studio_play",
        description=(
            "Start or stop Play Solo through the native StudioTestService bridge. "
            "The normal path never focuses Studio or sends F5/Shift+F5; foreground "
            "fallbacks are disabled. Use studio_ensure first so this never cold-launches "
            "Studio unexpectedly."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "stop": {"type": "boolean"},
                "restart": {"type": "boolean"},
                "hub": {"type": "string"},
            },
        },
        handler=studio_play,
    ))

    # ---------------------------------------------------------------- assets

    def _operations(arguments: dict[str, Any]):
        """Bind the asset workspace to a provider.

        The provider is chosen explicitly rather than guessed. Roblox Open Cloud
        needs a key, and falling back to the local catalogue when one is absent
        would answer a question about Roblox with an answer about a directory --
        which reads as a working search right up until an agent tries to publish
        what it found.
        """

        from ..assets.operations import AssetOperations
        from ..assets.providers.local import LocalCatalogProvider
        from ..assets.providers.roblox import RobloxOpenCloudConfig, RobloxOpenCloudProvider

        workspace = _inside(root, arguments.get("workspace", ".tmp/assets"), "workspace")
        workspace.mkdir(parents=True, exist_ok=True)

        name = arguments.get("provider", "roblox")
        if name == "roblox":
            # The key comes from the environment and is never an argument, so a
            # credential cannot be written into an agent transcript. Absent, the
            # provider still constructs and reports itself BLOCKED, which is the
            # answer a caller needs rather than an exception.
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(api_key=os.environ.get("ROBLOX_OPEN_CLOUD_KEY"))
            )
        elif name == "local":
            from ..assets.catalog import AssetCatalog
            from ..project import read_json

            relative = arguments.get("catalog")
            if not relative:
                raise ToolError(
                    "the local provider needs a catalog path; there is no default, because "
                    "guessing one answers a question about assets with a different file"
                )
            catalog_path = _inside(root, relative, "catalog", must_exist=True, file_only=True, suffixes=(".json",))
            try:
                catalog = AssetCatalog.from_dict(read_json(catalog_path))
            except ValueError as exc:
                raise ToolError(f"{catalog_path} is not an asset catalogue: {exc}") from exc
            provider = LocalCatalogProvider(catalog)
        else:
            raise ToolError(f'provider must be "roblox" or "local", got {name!r}')

        return AssetOperations(provider, workspace)

    def asset_capabilities(arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            return _operations(arguments).capabilities()
        except ToolError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

    server.register(Tool(
        name="asset_capabilities",
        description=(
            "Which asset providers are usable and what blocks the rest. Missing "
            "credentials are a named blocker, never a silent failure."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "provider": {"enum": ["roblox", "local"]},
                "catalog": {"type": "string"},
                "workspace": {"type": "string"},
            },
        },
        handler=asset_capabilities,
    ))

    def asset_search(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..assets.models import AssetKind, SearchQuery

        kinds = tuple(
            AssetKind(value) for value in arguments.get("kinds", [])
        ) if arguments.get("kinds") else ()
        try:
            query = SearchQuery(
                text=arguments["query"],
                kinds=kinds,
                limit=int(arguments.get("limit", 25)),
            )
        except ValueError as exc:
            raise ToolError(str(exc)) from exc

        try:
            return _operations(arguments).search(query)
        except ToolError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

    server.register(Tool(
        name="asset_search",
        description=(
            "Search the asset catalogue with names, descriptions, previews and rights, so "
            "an existing asset can be chosen before a new one is made."
        ),
        input_schema={
            "type": "object",
            "required": ["query"],
            "additionalProperties": False,
            "properties": {
                "query": {"type": "string", "minLength": 1},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                "kinds": {"type": "array", "items": {"enum": ["mesh", "audio", "animation", "icon"]}},
                "provider": {"enum": ["roblox", "local"]},
                "catalog": {"type": "string"},
                "workspace": {"type": "string"},
            },
        },
        handler=asset_search,
    ))

    def asset_prepare(arguments: dict[str, Any]) -> dict[str, Any]:
        """Validate a work request and build an immutable publication package.

        The step between "a file exists" and "a file may be uploaded". It hashes
        the payload, checks it against its declared kind, and refuses a
        placeholder outright -- because a placeholder that reaches the upload
        step becomes an asset id nobody can tell apart from a real one.
        """

        request = _inside(root, arguments["request"], "request", must_exist=True, file_only=True, suffixes=(".json",))
        try:
            prepared, written = _operations(arguments).prepare_file(request)
        except ToolError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        payload = prepared.to_dict() if hasattr(prepared, "to_dict") else {}
        payload["files"] = {key: str(value) for key, value in (written or {}).items()}
        return payload

    server.register(Tool(
        name="asset_prepare",
        description=(
            "Turn a work request into a content-addressed publication package: validated, "
            "hashed, and refused outright if it is a placeholder."
        ),
        input_schema={
            "type": "object",
            "required": ["request"],
            "additionalProperties": False,
            "properties": {
                "request": {"type": "string", "minLength": 1},
                "provider": {"enum": ["roblox", "local"]},
                "catalog": {"type": "string"},
                "workspace": {"type": "string"},
            },
        },
        handler=asset_prepare,
    ))

    def asset_integrate(arguments: dict[str, Any]) -> dict[str, Any]:
        """Bind approved asset ids to the places in the game that use them.

        Only approved assets. A published id whose moderation is still pending
        will render as nothing in a live game, and binding it would put a hole
        in the build that no local check could find.
        """

        from ..assets.catalog import AssetCatalog
        from ..assets.integration import build_integration_bundle
        from ..project import read_json

        catalog_path = _inside(root, arguments["catalog"], "catalog", must_exist=True, file_only=True, suffixes=(".json",))
        try:
            catalog = AssetCatalog.from_dict(read_json(catalog_path))
        except ValueError as exc:
            raise ToolError(f"{catalog_path} is not an asset catalogue: {exc}") from exc

        try:
            bundle = build_integration_bundle(catalog)
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        payload = bundle.to_dict() if hasattr(bundle, "to_dict") else {}
        bindings = payload.get("bindings") or []
        return {
            "catalog": str(catalog_path.relative_to(root)),
            "bindings": len(bindings),
            "bound": [item.get("assetKey") for item in bindings if isinstance(item, dict)],
            "bundle": payload,
        }

    server.register(Tool(
        name="asset_integrate",
        description=(
            "Build the binding bundle from approved assets to the places that reference "
            "them. Pending moderation is excluded: an unapproved id renders as nothing."
        ),
        input_schema={
            "type": "object",
            "required": ["catalog"],
            "additionalProperties": False,
            "properties": {"catalog": {"type": "string", "minLength": 1}},
        },
        handler=asset_integrate,
    ))

    # --------------------------------------------------------------- release

    def release_evaluate(arguments: dict[str, Any]) -> dict[str, Any]:
        """Run the gate and return its verdict.

        Read-only against the game: it measures, scores and refuses. What it
        cannot do is promote -- that is a separate decision, and folding the two
        together is how a gate becomes a rubber stamp.
        """

        from ..release import execute_release

        try:
            outcome = execute_release(
                root,
                static_only=bool(arguments.get("staticOnly", True)),
            )
        except TypeError:
            try:
                outcome = execute_release(root)
            except Exception as exc:  # noqa: BLE001
                raise ToolError(f"{type(exc).__name__}: {exc}") from exc
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        payload = outcome.to_dict() if hasattr(outcome, "to_dict") else {}
        gate = payload.get("gate") or {}
        blockers = gate.get("blockers") or payload.get("blockers") or []
        return {
            "releaseAllowed": bool(gate.get("releaseAllowed", payload.get("releaseAllowed", False))),
            "runId": payload.get("runId"),
            "blockerCount": len(blockers),
            # Truncated deliberately: a list nobody can read is a list nobody
            # acts on, and the run artifact holds the rest.
            "blockers": blockers[:15],
            "scores": gate.get("scores") or payload.get("scores"),
            "coverage": gate.get("coverage") or payload.get("coverage"),
        }

    server.register(Tool(
        name="release_evaluate",
        description=(
            "Run the fail-closed release gate and return its verdict, scores and "
            "blockers. Measures and refuses; it cannot promote."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {"staticOnly": {"type": "boolean"}},
        },
        handler=release_evaluate,
    ))

    return server
