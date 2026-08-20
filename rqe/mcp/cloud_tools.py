"""Open Cloud, exposed over MCP.

The half of Roblox that needs no desktop. `cloud_publish` and `cloud_versions`
are the pair that make CI real: build with Rojo, publish a version, run a Luau
task against it, measure the result -- with no Studio and no machine that has to
stay awake.

The API key is read from the environment and never accepted as an argument, so a
credential cannot be written into an agent transcript.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .server import EngineMcpServer, Tool, ToolError


def _client():
    from ..cloud import OpenCloudClient

    return OpenCloudClient()


def _target(arguments: dict[str, Any]) -> tuple[str, str]:
    universe = arguments.get("universeId") or os.environ.get("ROBLOX_UNIVERSE_ID", "")
    place = arguments.get("placeId") or os.environ.get("ROBLOX_PLACE_ID", "")
    if not universe:
        raise ToolError("universeId is required, directly or via ROBLOX_UNIVERSE_ID")
    return universe, place


def register_cloud_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def cloud_inspect(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..cloud import summarise

        universe, place = _target(arguments)
        client = _client()
        results = {"universe": client.universe(universe)}
        if place:
            results["place"] = client.place(universe, place)
            results["versions"] = client.list_versions(universe, place, limit=5)
        return summarise(results)

    server.register(Tool(
        name="cloud_inspect",
        description=(
            "Read a universe, its place and recent versions through Open Cloud. A missing "
            "key is BLOCKED and a refused key is DENIED with the scope it needs; neither "
            "is confused with an empty answer."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "universeId": {"type": "string"},
                "placeId": {"type": "string"},
            },
        },
        handler=cloud_inspect,
    ))

    def cloud_publish(arguments: dict[str, Any]) -> dict[str, Any]:
        universe, place = _target(arguments)
        if not place:
            raise ToolError("placeId is required to publish")

        relative = arguments["placeFile"]
        path = (root / relative).resolve()
        try:
            path.relative_to(root.resolve())
        except ValueError as exc:
            raise ToolError("placeFile must stay inside the project root") from exc
        if not path.is_file():
            raise ToolError(f"place file not found: {path}")

        published = bool(arguments.get("publish", False))
        if published and arguments.get("confirmPublish") is not True:
            # Publishing pushes to every live server. Refused rather than
            # warned, because a default that ships is a default that eventually
            # ships by accident.
            raise ToolError(
                "publishing releases the version to every live server; pass "
                "confirmPublish=true alongside publish=true"
            )

        payload = path.read_bytes()
        result = _client().publish_place(
            universe, place, payload,
            published=published,
            binary=path.suffix.lower() == ".rbxl",
        )
        return {
            "placeFile": str(path.relative_to(root)),
            "bytes": len(payload),
            "versionType": "Published" if published else "Saved",
            **result.to_dict(),
        }

    server.register(Tool(
        name="cloud_publish",
        description=(
            "Upload a place file as a new version. Saves by default; releasing it to live "
            "servers requires explicit confirmation."
        ),
        input_schema={
            "type": "object",
            "required": ["placeFile"],
            "additionalProperties": False,
            "properties": {
                "placeFile": {"type": "string", "minLength": 1},
                "universeId": {"type": "string"},
                "placeId": {"type": "string"},
                "publish": {"type": "boolean"},
                "confirmPublish": {"type": "boolean"},
            },
        },
        handler=cloud_publish,
    ))

    def cloud_asset(arguments: dict[str, Any]) -> dict[str, Any]:
        return _client().asset(arguments["assetId"]).to_dict()

    server.register(Tool(
        name="cloud_asset",
        description=(
            "Read an asset's metadata and moderation state. A published asset id is not "
            "an approved one, and this is where the difference is visible."
        ),
        input_schema={
            "type": "object",
            "required": ["assetId"],
            "additionalProperties": False,
            "properties": {"assetId": {"type": "string", "minLength": 1}},
        },
        handler=cloud_asset,
    ))

    def cloud_datastore(arguments: dict[str, Any]) -> dict[str, Any]:
        universe, _ = _target(arguments)
        client = _client()
        if arguments.get("entryId"):
            result = client.datastore_entry(
                universe,
                arguments["datastore"],
                arguments["entryId"],
                scope=arguments.get("scope", "global"),
            )
        else:
            result = client.list_datastores(universe)
        return result.to_dict()

    server.register(Tool(
        name="cloud_datastore",
        description=(
            "List data stores, or read one entry. Turns a persistence claim into "
            "evidence: a save only the game can read is a save nobody can verify."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "universeId": {"type": "string"},
                "datastore": {"type": "string"},
                "entryId": {"type": "string"},
                "scope": {"type": "string"},
            },
        },
        handler=cloud_datastore,
    ))

    def cloud_datastore_test_session(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..cloud.datastore_harness import DatastoreHarness

        universe, _ = _target(arguments)
        datastore = str(arguments.get("datastore") or "RQE_PersistenceTest")
        run_id = str(arguments.get("runId") or "datastore-test-adhoc")
        simulated = bool(arguments.get("simulated", False))
        harness = DatastoreHarness(client=_client(), simulated=simulated)
        receipt = harness.run_test_session(
            universe_id=universe,
            datastore=datastore,
            run_id=run_id,
            scope=str(arguments.get("scope") or "global"),
        )
        return receipt.to_dict()

    server.register(Tool(
        name="cloud_datastore_test_session",
        description=(
            "Run an end-to-end DataStore transactional test session (write, read, update, verify, cleanup) "
            "against Open Cloud or a simulated test sandbox. Produces an immutable persistence receipt."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "universeId": {"type": "string"},
                "datastore": {"type": "string"},
                "runId": {"type": "string"},
                "scope": {"type": "string"},
                "simulated": {"type": "boolean"},
            },
        },
        handler=cloud_datastore_test_session,
    ))

    return server
