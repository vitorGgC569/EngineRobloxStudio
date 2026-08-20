"""Movement and interface, authored directly.

Two gaps closed here, both the same shape: a capability existed in the SDK and
the only way to reach it was to write Luau.

    pursuit_*   a creature that follows, avoids, or walks a beat
    ui_compose  a screen described as data, with live attribute bindings

`pursuit_*` overlaps `gameplay_install`'s `chase`/`flee`/`patrol` effects on
purpose. The rule is how a behaviour ships -- it is saved with the place and
comes up with the session. These tools are how it gets tried: start a chase, look
at it, change the speed, look again. Making somebody author a rule to answer "is
20 studs/s too fast" would be a worse tool.
"""

from __future__ import annotations

import json
from typing import Any

from .server import Tool
from .staging_tools import _PRELUDE, _exec


def _num(arguments: dict[str, Any], key: str, default: float) -> float:
    """A numeric argument, where zero means zero.

    `float(arguments.get("upper") or 90)` reads naturally and is wrong: zero is
    falsy in Python, so a caller asking for `upper: 0` -- a door that closes
    flush -- silently got 90 degrees. Lua would have done the right thing here,
    which is exactly why the bug survived reading.

    Measured: `interact_attach` with `upper: 0` reported `upper: 90`.
    """

    value = arguments.get(key)
    if value is None:
        return float(default)
    return float(value)


def _int(arguments: dict[str, Any], key: str, default: int) -> int:
    """The same, for counts and seeds. Seed 0 is a seed."""

    value = arguments.get(key)
    if value is None:
        return int(default)
    return int(value)


