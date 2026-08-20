"""Camera, VFX, guidance, planting and setpieces -- the staging half.

These capabilities were written, tested and shipped inside the place, and not
one of them had a tool. Twenty-five functions across seven WorldKit modules,
reachable only by writing Luau through `bridge.exec`. That is the difference
between "the SDK can do it" and "an agent can ask for it", and the second is
the point of this surface.

Camera matters most and was missing entirely. Framing is half the language of
a scene -- a horror lane read from eye level and from above are different
games -- and the only way to change it was to compose CFrames by hand.

**Every tool here acts on the open place immediately.** Unlike `scene_*`, which
produce plans to be applied later, staging is the part you judge by looking:
you set a mood, you frame it, you capture, you adjust. Interposing a plan
between the intent and the picture would make that loop slower for no gain.

**Nothing here invents a colour or a number.** Every call takes token roles and
named profiles, so a highlight in a farm and a highlight in an abbey are the
same call with different palettes underneath -- and a caller cannot quietly
start a second design system.
"""

from __future__ import annotations

import json
from typing import Any

from .server import Tool


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


def _exec(server: Any, source: str, timeout: float = 60.0) -> dict[str, Any]:
    """Run Luau in the open place and hand back what it returned.

    Staging needs a live DataModel: there is no meaningful way to "plan" a
    camera. The bridge refuses this outside edit context, and that refusal is
    surfaced rather than swallowed -- a caller that thinks it framed a shot and
    did not would keep capturing the old one.
    """

    from ..hub.client import StudioBridge

    bridge = StudioBridge()
    bridge.pin_to_any()
    try:
        result = bridge.call("bridge.exec", {"source": source}, timeout=timeout)
    except Exception as error:
        return {
            "ok": False,
            "error": str(error),
            "remedy": (
                "staging acts on the open place and needs edit context; stop "
                "Play Solo, or use client_camera_* for a running session"
            ),
        }
    returned = result.get("returned") if isinstance(result, dict) else result
    return {"ok": True, "result": returned}


_PRELUDE = """
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldKit = require(ReplicatedStorage:WaitForChild("WorldKit"))
local tokens = WorldKit.Tokens.define(require(ReplicatedStorage.Shared.TokenData))
local function resolve(path)
    local node = game
    for piece in string.gmatch(path, "[^%.]+") do
        if piece ~= "game" then
            node = node:FindFirstChild(piece)
            if node == nil then
                error("no instance at " .. path, 0)
            end
        end
    end
    return node
end
--- Palette themes are named tables, not something derivable from the token set.
--- The first version guessed `Palette.theme(tokens)`, which does not exist, and
--- every caller got `attempt to index nil with 'metalDark'` from three frames
--- deep inside Palette -- an error that names neither the tool nor the mistake.
local function theme(named)
    local found = WorldKit.Palette[named]
    if found == nil or type(found) ~= "table" or found.swatches == nil then
        local names = {}
        for key, value in pairs(WorldKit.Palette) do
            if type(value) == "table" and value.swatches ~= nil then
                table.insert(names, key)
            end
        end
        table.sort(names)
        error(("no palette theme %q; have %s"):format(
            tostring(named), table.concat(names, ", ")), 0)
    end
    return found
end
"""


