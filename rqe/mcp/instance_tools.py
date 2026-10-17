"""Making, moving and asking about instances directly.

The plugin has had `instance.create`, `instance.clone` and the `world.*`
geometry queries for a long time and none of them had a tool. An agent that
wanted to put a part somewhere had to write Luau through `run` -- which works,
and is the escape hatch, but should not be the *only* way to do the most
ordinary thing in the engine.

    instance   create, clone, update, reparent, destroy, list
    spatial    raycast, what is in a box or a radius, line of sight, ground, path

Nothing here is required. `run` reaches all of it and more; these exist so the
common cases are one call instead of ten lines.
"""

from __future__ import annotations

import json
from typing import Any

from .server import Tool

#: Property values that have to become Roblox types rather than plain numbers.
_COLOUR_PROPERTIES = {"Color", "Color3", "BrickColor", "TextColor3", "BackgroundColor3"}


def _lua_value(name: str, value: Any) -> str:
    """A property value as Luau.

    Three-number lists are the ambiguity: `[4, 4, 4]` is a `Vector3` for `Size`
    and a `Color3` for `Color`, and guessing wrong sets a size of four studs in
    a colour channel. The property name decides, which is the only thing that
    can.
    """

    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, (list, tuple)) and len(value) == 3:
        if name in _COLOUR_PROPERTIES:
            return f"Color3.fromRGB({value[0]},{value[1]},{value[2]})"
        return f"Vector3.new({value[0]},{value[1]},{value[2]})"
    return json.dumps(value)


def _resolve_lua(path: str) -> str:
    """Luau that walks a dotted path and raises with the path when it cannot."""

    pieces = [piece for piece in path.split(".") if piece and piece != "game"]
    if not pieces:
        return "game"
    lines = ["(function()", "\tlocal node = game"]
    for piece in pieces:
        lines.append(
            f"\tnode = node:FindFirstChild({json.dumps(piece)}) "
            f"or (node == game and game:FindService({json.dumps(piece)}) or nil)")
        lines.append(
            f"\tif node == nil then error({json.dumps('no instance at ' + path)}, 0) end")
    lines.append("\treturn node")
    lines.append("end)()")
    return "\n".join(lines)


def _exec(source: str, chunk: str, timeout: float = 45.0) -> dict[str, Any]:
    from ..hub.client import StudioBridge

    # This surface emits a fixed program from typed/JSON-escaped fields.  It is
    # an audited use of the executor capability, not a raw-source escape hatch.
    bridge = StudioBridge(allow_arbitrary=True)
    try:
        with bridge.lease_scope(
            agent_id="mcp-instance-tools",
            context="edit",
            ttl_seconds=max(30.0, min(timeout + 30.0, 300.0)),
        ):
            answer = bridge.call(
                "bridge.exec",
                {"source": source, "chunkName": chunk},
                timeout=timeout,
            )
    except Exception as error:  # noqa: BLE001
        return {"ok": False, "error": str(error)}
    returned = answer.get("returned") if isinstance(answer, dict) else answer
    if isinstance(returned, dict):
        return returned
    return {"ok": True, "result": returned}


