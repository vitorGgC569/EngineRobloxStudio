"""The engine surface: know, write, run, see, place.

This is the half of the platform that helps somebody *program* rather than the
half that builds things for them. Five groups, and none of them decides anything
about the game:

    sdk_*        what exists, what it takes, what the source says
    code_*       write files that stay, reload without restarting
    run / test   execute anywhere, assert inside the engine
    dm_* watch   what is there now, what changed while you were not looking
    place_*      put things where you want, by coordinate or by relation

**Nothing here validates a design.** The refusals that remain are the ones that
translate Roblox's silent failures -- a weld between anchored parts, a command in
the wrong context. Those do not restrict anybody: they say the engine has just
ignored what was asked.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .server import Tool, ToolError


def _call(method: str, params: dict[str, Any], *, timeout: float = 60.0,
          context: str | None = None, allow_arbitrary: bool = False) -> dict[str, Any]:
    """One bridge call, with the failure returned rather than raised."""

    from ..hub.client import StudioBridge
    from ..hub.commands import load_default_registry

    bridge = StudioBridge(allow_arbitrary=allow_arbitrary)
    try:
        if context == "running":
            bridge.pin_to_running()
        else:
            bridge.pin_to_any()
        spec = load_default_registry(verify_dispatcher=False).require(method)
        if spec.lease_targeted:
            with bridge.lease_scope(
                agent_id="mcp-engine-tools",
                ttl_seconds=max(30.0, min(timeout + 30.0, 300.0)),
            ):
                result = bridge.call(method, params, timeout=timeout)
        else:
            result = bridge.call(method, params, timeout=timeout)
        return {"ok": True, "result": result}
    except Exception as error:  # noqa: BLE001
        return {"ok": False, "error": str(error)}


def register_programming_tools(server: Any) -> Any:
    """Attach the programming surface."""

    from .. import sdkindex

    # -- knowing --------------------------------------------------------

    def sdk_signature(arguments: dict[str, Any]) -> dict[str, Any]:
        return sdkindex.signature(server.root, str(arguments["name"]))

    def sdk_search(arguments: dict[str, Any]) -> dict[str, Any]:
        return sdkindex.search(
            server.root, str(arguments["query"]),
            limit=int(arguments.get("limit") or 12))

    def sdk_source(arguments: dict[str, Any]) -> dict[str, Any]:
        around = arguments.get("lines")
        return sdkindex.source(
            server.root, str(arguments["name"]),
            around=int(around) if around is not None else None)

    def reuse_search(arguments: dict[str, Any]) -> dict[str, Any]:
        """The four shelves at once: engine, second library, games, kits.

        `sdk_search` above reads library source and answers with signatures.
        It cannot see `games/` or `forge/kits/`, and a kit is a *finished game*
        -- the single most expensive thing in this repository to miss. An agent
        began writing a zombie system with a complete, running zombie survival
        game in `forge/kits/infected/`, and the reason was not missing
        information: it was that the only command that searched kits was the
        CLI, and an agent driving through MCP had no route to it.

        Same corpus, same ranking and same output as `forge find`, so the two
        front doors cannot answer differently.
        """

        import sys

        root = str(server.root)
        if root not in sys.path:
            sys.path.insert(0, root)
        from forge.cli.find import render, search

        query = str(arguments["query"])
        limit = int(arguments.get("limit", 8))
        results = search(query, limit=limit)
        return {
            "query": query,
            "shelves": {
                shelf: [
                    {
                        "name": hit.name,
                        "where": hit.where,
                        "summary": hit.summary[:300],
                        "detail": list(hit.detail[:6]),
                        "score": hit.score,
                    }
                    for hit in hits
                ]
                for shelf, hits in results.items()
            },
            "report": render(query, results),
        }

    def sdk_surface(_arguments: dict[str, Any]) -> dict[str, Any]:
        return sdkindex.surface(server.root)

    def sdk_skeleton(arguments: dict[str, Any]) -> dict[str, Any]:
        """A whole game as readable starting code."""

        folder = server.root / "roblox" / "skeletons"
        available = sorted(path.stem.replace(".server", "") for path in folder.glob("*.lua"))
        name = str(arguments.get("name") or "").strip()
        if not name:
            return {
                "skeletons": available,
                "note": (
                    "these are starting points, not generators: read one, change "
                    "it, delete the half you do not want. Nothing depends on their shape"
                ),
            }
        for path in folder.glob("*.lua"):
            if path.stem.replace(".server", "") == name:
                text = path.read_text(encoding="utf-8")
                return {
                    "name": name,
                    "file": str(path.relative_to(server.root)).replace("\\", "/"),
                    "lines": text.count("\n") + 1,
                    "source": text,
                }
        return {"error": f"no skeleton {name!r}", "skeletons": available}

    # -- writing --------------------------------------------------------

    def code_write(arguments: dict[str, Any]) -> dict[str, Any]:
        import os
        import tempfile

        from ..security import SecurityBoundaryError, resolve_inside

        path = str(arguments["path"])
        source = str(arguments["source"])
        kind = str(arguments.get("kind") or "module")

        if len(source.encode("utf-8")) > 1_048_576:
            return {"written": False, "error": "source exceeds the 1 MiB code_write limit"}

        disk = arguments.get("file")
        target = None
        staged = None
        if disk:
            try:
                target = resolve_inside(
                    server.root,
                    str(disk),
                    label="code_write file",
                    suffixes=(".lua", ".luau"),
                )
            except SecurityBoundaryError as exc:
                return {"written": False, "error": str(exc)}
            if target.exists() and not bool(arguments.get("overwrite")):
                try:
                    unchanged = target.read_text(encoding="utf-8") == source
                except OSError:
                    unchanged = False
                if not unchanged:
                    return {
                        "written": False,
                        "error": (
                            f"{disk} already exists; read it first and pass overwrite:true "
                            "only when replacing it is intentional"
                        ),
                    }
        # Compile first. A module written with a syntax error becomes a module
        # that fails at require time with a message naming nothing, which is
        # exactly the trap this surface exists to remove.
        checked = _call("code.compile", {"source": source})
        if checked.get("ok"):
            report = checked["result"]
            if report.get("compiles") is False:
                return {
                    "written": False,
                    "compiles": False,
                    "error": report.get("error"),
                    "line": report.get("line"),
                    "note": "not written; fix the syntax and call again",
                }

        if target is not None:
            target.parent.mkdir(parents=True, exist_ok=True)
            handle, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
            staged = Path(temporary)
            try:
                with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
                    stream.write(source)
            except BaseException:
                staged.unlink(missing_ok=True)
                raise

        try:
            answer = _call("code.write", {"path": path, "source": source, "kind": kind})
        except BaseException:
            if staged is not None:
                staged.unlink(missing_ok=True)
            raise
        if not answer.get("ok"):
            if staged is not None:
                staged.unlink(missing_ok=True)
            return {"written": False, "error": answer.get("error")}

        # Keep the file on disk too, when the caller aims at the library. The
        # place is where it runs; the repository is where it survives a rebuild.
        if target is not None and staged is not None:
            os.replace(staged, target)
            sdkindex.refresh()

        result = dict(answer["result"])
        result["written"] = True
        result["savedTo"] = str(disk) if disk else None
        return result

    def code_reload(arguments: dict[str, Any]) -> dict[str, Any]:
        params: dict[str, Any] = {"path": str(arguments["path"])}
        if arguments.get("source"):
            params["source"] = str(arguments["source"])
        answer = _call("code.reload", params)
        if not answer.get("ok"):
            return {"reloaded": False, "error": answer.get("error")}
        return answer["result"]

    def code_read(arguments: dict[str, Any]) -> dict[str, Any]:
        answer = _call("code.read", {"path": str(arguments["path"])})
        return answer.get("result", answer)

    def code_list(arguments: dict[str, Any]) -> dict[str, Any]:
        answer = _call("code.list", {"path": str(arguments.get("path") or "ReplicatedStorage")})
        return answer.get("result", answer)

    def code_at_start(arguments: dict[str, Any]) -> dict[str, Any]:
        answer = _call("code.at_start", {
            "source": str(arguments["source"]),
            "name": str(arguments.get("name") or "RQEStartup"),
            "client": bool(arguments.get("client")),
        })
        return answer.get("result", answer)

    # -- running --------------------------------------------------------

    def run_luau(arguments: dict[str, Any]) -> dict[str, Any]:
        from .capabilities import require_arbitrary_code

        require_arbitrary_code()
        source = str(arguments["source"])
        where = str(arguments.get("context") or "any")
        answer = _call(
            "bridge.exec",
            {"source": source, "chunkName": str(arguments.get("name") or "rqe.run")},
            timeout=float(arguments.get("timeout") or 60.0),
            context="running" if where in ("server", "run", "running") else None,
            allow_arbitrary=True,
        )
        if not answer.get("ok"):
            return {"ran": False, "error": answer.get("error")}
        result = dict(answer["result"])
        result["ran"] = True
        return result

    def code_compile(arguments: dict[str, Any]) -> dict[str, Any]:
        answer = _call("code.compile", {"source": str(arguments["source"])})
        return answer.get("result", answer)

    def test_run(arguments: dict[str, Any]) -> dict[str, Any]:
        from .capabilities import require_arbitrary_code

        require_arbitrary_code()
        answer = _call("test.run", {
            "source": str(arguments["source"]),
        }, timeout=float(arguments.get("timeout") or 90.0), allow_arbitrary=True)
        if not answer.get("ok"):
            return {"ran": False, "error": answer.get("error")}
        return answer["result"]

    # -- seeing ---------------------------------------------------------

    def dm_inspect(arguments: dict[str, Any]) -> dict[str, Any]:
        answer = _call("dm.inspect", {
            "path": str(arguments["path"]),
            "source": bool(arguments.get("source")),
        })
        return answer.get("result", answer)

    def logs_tail(arguments: dict[str, Any]) -> dict[str, Any]:
        answer = _call("log.tail", {"limit": int(arguments.get("limit") or 80)})
        return answer.get("result", answer)

    def watch_attribute(arguments: dict[str, Any]) -> dict[str, Any]:
        action = str(arguments.get("action") or "read")
        method = {"start": "watch.start", "read": "watch.read", "stop": "watch.stop"}.get(action)
        if method is None:
            return {"ok": False, "error": "action must be start, read or stop"}
        answer = _call(method, {
            "path": str(arguments["path"]),
            "attribute": str(arguments["attribute"]),
        })
        return answer.get("result", answer)

    # -- placing ---------------------------------------------------------

    def place_transform(arguments: dict[str, Any]) -> dict[str, Any]:
        action = str(arguments.get("action") or "bounds")
        path = str(arguments["path"])

        if action == "bounds":
            answer = _call("transform.bounds", {"path": path})
        elif action == "move":
            params: dict[str, Any] = {"path": path}
            if arguments.get("to") is not None:
                params["to"] = list(arguments["to"])
            if arguments.get("by") is not None:
                params["by"] = list(arguments["by"])
            answer = _call("transform.move", params)
        elif action == "orient":
            params = {"path": path}
            if arguments.get("rotate") is not None:
                params["rotate"] = list(arguments["rotate"])
            if arguments.get("scale") is not None:
                params["scale"] = float(arguments["scale"])
            answer = _call("transform.orient", params)
        elif action == "align":
            answer = _call("transform.align", {
                "path": path,
                "to": str(arguments["to"]),
                "face": str(arguments.get("face") or "top"),
                "gap": float(arguments.get("gap") or 0),
                "centred": bool(arguments.get("centred")),
            })
        elif action == "snap":
            answer = _call("transform.snap", {
                "path": path,
                "grid": float(arguments.get("grid") or 4),
                "axes": str(arguments.get("axes") or "xz"),
            })
        elif action == "settle":
            answer = _call("transform.settle", {"path": path})
        else:
            return {"ok": False,
                    "error": f"no action {action!r}; have bounds, move, orient, "
                             "align, snap, settle"}

        return answer.get("result", answer)

    def place_query(arguments: dict[str, Any]) -> dict[str, Any]:
        if arguments.get("a") and arguments.get("b"):
            answer = _call("transform.overlaps", {
                "a": str(arguments["a"]), "b": str(arguments["b"])})
        elif arguments.get("point"):
            params: dict[str, Any] = {"point": list(arguments["point"])}
            if arguments.get("within"):
                params["within"] = str(arguments["within"])
            if arguments.get("className"):
                params["className"] = str(arguments["className"])
            answer = _call("transform.nearest", params)
        else:
            return {"ok": False, "error": "give a and b to test overlap, or a point"}
        return answer.get("result", answer)

    # -- registration -----------------------------------------------------

    server.register(Tool(
        name="sdk_signature",
        description=(
            "What a function takes, returns and is for, read from the Luau "
            "itself. Guessing a signature cost four failed round trips in one "
            "day, and one of them took a whole module down with an error that "
            "named nothing."
        ),
        input_schema={
            "type": "object",
            "required": ["name"],
            "properties": {
                "name": {"type": "string",
                         "description": "e.g. Threat.build, or just build"},
            },
        },
        handler=sdk_signature,
    ))

    server.register(Tool(
        name="sdk_search",
        description=(
            "Find something by describing the job rather than naming the "
            "function: 'how do I make a trigger volume', 'something that chases'."
        ),
        input_schema={
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 40},
            },
        },
        handler=sdk_search,
    ))

    server.register(Tool(
        name="reuse_search",
        description=(
            "Does this already exist? Searches all four shelves at once -- the "
            "Forge engine, the roblox/lib library, every game's source, and the "
            "kits, which are whole finished games. Ask with a sentence, not a "
            "filename: 'hold a weapon in the hand', 'daily login reward'. Call "
            "this BEFORE writing any system. `sdk_search` reads library "
            "signatures only and cannot see games or kits."
        ),
        input_schema={
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {"type": "string",
                          "description": "what you are about to build, as a sentence"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 40},
            },
        },
        handler=reuse_search,
    ))

    server.register(Tool(
        name="sdk_source",
        description=(
            "The actual code of a module or function, to read and to copy. When "
            "a library function does not fit, taking it and changing it is the "
            "intended move -- not asking for another option."
        ),
        input_schema={
            "type": "object",
            "required": ["name"],
            "properties": {
                "name": {"type": "string"},
                "lines": {"type": "integer", "minimum": 5, "maximum": 400},
            },
        },
        handler=sdk_source,
    ))

    server.register(Tool(
        name="sdk_surface",
        description="Every module in the SDK and what is in it. The map.",
        input_schema={"type": "object", "properties": {}},
        handler=sdk_surface,
    ))

    server.register(Tool(
        name="sdk_skeleton",
        description=(
            "A whole game as readable starting code -- obby, tycoon, survival, "
            "tower defense. Not a generator: source you open and rewrite. Call "
            "with no name to list them."
        ),
        input_schema={
            "type": "object",
            "properties": {"name": {"type": "string"}},
        },
        handler=sdk_skeleton,
    ))

    server.register(Tool(
        name="code_write",
        description=(
            "Write a script into the open place. Compiles it first, so a syntax "
            "error comes back with a line number instead of becoming a module "
            "that fails at require time saying nothing. Pass `file` to also save "
            "it into the repository so it survives a rebuild."
        ),
        input_schema={
            "type": "object",
            "required": ["path", "source"],
            "properties": {
                "path": {"type": "string",
                         "description": "e.g. ReplicatedStorage.Gameplay.Sanity"},
                "source": {"type": "string"},
                "kind": {"type": "string", "enum": ["module", "server", "client"]},
                "file": {"type": "string",
                          "description": "optional repo path to save the same source to"},
                "overwrite": {
                    "type": "boolean",
                    "description": "required when replacing an existing repository file",
                },
            },
        },
        handler=code_write,
    ))

    server.register(Tool(
        name="code_reload",
        description=(
            "Reload a module without restarting Studio. Roblox caches require "
            "per instance forever, so this destroys and recreates the module to "
            "give it a new identity -- and then requires it, so a load error "
            "arrives now with a line number. Anything already holding the old "
            "table keeps it."
        ),
        input_schema={
            "type": "object",
            "required": ["path"],
            "properties": {
                "path": {"type": "string"},
                "source": {"type": "string",
                           "description": "optional new source, written before reloading"},
            },
        },
        handler=code_reload,
    ))

    server.register(Tool(
        name="code_read",
        description="The source of a script in the place.",
        input_schema={
            "type": "object",
            "required": ["path"],
            "properties": {"path": {"type": "string"}},
        },
        handler=code_read,
    ))

    server.register(Tool(
        name="code_list",
        description="Every script under a path in the place, with sizes.",
        input_schema={
            "type": "object",
            "properties": {"path": {"type": "string"}},
        },
        handler=code_list,
    ))

    server.register(Tool(
        name="code_at_start",
        description=(
            "Install code that runs when the game starts and is saved with the "
            "place. The difference from `run` is lifetime: a run's connections "
            "die with the session, this comes up with every Play Solo."
        ),
        input_schema={
            "type": "object",
            "required": ["source"],
            "properties": {
                "source": {"type": "string"},
                "name": {"type": "string"},
                "client": {"type": "boolean",
                           "description": "run on the client instead of the server"},
            },
        },
        handler=code_at_start,
    ))

    server.register(Tool(
        name="run",
        description=(
            "Run Luau in the open place, in edit or in a running session. The "
            "escape hatch: anything the library does not cover, write it here. "
            "Errors come back with a line number."
        ),
        input_schema={
            "type": "object",
            "required": ["source"],
            "properties": {
                "source": {"type": "string"},
                "context": {"type": "string", "enum": ["any", "edit", "server", "running"]},
                "name": {"type": "string", "description": "chunk name, shown in errors"},
                "timeout": {"type": "number", "minimum": 1, "maximum": 300},
            },
        },
        handler=run_luau,
    ))

    server.register(Tool(
        name="compile",
        description="Does this Luau parse? Checks without spending a run.",
        input_schema={
            "type": "object",
            "required": ["source"],
            "properties": {"source": {"type": "string"}},
        },
        handler=code_compile,
    ))

    server.register(Tool(
        name="test_run",
        description=(
            "Run assertions inside the engine. Your source is given a "
            "`check(name, condition, detail)` function; everything it reports "
            "comes back as one result. The suite outside can check Python -- "
            "this is the only way to assert something about the DataModel where "
            "the assertion and the fact are in the same process."
        ),
        input_schema={
            "type": "object",
            "required": ["source"],
            "properties": {
                "source": {"type": "string"},
                "timeout": {"type": "number", "minimum": 1, "maximum": 300},
            },
        },
        handler=test_run,
    ))

    server.register(Tool(
        name="dm_inspect",
        description=(
            "Everything about one instance in one call: properties, attributes, "
            "tags, children, counts. Optionally its source."
        ),
        input_schema={
            "type": "object",
            "required": ["path"],
            "properties": {
                "path": {"type": "string"},
                "source": {"type": "boolean"},
            },
        },
        handler=dm_inspect,
    ))

    server.register(Tool(
        name="logs",
        description="The print and warn output of the running game.",
        input_schema={
            "type": "object",
            "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 400}},
        },
        handler=logs_tail,
    ))

    server.register(Tool(
        name="watch",
        description=(
            "Record what an attribute does while you are not looking. A poll "
            "asks what it is now; a watch catches the value that flickered."
        ),
        input_schema={
            "type": "object",
            "required": ["path", "attribute"],
            "properties": {
                "path": {"type": "string"},
                "attribute": {"type": "string"},
                "action": {"type": "string", "enum": ["start", "read", "stop"]},
            },
        },
        handler=watch_attribute,
    ))

    server.register(Tool(
        name="place",
        description=(
            "Put something where you want it: move to a point or by an offset, "
            "rotate, scale, align against a face of something else, snap to a "
            "grid, or settle onto whatever is underneath. Every action reads "
            "back where it ended up and what it now overlaps -- a move you "
            "cannot verify is a move you have to screenshot."
        ),
        input_schema={
            "type": "object",
            "required": ["path"],
            "properties": {
                "path": {"type": "string"},
                "action": {"type": "string",
                           "enum": ["bounds", "move", "orient", "align", "snap", "settle"]},
                "to": {"description": "move: [x,y,z]. align: the path to align against"},
                "by": {"type": "array", "items": {"type": "number"},
                       "minItems": 3, "maxItems": 3},
                "rotate": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "scale": {"type": "number", "exclusiveMinimum": 0},
                "face": {"type": "string",
                         "enum": ["top", "bottom", "left", "right", "front", "back", "centre"]},
                "gap": {"type": "number"},
                "centred": {"type": "boolean"},
                "grid": {"type": "number", "exclusiveMinimum": 0},
                "axes": {"type": "string", "description": "which axes snap, e.g. xz"},
            },
        },
        handler=place_transform,
    ))

    server.register(Tool(
        name="place_query",
        description=(
            "Do two things intersect and by how much, or what is nearest to a "
            "point. The checks that make a placement verifiable."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "a": {"type": "string"},
                "b": {"type": "string"},
                "point": {"type": "array", "items": {"type": "number"},
                          "minItems": 3, "maxItems": 3},
                "within": {"type": "string"},
                "className": {"type": "string"},
            },
        },
        handler=place_query,
    ))

    return server