def register_staging_tools(server: Any) -> Any:
    """Attach camera, VFX, guidance, planting and setpiece tools."""

    def camera_frame(arguments: dict[str, Any]) -> dict[str, Any]:
        profile = json.dumps(str(arguments.get("profile") or "hero"))
        target = json.dumps(str(arguments["target"]))
        return _exec(server, _PRELUDE + f"""
local subject = resolve({target})
local framing = WorldKit.Camera.frame(tokens, {profile}, subject, {{}})
WorldKit.Camera.apply(workspace.CurrentCamera, framing)
return {{ profile = {profile}, subject = subject:GetFullName() }}
""")

    def camera_sweep(arguments: dict[str, Any]) -> dict[str, Any]:
        target = json.dumps(str(arguments["target"]))
        return _exec(server, _PRELUDE + f"""
local subject = resolve({target})
local sweep = WorldKit.Camera.sweep(tokens, subject, {{}})
local names = {{}}
for name in pairs(sweep) do table.insert(names, name) end
table.sort(names)
return {{ viewpoints = names }}
""")

    def vfx_apply(arguments: dict[str, Any]) -> dict[str, Any]:
        target = json.dumps(str(arguments["target"]))
        style = str(arguments.get("style") or "burst")
        role_from = json.dumps(str(arguments.get("fromRole") or "accentGold"))
        role_to = json.dumps(str(arguments.get("toRole") or "accentDanger"))
        amount = _int(arguments, "amount", 16)

        if style == "highlight":
            body = f"""
local target = resolve({target})
WorldKit.Vfx.highlight(tokens, target, {role_from}, {role_to}, {{}})
return {{ style = "highlight", target = target:GetFullName() }}
"""
        elif style == "light":
            body = f"""
local host = resolve({target})
WorldKit.Vfx.light(tokens, host, {role_from}, {{}})
return {{ style = "light", target = host:GetFullName() }}
"""
        elif style == "trail":
            body = f"""
local host = resolve({target})
WorldKit.Vfx.trail(tokens, host, {role_from}, {role_to}, {{}})
return {{ style = "trail", target = host:GetFullName() }}
"""
        else:
            body = f"""
local host = resolve({target})
WorldKit.Vfx.burst(tokens, host, {{
    fromRole = {role_from}, toRole = {role_to},
    rate = 0, lifetime = NumberRange.new(0.3, 0.9),
    speed = NumberRange.new(6, 14), size = 1.2,
}}, {amount})
return {{ style = "burst", target = host:GetFullName(), amount = {amount} }}
"""
        return _exec(server, _PRELUDE + body)

    def guidance_focus(arguments: dict[str, Any]) -> dict[str, Any]:
        target = json.dumps(str(arguments["target"]))
        label = json.dumps(str(arguments.get("label") or "here"))
        identifier = json.dumps(str(arguments.get("id") or "guidance"))
        return _exec(server, _PRELUDE + f"""
local target = resolve({target})
local handle = WorldKit.Guidance.focus(tokens, target, {{
    id = {identifier}, label = {label},
}})
return {{ focused = target:GetFullName(), id = {identifier} }}
""")

    def guidance_clear(arguments: dict[str, Any]) -> dict[str, Any]:
        target = json.dumps(str(arguments["target"]))
        return _exec(server, _PRELUDE + f"""
local target = resolve({target})
return {{ cleared = WorldKit.Guidance.clear(target) }}
""")

    def nature_scatter(arguments: dict[str, Any]) -> dict[str, Any]:
        centre = list(arguments.get("centre") or [0, 0, 0])
        # A footprint, not a radius. The module takes a Vector2 extent, and
        # planting rectangles is what maps need: a strip beside a road, the
        # ground between two plots.
        size = list(arguments.get("size") or [120, 120])
        count = _int(arguments, "count", 40)
        ratio = _num(arguments, "treeRatio", 0.7)
        seed = _int(arguments, "seed", 1)
        spacing = _num(arguments, "minSpacing", 12)
        parent = json.dumps(str(arguments.get("parent") or "Workspace"))
        theme_name = json.dumps(str(arguments.get("theme") or "BrickFarm"))

        # Exclusions are the difference between a forest and a forest growing
        # through the roads. Without them a caller has to plant, look, and
        # delete by hand.
        keep_clear = "{" + ",".join(
            "{centre=Vector3.new(%s,%s,%s),size=Vector2.new(%s,%s)}" % (
                zone["centre"][0], zone["centre"][1], zone["centre"][2],
                zone["size"][0], zone["size"][1])
            for zone in (arguments.get("keepClear") or [])) + "}"

        return _exec(server, _PRELUDE + f"""
local parent = resolve({parent})
local model = WorldKit.Nature.scatter(parent, theme({theme_name}), {{
    centre = Vector3.new({centre[0]}, {centre[1]}, {centre[2]}),
    size = Vector2.new({size[0]}, {size[1]}),
    count = {count}, seed = {seed}, minSpacing = {spacing},
    exclusions = {keep_clear},
}}, {ratio})
return {{ planted = #model:GetChildren(), at = model:GetFullName() }}
""", timeout=120.0)

    def setpiece_build(arguments: dict[str, Any]) -> dict[str, Any]:
        kind = str(arguments.get("kind") or "ruinedSanctuary")
        centre = list(arguments.get("centre") or [0, 0, 0])
        parent = json.dumps(str(arguments.get("parent") or "Workspace"))
        return _exec(server, _PRELUDE + f"""
local parent = resolve({parent})
local builder = WorldKit.Setpiece["{kind}"]
if builder == nil then
    local names = {{}}
    for name in pairs(WorldKit.Setpiece) do table.insert(names, name) end
    table.sort(names)
    error("no setpiece named {kind}; have " .. table.concat(names, ", "), 0)
end
local built = builder(parent, tokens, {{
    centre = Vector3.new({centre[0]}, {centre[1]}, {centre[2]}),
}})
return {{ kind = "{kind}", built = typeof(built) }}
""", timeout=120.0)

    def conveyor_build(arguments: dict[str, Any]) -> dict[str, Any]:
        name = json.dumps(str(arguments.get("name") or "Belt"))
        origin = list(arguments.get("origin") or [0, 0, 0])
        direction = list(arguments.get("direction") or [0, 0, 1])
        length = _num(arguments, "length", 40)
        width = _num(arguments, "width", 6)
        speed = _num(arguments, "speed", 8)
        parent = json.dumps(str(arguments.get("parent") or "Workspace"))
        theme_name = json.dumps(str(arguments.get("theme") or "BrickFarm"))
        return _exec(server, _PRELUDE + f"""
local parent = resolve({parent})
local belt = WorldKit.Conveyor.build(parent, {name}, {{
    origin = Vector3.new({origin[0]}, {origin[1]}, {origin[2]}),
    direction = Vector3.new({direction[0]}, {direction[1]}, {direction[2]}).Unit,
    length = {length}, width = {width}, speed = {speed},
    theme = theme({theme_name}),
}})
return {{ built = {name}, length = {length}, speed = {speed} }}
""", timeout=90.0)

    def fab_aperture(arguments: dict[str, Any]) -> dict[str, Any]:
        wall = json.dumps(str(arguments["wall"]))
        openings = arguments.get("openings") or []
        if not openings:
            return {"ok": False,
                    "error": "an aperture with no openings is just a wall"}
        lua = "{" + ",".join(
            "{offset=Vector2.new(%s,%s),size=Vector2.new(%s,%s)}" % (
                o["offset"][0], o["offset"][1], o["size"][0], o["size"][1])
            for o in openings) + "}"
        return _exec(server, _PRELUDE + f"""
local wall = resolve({wall})
if not wall:IsA("BasePart") then
    error("aperture needs a BasePart, got a " .. wall.ClassName, 0)
end
local cut, receipt = WorldKit.Fab.aperture(wall, {lua}, {{}})
return {{
    cut = cut ~= nil,
    path = cut ~= nil and cut:GetFullName() or nil,
    receipt = receipt,
}}
""", timeout=120.0)

    def fab_budget(_arguments: dict[str, Any]) -> dict[str, Any]:
        return _exec(server, _PRELUDE + """
return {
    capabilities = WorldKit.Fab.capabilities(),
    budget = WorldKit.Fab.budget(),
    vfx = WorldKit.Vfx.budget(),
}
""")

    def audio_events(_arguments: dict[str, Any]) -> dict[str, Any]:
        return _exec(server, _PRELUDE + """
local bank = WorldKit.Audio.define()
return {
    events = WorldKit.Audio.events(),
    problems = WorldKit.Audio.problems(),
    defined = bank ~= nil,
}
""")

    def audio_play(arguments: dict[str, Any]) -> dict[str, Any]:
        event = json.dumps(str(arguments["event"]))
        volume = _num(arguments, "volume", 1.0)
        where = arguments.get("at")
        if where:
            at = json.dumps(str(where))
            body = f"""
local sound = WorldKit.Audio.playAt({event}, resolve({at}), {{ volume = {volume} }})
return {{ played = sound ~= nil, event = {event}, at = {at} }}
"""
        else:
            body = f"""
local sound = WorldKit.Audio.play({event}, {{ volume = {volume} }})
return {{ played = sound ~= nil, event = {event} }}
"""
        return _exec(server, _PRELUDE + f"""
WorldKit.Audio.define()
-- `Audio.play` raises on an unknown event rather than going quiet, and that is
-- the right behaviour -- but the name it wants is worth reporting up front,
-- because a cue named `denial` when the bank says `denied` once took a whole
-- world script down.
local known = false
for _, name in ipairs(WorldKit.Audio.events()) do
    if name == {event} then known = true end
end
if not known then
    error("no audio event named " .. {event} .. "; have " ..
        table.concat(WorldKit.Audio.events(), ", "), 0)
end
{body}
""")

    def staging_catalogue(_arguments: dict[str, Any]) -> dict[str, Any]:
        return _exec(server, _PRELUDE + """
local function names(module)
    local out = {}
    for name, value in pairs(module) do
        if type(value) == "function" and string.sub(name, 1, 1) ~= "_" then
            table.insert(out, name)
        end
    end
    table.sort(out)
    return out
end
return {
    camera = names(WorldKit.Camera),
    vfx = names(WorldKit.Vfx),
    guidance = names(WorldKit.Guidance),
    nature = names(WorldKit.Nature),
    setpiece = names(WorldKit.Setpiece),
    conveyor = names(WorldKit.Conveyor),
    fab = names(WorldKit.Fab),
}
""")

    server.register(Tool(
        name="conveyor_build",
        description=(
            "A working belt that carries what lands on it -- geometry and "
            "motion together, not a decorated part."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "origin": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "direction": {"type": "array", "items": {"type": "number"},
                              "minItems": 3, "maxItems": 3},
                "length": {"type": "number", "exclusiveMinimum": 0},
                "width": {"type": "number", "exclusiveMinimum": 0},
                "speed": {"type": "number", "exclusiveMinimum": 0},
                "theme": {"type": "string"},
                "parent": {"type": "string"},
            },
        },
        handler=conveyor_build,
    ))

    server.register(Tool(
        name="fab_aperture",
        description=(
            "Cut doors and windows into a wall with real solid geometry, and "
            "report the receipt. A doorway drawn as a dark rectangle is the "
            "single most common tell that a place is a greybox."
        ),
        input_schema={
            "type": "object",
            "required": ["wall", "openings"],
            "properties": {
                "wall": {"type": "string", "description": "full path to a BasePart"},
                "openings": {
                    "type": "array",
                    "minItems": 1,
                    "items": {
                        "type": "object",
                        "required": ["offset", "size"],
                        "properties": {
                            "offset": {"type": "array", "items": {"type": "number"},
                                       "minItems": 2, "maxItems": 2},
                            "size": {"type": "array", "items": {"type": "number"},
                                     "minItems": 2, "maxItems": 2},
                        },
                    },
                },
            },
        },
        handler=fab_aperture,
    ))

    server.register(Tool(
        name="fab_budget",
        description=(
            "What solid modelling and particles have left. Both are capped on "
            "purpose: a scene that spends the whole mesh budget on one building "
            "has nothing for the other forty."
        ),
        input_schema={"type": "object", "properties": {}},
        handler=fab_budget,
    ))

    server.register(Tool(
        name="audio_events",
        description=(
            "Every cue this game's sound bank declares, and anything wrong with "
            "it. `Audio.define` raises on an unknown event, so the list is worth "
            "reading before writing a rule that plays one."
        ),
        input_schema={"type": "object", "properties": {}},
        handler=audio_events,
    ))

    server.register(Tool(
        name="audio_play",
        description=(
            "Play one cue, optionally at an instance. Names the cues it has when "
            "asked for one it does not."
        ),
        input_schema={
            "type": "object",
            "required": ["event"],
            "properties": {
                "event": {"type": "string"},
                "at": {"type": "string", "description": "full path; omit for 2D"},
                "volume": {"type": "number", "minimum": 0, "maximum": 2},
            },
        },
        handler=audio_play,
    ))

    server.register(Tool(
        name="staging_catalogue",
        description=(
            "What the staging modules can actually do, read from the open "
            "place rather than from a list here -- so it cannot drift."
        ),
        input_schema={"type": "object", "properties": {}},
        handler=staging_catalogue,
    ))

    server.register(Tool(
        name="camera_frame",
        description=(
            "Frame the editor camera on an instance using a named profile from "
            "the token set. Framing is half the language of a scene and was the "
            "one staging capability with no tool at all."
        ),
        input_schema={
            "type": "object",
            "required": ["target"],
            "properties": {
                "target": {"type": "string",
                           "description": "full path, e.g. Workspace.Keep"},
                "profile": {"type": "string",
                            "description": "a camera profile the token set declares"},
            },
        },
        handler=camera_frame,
    ))

    server.register(Tool(
        name="camera_sweep",
        description="The viewpoints a token set declares for one subject.",
        input_schema={
            "type": "object",
            "required": ["target"],
            "properties": {"target": {"type": "string"}},
        },
        handler=camera_sweep,
    ))

    server.register(Tool(
        name="vfx_apply",
        description=(
            "A burst, highlight, trail or light on one instance, coloured from "
            "token roles so it belongs to the same palette as the world."
        ),
        input_schema={
            "type": "object",
            "required": ["target"],
            "properties": {
                "target": {"type": "string"},
                "style": {"type": "string",
                          "enum": ["burst", "highlight", "trail", "light"]},
                "fromRole": {"type": "string"},
                "toRole": {"type": "string"},
                "amount": {"type": "integer", "minimum": 1, "maximum": 200},
            },
        },
        handler=vfx_apply,
    ))

    server.register(Tool(
        name="guidance_focus",
        description=(
            "Mark one instance as where the player should look next. The "
            "onboarding primitive that existed and was never reachable."
        ),
        input_schema={
            "type": "object",
            "required": ["target"],
            "properties": {
                "target": {"type": "string"},
                "label": {"type": "string"},
                "id": {"type": "string"},
            },
        },
        handler=guidance_focus,
    ))

    server.register(Tool(
        name="guidance_clear",
        description="Remove guidance from an instance.",
        input_schema={
            "type": "object",
            "required": ["target"],
            "properties": {"target": {"type": "string"}},
        },
        handler=guidance_clear,
    ))

    server.register(Tool(
        name="nature_scatter",
        description=(
            "Plant deterministically inside a footprint. Same seed, same "
            "forest -- so a scatter can be judged, adjusted and reproduced."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "centre": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "size": {"type": "array", "items": {"type": "number"},
                         "minItems": 2, "maxItems": 2,
                         "description": "footprint extent, not a radius"},
                "count": {"type": "integer", "minimum": 1, "maximum": 400},
                "minSpacing": {"type": "number", "exclusiveMinimum": 0},
                "keepClear": {
                    "type": "array",
                    "description": "areas nothing may be planted in: roads, plots, the hub",
                    "items": {
                        "type": "object",
                        "required": ["centre", "size"],
                        "properties": {
                            "centre": {"type": "array", "items": {"type": "number"},
                                       "minItems": 3, "maxItems": 3},
                            "size": {"type": "array", "items": {"type": "number"},
                                     "minItems": 2, "maxItems": 2},
                        },
                    },
                },
                "treeRatio": {"type": "number", "minimum": 0, "maximum": 1},
                "seed": {"type": "integer"},
                "theme": {"type": "string",
                          "description": "a named Palette theme; names them when wrong"},
                "parent": {"type": "string"},
            },
        },
        handler=nature_scatter,
    ))

    server.register(Tool(
        name="setpiece_build",
        description=(
            "Build a composed setpiece -- a whole authored arrangement rather "
            "than a single prop. Names the ones it has when asked for one it "
            "does not."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "kind": {"type": "string"},
                "centre": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "parent": {"type": "string"},
            },
        },
        handler=setpiece_build,
    ))

    return server