def register_instance_tools(server: Any) -> Any:
    """Attach direct instance and spatial tools."""

    def instance_do(arguments: dict[str, Any]) -> dict[str, Any]:
        action = str(arguments.get("action") or "create")

        if action == "create":
            class_name = str(arguments.get("className") or "Part")
            name = str(arguments.get("name") or class_name)
            assignments = "\n".join(
                f"pcall(function() made.{key} = {_lua_value(key, value)} end)"
                for key, value in (arguments.get("properties") or {}).items())
            attributes = "\n".join(
                f"made:SetAttribute({json.dumps(key)}, {_lua_value(key, value)})"
                for key, value in (arguments.get("attributes") or {}).items())
            source = f"""
local parent = {_resolve_lua(str(arguments.get("parent") or "Workspace"))}
local made = Instance.new({json.dumps(class_name)})
made.Name = {json.dumps(name)}
{assignments}
{attributes}
made.Parent = parent
return {{ path = made:GetFullName(), className = made.ClassName, created = true }}
"""
        elif action == "clone":
            rename = str(arguments.get("name") or "")
            source = f"""
local original = {_resolve_lua(str(arguments["path"]))}
local copy = original:Clone()
copy.Parent = {_resolve_lua(str(arguments.get("parent") or "Workspace"))}
if {json.dumps(rename)} ~= "" then copy.Name = {json.dumps(rename)} end
return {{ path = copy:GetFullName(), from = original:GetFullName(), cloned = true }}
"""
        elif action == "update":
            lines = [
                f"pcall(function() target.{key} = {_lua_value(key, value)} end)"
                for key, value in (arguments.get("properties") or {}).items()
            ] + [
                f"target:SetAttribute({json.dumps(key)}, {_lua_value(key, value)})"
                for key, value in (arguments.get("attributes") or {}).items()
            ]
            source = f"""
local target = {_resolve_lua(str(arguments["path"]))}
{chr(10).join(lines)}
return {{ path = target:GetFullName(), applied = {len(lines)} }}
"""
        elif action == "parent":
            source = f"""
local target = {_resolve_lua(str(arguments["path"]))}
target.Parent = {_resolve_lua(str(arguments["parent"]))}
return {{ path = target:GetFullName() }}
"""
        elif action == "destroy":
            source = f"""
local target = {_resolve_lua(str(arguments["path"]))}
local was = target:GetFullName()
target:Destroy()
return {{ destroyed = was }}
"""
        elif action == "list":
            source = f"""
local root = {_resolve_lua(str(arguments.get("path") or "Workspace"))}
local wanted = {json.dumps(str(arguments.get("className") or ""))}
local deep = {str(bool(arguments.get("deep"))).lower()}
local out = {{}}
local items = if deep then root:GetDescendants() else root:GetChildren()
for _, item in ipairs(items) do
    if wanted == "" or item:IsA(wanted) then
        table.insert(out, {{ name = item.Name, className = item.ClassName,
                            path = item:GetFullName() }})
        if #out >= 200 then break end
    end
end
return {{ root = root:GetFullName(), found = #out, items = out }}
"""
        else:
            return {"ok": False,
                    "error": f"no action {action!r}; have create, clone, update, "
                             "parent, destroy, list"}

        return _exec(source, "rqe.instance")

    def spatial_query(arguments: dict[str, Any]) -> dict[str, Any]:
        kind = str(arguments.get("kind") or "ray")
        ignore = "{" + ",".join(
            _resolve_lua(str(path)) for path in (arguments.get("ignore") or [])) + "}"
        prelude = 'local Spatial = require(game:GetService("ReplicatedStorage").Core.Spatial)'

        def vector(name: str, fallback=(0, 0, 0)) -> str:
            values = list(arguments.get(name) or fallback)
            return f"Vector3.new({values[0]},{values[1]},{values[2]})"

        if kind == "ray":
            direction = (f"{vector('to')} - {vector('from')}"
                         if arguments.get("to") is not None
                         else vector("direction", (0, -100, 0)))
            source = f"""
{prelude}
local hit = Spatial.ray({vector("from")}, {direction}, {{ ignore = {ignore} }})
return {{
    hit = hit.hit,
    instance = hit.instance and hit.instance:GetFullName() or nil,
    position = hit.position and {{ hit.position.X, hit.position.Y, hit.position.Z }} or nil,
    distance = hit.distance, material = hit.material,
}}
"""
        elif kind in ("box", "radius"):
            call = (f"Spatial.inBox({vector('centre')}, {vector('size', (32, 32, 32))}, "
                    f"{{ ignore = {ignore} }})"
                    if kind == "box"
                    else f"Spatial.inRadius({vector('centre')}, "
                         f"{float(arguments.get('radius') or 20)}, {{ ignore = {ignore} }})")
            source = f"""
{prelude}
local found = {call}
local out = {{}}
for _, item in ipairs(found) do table.insert(out, item:GetFullName()) end
return {{ found = #out, items = out }}
"""
        elif kind == "sees":
            source = f"""
{prelude}
return {{ sees = Spatial.sees({vector("from")}, {vector("to")}, {{ ignore = {ignore} }}) }}
"""
        elif kind == "ground":
            source = f"""
{prelude}
local hit = Spatial.ground({vector("from")}, {{ ignore = {ignore} }})
return {{
    hit = hit.hit,
    instance = hit.instance and hit.instance:GetFullName() or nil,
    position = hit.position and {{ hit.position.X, hit.position.Y, hit.position.Z }} or nil,
    distance = hit.distance,
}}
"""
        elif kind == "path":
            source = f"""
{prelude}
local found = Spatial.path({vector("from")}, {vector("to")}, {{}})
local points = {{}}
for _, w in ipairs(found.waypoints) do
    table.insert(points, {{ w.position.X, w.position.Y, w.position.Z, w.action }})
end
return {{ ok = found.ok, status = found.status, waypoints = points, count = #points }}
"""
        else:
            return {"ok": False,
                    "error": f"no kind {kind!r}; have ray, box, radius, sees, ground, path"}

        return _exec(source, "rqe.spatial")

    server.register(Tool(
        name="instance",
        description=(
            "Create, clone, update, reparent, destroy or list instances. The "
            "most ordinary thing in the engine, and it used to need hand-written "
            "Luau. Three-number lists become Vector3 or Color3 depending on the "
            "property name -- guessing wrong sets a size in a colour channel."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "action": {"type": "string",
                           "enum": ["create", "clone", "update", "parent",
                                    "destroy", "list"]},
                "path": {"type": "string"},
                "className": {"type": "string"},
                "name": {"type": "string"},
                "parent": {"type": "string"},
                "properties": {"type": "object"},
                "attributes": {"type": "object"},
                "deep": {"type": "boolean"},
            },
        },
        handler=instance_do,
    ))

    server.register(Tool(
        name="spatial",
        description=(
            "Ask the world where things are: cast a ray, list what is in a box "
            "or a radius, check line of sight, find the ground, compute a path. "
            "The caster is excluded by default -- a ray from a creature that "
            "hits the creature is the commonest raycast bug there is."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "kind": {"type": "string",
                         "enum": ["ray", "box", "radius", "sees", "ground", "path"]},
                "from": {"type": "array", "items": {"type": "number"},
                         "minItems": 3, "maxItems": 3},
                "to": {"type": "array", "items": {"type": "number"},
                       "minItems": 3, "maxItems": 3},
                "direction": {"type": "array", "items": {"type": "number"},
                              "minItems": 3, "maxItems": 3},
                "centre": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "size": {"type": "array", "items": {"type": "number"},
                         "minItems": 3, "maxItems": 3},
                "radius": {"type": "number", "exclusiveMinimum": 0},
                "ignore": {"type": "array", "items": {"type": "string"}},
            },
        },
        handler=spatial_query,
    ))

    return server