def register_authoring_tools(server: Any) -> Any:
    """Attach the pursuit and screen-composition tools."""

    def pursuit_start(arguments: dict[str, Any]) -> dict[str, Any]:
        who = json.dumps(str(arguments["who"]))
        mode = str(arguments.get("mode") or "chase")
        if mode not in ("chase", "flee", "patrol"):
            return {"ok": False, "error": "mode must be chase, flee or patrol"}
        speed = _num(arguments, "speed", 16)
        safe = _num(arguments, "safe", 60)
        reach = _num(arguments, "reach", 4)
        points = arguments.get("points") or []
        if mode == "patrol" and len(points) < 2:
            return {"ok": False,
                    "error": "patrol needs at least two points to walk between"}
        lua_points = "{" + ",".join(
            f"Vector3.new({p[0]},{p[1]},{p[2]})" for p in points) + "}"

        # A creature that pathfinds and slides is the exact defect Motion was
        # built to fix, and nothing forced the two tools to be used together.
        # So movement animates by default: a caller has to ask for the broken
        # version rather than fall into it.
        gait = str(arguments.get("gait") or "walk")
        animate = gait != "none"

        return _exec(server, _PRELUDE + f"""
local GameKit = require(game:GetService("ReplicatedStorage"):WaitForChild("GameKit"))
local Pursuit = GameKit.Pursuit
local wanted = {who}
local started, refused = 0, {{}}
for _, item in ipairs(workspace:GetDescendants()) do
    if item:IsA("Model") and item.Name == wanted then
        local pursuer, why = Pursuit.start(item, {{
            mode = "{mode}", speed = {speed}, safe = {safe}, reach = {reach},
            points = {lua_points},
        }}, function()
            local pivot = item:GetPivot().Position
            return Pursuit.nearestPlayer(pivot)
        end)
        if pursuer ~= nil then
            started += 1
            if {str(animate).lower()} then
                -- Failure to animate must not stop the creature moving; a
                -- single-part model cannot be animated and can still walk.
                local performer, gaitWhy = GameKit.Motion.play(item, {{
                    gait = "{gait}", rate = 1.6,
                }})
                if performer == nil then table.insert(refused, gaitWhy) end
            end
        else
            table.insert(refused, why)
        end
    end
end
if started == 0 and #refused == 0 then
    error("no Model named " .. wanted .. " in the workspace", 0)
end
return {{
    started = started, refused = refused,
    gait = {"nil" if not animate else '"' + gait + '"'},
    report = Pursuit.report(),
}}
""")

    def pursuit_stop(arguments: dict[str, Any]) -> dict[str, Any]:
        who = arguments.get("who")
        if not who:
            return _exec(server, _PRELUDE + """
local GameKit = require(game:GetService("ReplicatedStorage"):WaitForChild("GameKit"))
GameKit.Pursuit.stopAll()
GameKit.Motion.stopAll()
return { stopped = "all", report = GameKit.Pursuit.report() }
""")
        return _exec(server, _PRELUDE + f"""
local GameKit = require(game:GetService("ReplicatedStorage"):WaitForChild("GameKit"))
local stopped = 0
for _, item in ipairs(workspace:GetDescendants()) do
    if item:IsA("Model") and item.Name == {json.dumps(str(who))} then
        GameKit.Pursuit.stop(item)
        GameKit.Motion.stop(item)
        stopped += 1
    end
end
return {{ stopped = stopped, report = GameKit.Pursuit.report() }}
""")

    def pursuit_report(_arguments: dict[str, Any]) -> dict[str, Any]:
        return _exec(server, _PRELUDE + """
local Pursuit = require(game:GetService("ReplicatedStorage"):WaitForChild("GameKit")).Pursuit
return Pursuit.report()
""")

    def ui_compose(arguments: dict[str, Any]) -> dict[str, Any]:
        from .gameplay_tools import _lua

        spec = dict(arguments.get("screen") or {})
        if not spec.get("name"):
            return {"ok": False, "error": "screen needs a name"}
        if not spec.get("children") and arguments.get("force") is not True:
            return {
                "ok": False,
                "error": "screen has no children, so it would open blank",
                "note": "advice: pass force:true to build it anyway",
            }

        check_only = bool(arguments.get("checkOnly"))
        verb = "validate" if check_only else "build"
        return _exec(server, _PRELUDE + f"""
local spec = {_lua(spec)}
local problems = WorldKit.Compose.validate(spec)
if #problems > 0 then
    return {{ ok = false, problems = problems }}
end
if "{verb}" == "validate" then
    return {{ ok = true, validated = true, name = spec.name }}
end
local host = game:GetService("StarterGui")
local existing = host:FindFirstChild(spec.name)
if existing ~= nil then existing:Destroy() end
local screen, audit = WorldKit.Compose.build(host, tokens, spec, nil)
if screen == nil then
    return {{ ok = false, problems = audit }}
end
return {{
    ok = true, name = screen.Name, enabled = screen.Enabled,
    path = screen:GetFullName(),
    descendants = #screen:GetDescendants(),
    audit = audit,
}}
""")

    server.register(Tool(
        name="pursuit_start",
        description=(
            "Make every Model with this name chase the nearest player, flee it, "
            "or walk a patrol -- with real pathfinding round geometry, and "
            "animated while it moves. Works on models without a Humanoid, which "
            "is what most stylised creatures are."
        ),
        input_schema={
            "type": "object",
            "required": ["who"],
            "properties": {
                "who": {"type": "string", "description": "Model name to move"},
                "mode": {"type": "string", "enum": ["chase", "flee", "patrol"]},
                "speed": {"type": "number", "exclusiveMinimum": 0},
                "safe": {"type": "number",
                         "description": "flee: how far away is far enough"},
                "reach": {"type": "number",
                          "description": "how close counts as arrived"},
                "gait": {
                    "type": "string",
                    "enum": ["walk", "menace", "stagger", "hover", "idle", "none"],
                    "description": "animation to play while moving; defaults to walk. "
                                   "`none` leaves the creature sliding, which is "
                                   "almost never what you want",
                },
                "points": {
                    "type": "array",
                    "description": "patrol: the loop to walk",
                    "items": {"type": "array", "items": {"type": "number"},
                              "minItems": 3, "maxItems": 3},
                },
            },
        },
        handler=pursuit_start,
    ))

    server.register(Tool(
        name="pursuit_stop",
        description="Stop one named Model moving, or every pursuer when given no name.",
        input_schema={
            "type": "object",
            "properties": {"who": {"type": "string"}},
        },
        handler=pursuit_stop,
    ))

    server.register(Tool(
        name="pursuit_report",
        description=(
            "What is moving and in what state: chase, flee, patrol, idle, safe, "
            "or unreachable. `unreachable` means pathfinding failed repeatedly "
            "-- usually a creature walled in, which looks identical to a bug."
        ),
        input_schema={"type": "object", "properties": {}},
        handler=pursuit_report,
    ))

    server.register(Tool(
        name="ui_compose",
        description=(
            "Author a screen from a description instead of picking a template: "
            "panels, text, meters, buttons, chips, bound live to attributes. "
            "Every panel gets a layout, so children cannot pile at the origin, "
            "and the result is run through the same audit the emit gate uses. "
            "Set checkOnly to validate without building."
        ),
        input_schema={
            "type": "object",
            "required": ["screen"],
            "properties": {
                "checkOnly": {"type": "boolean"},
                "force": {"type": "boolean",
                          "description": "build despite validation advice"},
                "screen": {
                    "type": "object",
                    "required": ["name", "children"],
                    "properties": {
                        "name": {"type": "string"},
                        "anchor": {
                            "type": "string",
                            "enum": ["topLeft", "topRight", "bottomLeft",
                                     "bottomRight", "top", "bottom", "centre"],
                        },
                        "enabled": {"type": "boolean"},
                        "children": {
                            "type": "array",
                            "items": {"$ref": "#/$defs/element"},
                        },
                    },
                },
            },
            "$defs": {
                "element": {
                    "type": "object",
                    "required": ["kind"],
                    "properties": {
                        "kind": {
                            "type": "string",
                            "enum": ["panel", "stack", "text", "value", "meter",
                                     "button", "chip", "icon", "spacer",
                                     "shelf", "scroller"],
                        },
                        "body": {"type": "string"},
                        "step": {"type": "string",
                                 "description": "type scale: title, body, caption"},
                        "caption": {"type": "string"},
                        "icon": {"type": "string"},
                        "bind": {
                            "type": "object",
                            "required": ["attribute"],
                            "properties": {
                                "attribute": {"type": "string"},
                                "on": {"type": "string",
                                       "description": "player, workspace, or a path"},
                                "max": {"type": "number"},
                                "format": {"type": "string",
                                           "description": "e.g. 'Sanity: %d%%'"},
                            },
                        },
                        "options": {"type": "object"},
                        "children": {"type": "array",
                                     "items": {"$ref": "#/$defs/element"}},
                    },
                },
            },
        },
        handler=ui_compose,
    ))

    return server
