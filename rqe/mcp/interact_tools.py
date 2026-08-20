"""A world you can touch, and the platform it sits on.

    interact_*   clicks, prompts, signs, labels, welds, hinges
    team_*       teams, whose colours must not collide
    badge_*      achievements, awarded from the server and cached
    text_*       localisation, and the phrases nobody has translated

Every one of these was at zero. A place could be built, lit, populated and
animated, and a player could not click anything, could not read a word off a
wall, and nothing could be attached to anything else. That is a diorama.

**The refusals here are the point.** Roblox's failure mode for all of this is
silence: a weld between two anchored parts does nothing, two teams sharing a
colour merge, a badge awarded from a LocalScript never arrives, a failed
teleport strands the player with a blank screen. None of it errors. So these
tools refuse out loud where the engine would shrug.
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


def _colour(value: Any, fallback: str = "240,238,232") -> str:
    if not value:
        return f"Color3.fromRGB({fallback})"
    return f"Color3.fromRGB({value[0]},{value[1]},{value[2]})"


def register_interact_tools(server: Any) -> Any:
    """Attach world interaction and platform tools."""

    _GAMEKIT = ('local Platform = require(game:GetService("ReplicatedStorage")'
                ':WaitForChild("GameKit")).Platform')

    def interact_touchable(arguments: dict[str, Any]) -> dict[str, Any]:
        target = json.dumps(str(arguments["target"]))
        kind = str(arguments.get("kind") or "prompt")
        label = json.dumps(str(arguments.get("label") or "Use"))
        action = json.dumps(str(arguments.get("action") or "Use"))
        rng = _num(arguments, "range", 12 if kind == "prompt" else 24)
        hold = _num(arguments, "holdTime", 0)

        if kind == "click":
            body = f"""
local made = WorldKit.Interact.click(part, {{ range = {rng} }})
return {{ kind = "click", on = part:GetFullName(), range = made.MaxActivationDistance }}
"""
        else:
            body = f"""
local made = WorldKit.Interact.prompt(part, {{
    label = {label}, action = {action}, range = {rng}, holdTime = {hold},
}})
return {{ kind = "prompt", on = part:GetFullName(),
          label = made.ObjectText, action = made.ActionText }}
"""
        return _exec(server, _PRELUDE + f"""
local part = resolve({target})
if not part:IsA("BasePart") then
    error("interaction needs a BasePart, got a " .. part.ClassName, 0)
end
{body}
""")

    def interact_sign(arguments: dict[str, Any]) -> dict[str, Any]:
        target = json.dumps(str(arguments["target"]))
        text = json.dumps(str(arguments["text"]))
        face = str(arguments.get("face") or "Front")
        size = _num(arguments, "size", 1.2)
        colour = _colour(arguments.get("colour"))
        background = arguments.get("background")
        back = ("nil" if not background
                else _colour(background))
        transparency = _num(arguments, "transparency", 0.15)
        return _exec(server, _PRELUDE + f"""
local part = resolve({target})
if not part:IsA("BasePart") then
    error("a sign needs a BasePart, got a " .. part.ClassName, 0)
end
local surface = WorldKit.Interact.sign(part, {{
    text = {text}, face = Enum.NormalId.{face}, size = {size},
    colour = {colour}, background = {back}, transparency = {transparency},
}})
local label = surface:FindFirstChildWhichIsA("TextLabel", true)
return {{
    on = part:GetFullName(), face = surface.Face.Name,
    pixelsPerStud = surface.PixelsPerStud,
    textSize = label ~= nil and label.TextSize or nil,
}}
""")

    def interact_label(arguments: dict[str, Any]) -> dict[str, Any]:
        target = json.dumps(str(arguments["target"]))
        text = json.dumps(str(arguments["text"]))
        size = _num(arguments, "size", 2)
        rise = _num(arguments, "rise", 1.5)
        distance = _num(arguments, "maxDistance", 120)
        return _exec(server, _PRELUDE + f"""
local part = resolve({target})
local made = WorldKit.Interact.label(part, {{
    text = {text}, size = {size}, rise = {rise}, maxDistance = {distance},
}})
return {{ on = part:GetFullName(), maxDistance = made.MaxDistance }}
""")

    def interact_attach(arguments: dict[str, Any]) -> dict[str, Any]:
        anchor = json.dumps(str(arguments["anchor"]))
        parts = arguments.get("parts") or []
        kind = str(arguments.get("kind") or "weld")

        if kind == "hinge":
            if len(parts) != 1:
                return {"ok": False, "error": "a hinge joins exactly two parts"}
            axis = list(arguments.get("axis") or [0, 1, 0])
            lower = _num(arguments, "lower", -90)
            upper = _num(arguments, "upper", 90)
            return _exec(server, _PRELUDE + f"""
local a = resolve({anchor})
local b = resolve({json.dumps(str(parts[0]))})
local hinge = WorldKit.Interact.hinge(a, b, {{
    axis = Vector3.new({axis[0]}, {axis[1]}, {axis[2]}),
    lower = {lower}, upper = {upper},
}})
return {{ hinged = a.Name .. " <-> " .. b.Name,
          lower = hinge.LowerAngle, upper = hinge.UpperAngle }}
""")

        listed = ",".join(f"resolve({json.dumps(str(p))})" for p in parts)
        return _exec(server, _PRELUDE + f"""
local anchor = resolve({anchor})
local made, problems = WorldKit.Interact.weld(anchor, {{{listed}}})
return {{ welded = made, problems = problems }}
""")

    def interact_report(arguments: dict[str, Any]) -> dict[str, Any]:
        root = json.dumps(str(arguments.get("root") or "Workspace"))
        return _exec(server, _PRELUDE + f"""
return WorldKit.Interact.report(resolve({root}))
""", timeout=90.0)

    # -- platform ----------------------------------------------------------

    def team_declare(arguments: dict[str, Any]) -> dict[str, Any]:
        teams = arguments.get("teams") or []
        if not teams:
            return _exec(server, _PRELUDE + f"""
{_GAMEKIT}
return Platform.teamReport()
""")
        listed = ",".join(
            '{name=%s,colour=%s,autoAssign=%s}' % (
                json.dumps(str(t["name"])),
                json.dumps(str(t.get("colour") or "Medium stone grey")),
                str(bool(t.get("autoAssign", True))).lower())
            for t in teams)
        return _exec(server, _PRELUDE + f"""
{_GAMEKIT}
local ok, problems = Platform.teams({{{listed}}})
return {{ declared = ok, problems = problems, report = Platform.teamReport() }}
""")

    def badge_check(arguments: dict[str, Any]) -> dict[str, Any]:
        badges = arguments.get("badges") or []
        if not badges:
            return {"ok": False, "error": "give at least one badge to check"}
        problems: list[str] = []
        seen: dict[int, str] = {}
        for badge in badges:
            name = str(badge.get("name") or "")
            raw = badge.get("id")
            if not isinstance(raw, int) or isinstance(raw, bool) or raw <= 0:
                problems.append(
                    f"badge {name!r} needs a positive integer id -- badges are "
                    f"created on the website, nothing here can make one")
                continue
            if raw in seen:
                problems.append(f"id {raw} is used by both {seen[raw]} and {name}")
            seen[raw] = name
            if not name:
                problems.append(f"badge {raw} has no name")
            if not badge.get("earnedFor"):
                problems.append(
                    f"badge {name!r} does not say what earns it, so nothing "
                    f"can award it")
        return {
            "ok": not problems,
            "problems": problems,
            "badges": len(badges),
            "note": (
                "shape only. Awarding needs the server -- `AwardBadge` from a "
                "LocalScript silently does nothing and the player never finds out"
            ),
        }

    def text_declare(arguments: dict[str, Any]) -> dict[str, Any]:
        from .gameplay_tools import _lua

        phrases = arguments.get("phrases") or {}
        if not phrases:
            return {"ok": False, "error": "declare at least one phrase"}
        source = str(arguments.get("sourceLocale") or "en")
        return _exec(server, _PRELUDE + f"""
{_GAMEKIT}
Platform.declareText({_lua(phrases)}, {json.dumps(source)})
local report = Platform.report()
local gaps = {{}}
for _, locale in ipairs(Platform.locales()) do
    gaps[locale] = Platform.missing(locale)
end
return {{ phrases = report.phrases, locales = report.locales,
          coverage = report.coverage, missing = gaps }}
""")

    def chat_commands(arguments: dict[str, Any]) -> dict[str, Any]:
        """Validate slash commands. Handlers are Luau, so this checks shape."""

        commands = arguments.get("commands") or []
        if not commands:
            return _exec(server, _PRELUDE + """
local Chat = require(game:GetService("ReplicatedStorage")
    :WaitForChild("GameKit")).Chat
return Chat.report()
""")

        problems: list[str] = []
        seen: dict[str, str] = {}
        for index, command in enumerate(commands):
            name = str(command.get("name") or "")
            if not name:
                problems.append(f"command {index + 1} has no name")
                continue
            if name.startswith("/"):
                # The slash is added by the installer. A name written with one
                # produces `//kick`, which never matches and reads as broken.
                problems.append(f"{name}: leave the slash off the name")
            if " " in name:
                problems.append(f"{name}: a command name cannot contain a space")
            for key in (name, command.get("alias")):
                if key:
                    key = str(key)
                    if key in seen:
                        problems.append(f"two commands answer to /{key}")
                    seen[key] = name
            if not command.get("does"):
                problems.append(f"{name}: does not say what it does")

        return {
            "ok": not problems,
            "problems": problems,
            "commands": len(commands),
            "note": (
                "shape only. Any player text a command echoes must be filtered "
                "through Chat.display before another player sees it -- that "
                "calls TextService:FilterStringAsync per recipient. Showing it "
                "unfiltered is a moderation failure, not a style preference, "
                "and it covers pet names and signs as well as the chat window"
            ),
        }

    def physics_join(arguments: dict[str, Any]) -> dict[str, Any]:
        """Ropes, springs, sockets, sliders, pushes and holds."""

        kind = str(arguments.get("kind") or "rope")
        a = json.dumps(str(arguments["a"]))
        b = arguments.get("b")

        if kind == "push":
            force = list(arguments.get("force") or [0, 5000, 0])
            return _exec(server, _PRELUDE + f"""
local part = resolve({a})
local made = WorldKit.Physics.push(part, Vector3.new({force[0]}, {force[1]}, {force[2]}), {{}})
return {{ kind = "push", on = part:GetFullName(), force = tostring(made.Force) }}
""")

        if kind == "hold":
            at = list(arguments.get("at") or [0, 10, 0])
            return _exec(server, _PRELUDE + f"""
local part = resolve({a})
local made = WorldKit.Physics.hold(part, Vector3.new({at[0]}, {at[1]}, {at[2]}), {{}})
return {{ kind = "hold", on = part:GetFullName(), force = made.MaxForce }}
""")

        if not b:
            return {"ok": False,
                    "error": f"a {kind} joins two parts; give both a and b"}
        second = json.dumps(str(b))

        if kind == "rope":
            call = "WorldKit.Physics.rope(first, other, { length = LENGTH })"
            call = call.replace("LENGTH", str(_num(arguments, "length", 0)) or "nil")
            if _num(arguments, "length", 0) <= 0:
                call = "WorldKit.Physics.rope(first, other, {})"
            field = "Length"
        elif kind == "spring":
            call = ("WorldKit.Physics.spring(first, other, { stiffness = %s, damping = %s })"
                    % (_num(arguments, "stiffness", 2000), _num(arguments, "damping", 200)))
            field = "FreeLength"
        elif kind == "socket":
            call = ("WorldKit.Physics.ballSocket(first, other, { cone = %s })"
                    % _num(arguments, "cone", 45))
            field = "UpperAngle"
        elif kind == "slider":
            axis = list(arguments.get("axis") or [0, 1, 0])
            call = ("WorldKit.Physics.slider(first, other, { axis = Vector3.new(%s,%s,%s), "
                    "lower = %s, upper = %s })"
                    % (axis[0], axis[1], axis[2],
                       _num(arguments, "lower", 0), _num(arguments, "upper", 8)))
            field = "UpperLimit"
        else:
            return {"ok": False,
                    "error": f"no joint kind {kind!r}; have rope, spring, socket, "
                             "slider, push, hold"}

        return _exec(server, _PRELUDE + f"""
local first = resolve({a})
local other = resolve({second})
local made = {call}
return {{ kind = "{kind}", joined = first.Name .. " <-> " .. other.Name,
          value = made.{field} }}
""")

    def physics_ragdoll(arguments: dict[str, Any]) -> dict[str, Any]:
        who = json.dumps(str(arguments["who"]))
        return _exec(server, _PRELUDE + f"""
local wanted = {who}
local total, notes = 0, {{}}
for _, item in ipairs(workspace:GetDescendants()) do
    if item:IsA("Model") and item.Name == wanted then
        local converted, problems = WorldKit.Physics.ragdoll(item)
        total += converted
        for _, note in ipairs(problems) do table.insert(notes, note) end
    end
end
if total == 0 and #notes == 0 then
    error("no Model named " .. wanted .. " in the workspace", 0)
end
return {{ joints = total, problems = notes }}
""")

    def physics_report(arguments: dict[str, Any]) -> dict[str, Any]:
        root = json.dumps(str(arguments.get("root") or "Workspace"))
        return _exec(server, _PRELUDE + f"""
return WorldKit.Physics.report(resolve({root}))
""", timeout=90.0)

    def policy_check(arguments: dict[str, Any]) -> dict[str, Any]:
        """What a game may show, and whether it asks before showing it."""

        features = arguments.get("features") or []
        if not features:
            return _exec(server, _PRELUDE + """
local Reach = require(game:GetService("ReplicatedStorage")
    :WaitForChild("GameKit")).Reach
return Reach.report()
""")

        # Each of these is gated by PolicyService per player, and shipping one
        # ungated is a compliance failure rather than a design choice.
        GATED = {
            "randomPaidItems": "Reach.mayShowRandomPaidItems",
            "externalLinks": "Reach.mayLinkTo",
            "trading": "Reach.mayTrade",
        }
        problems: list[str] = []
        for feature in features:
            name = str(feature.get("name") or "")
            kind = str(feature.get("kind") or "")
            if kind not in GATED:
                problems.append(
                    f"{name or kind!r}: no policy gate named {kind!r}; have "
                    + ", ".join(sorted(GATED)))
                continue
            if not feature.get("gated"):
                problems.append(
                    f"{name}: {kind} must be checked with {GATED[kind]} before "
                    f"it is shown. Roblox decides this per player, by age and "
                    f"country, and it is enforced")

        return {
            "ok": not problems,
            "problems": problems,
            "features": len(features),
            "gates": GATED,
            "note": (
                "an unreadable policy denies rather than allows -- an outage "
                "must not silently turn compliance off"
            ),
        }

    def reach_publish(arguments: dict[str, Any]) -> dict[str, Any]:
        topic = json.dumps(str(arguments["topic"]))
        payload = arguments.get("payload")
        if payload is None:
            return {"ok": False, "error": "give a payload to publish"}
        from .gameplay_tools import _lua

        return _exec(server, _PRELUDE + f"""
local Reach = require(game:GetService("ReplicatedStorage")
    :WaitForChild("GameKit")).Reach
local ok, why = Reach.publish({topic}, {_lua(payload)})
return {{
    published = ok, error = why, topic = {topic},
    note = "PublishAsync does not deliver to the sender; a server that only "
        .. "updates itself in the subscriber never sees its own change",
}}
""")

    # -- registration ------------------------------------------------------

    server.register(Tool(
        name="chat_commands",
        description=(
            "Validate a set of slash commands, or read the installed ones when "
            "given none. Player text that any command echoes must pass "
            "`Chat.display` first: Roblox requires every user-authored string "
            "shown to another player to be filtered -- pet names and signs "
            "included, not just the chat window -- and games are taken down for "
            "it."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "commands": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "does"],
                        "properties": {
                            "name": {"type": "string",
                                     "description": "without the leading slash"},
                            "alias": {"type": "string"},
                            "does": {"type": "string"},
                        },
                    },
                },
            },
        },
        handler=chat_commands,
    ))

    server.register(Tool(
        name="physics_join",
        description=(
            "Ropes, springs, ball sockets, sliders, steady pushes and holds. "
            "Every constraint in Roblox joins two Attachments rather than two "
            "parts, and one with a nil end installs cleanly and does nothing -- "
            "these make and place their own. Refuses a joint between two "
            "anchored parts, which is the same silent failure as welding them."
        ),
        input_schema={
            "type": "object",
            "required": ["a"],
            "properties": {
                "kind": {"type": "string",
                         "enum": ["rope", "spring", "socket", "slider", "push", "hold"]},
                "a": {"type": "string", "description": "full path to a BasePart"},
                "b": {"type": "string", "description": "the other part; not used by push or hold"},
                "length": {"type": "number", "description": "rope: defaults to the current gap"},
                "stiffness": {"type": "number"},
                "damping": {"type": "number",
                            "description": "spring: undamped springs oscillate forever"},
                "cone": {"type": "number", "description": "socket: degrees of freedom"},
                "axis": {"type": "array", "items": {"type": "number"},
                         "minItems": 3, "maxItems": 3},
                "lower": {"type": "number"},
                "upper": {"type": "number"},
                "force": {"type": "array", "items": {"type": "number"},
                          "minItems": 3, "maxItems": 3},
                "at": {"type": "array", "items": {"type": "number"},
                       "minItems": 3, "maxItems": 3,
                       "description": "hold: where to keep it"},
            },
        },
        handler=physics_join,
    ))

    server.register(Tool(
        name="physics_ragdoll",
        description=(
            "Turn a character into a body. Not 'switch off the Humanoid' -- the "
            "Motor6Ds keep it rigid, so that gives a statue that topples in one "
            "piece. Each Motor6D is replaced by a ball socket at the same "
            "attachment points, and the count comes back so a real ragdoll can "
            "be told from a model that had no rig."
        ),
        input_schema={
            "type": "object",
            "required": ["who"],
            "properties": {"who": {"type": "string", "description": "Model name"}},
        },
        handler=physics_ragdoll,
    ))

    server.register(Tool(
        name="physics_report",
        description=(
            "What can move, and what is quietly inert: constraints with an "
            "unattached end, and joints between two anchored parts. Both look "
            "exactly like a working constraint in the explorer."
        ),
        input_schema={
            "type": "object",
            "properties": {"root": {"type": "string"}},
        },
        handler=physics_report,
    ))

    server.register(Tool(
        name="policy_check",
        description=(
            "Does this game gate what Roblox requires it to gate? Paid random "
            "items, external links and trading are decided per player by age "
            "and country, and showing one to a player whose policy forbids it "
            "is enforced, not a design choice. Call with no features to read "
            "what the running game has."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "features": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "kind"],
                        "properties": {
                            "name": {"type": "string"},
                            "kind": {"type": "string",
                                     "enum": ["randomPaidItems", "externalLinks",
                                              "trading"]},
                            "gated": {"type": "boolean",
                                      "description": "is it checked before being shown"},
                        },
                    },
                },
            },
        },
        handler=policy_check,
    ))

    server.register(Tool(
        name="reach_publish",
        description=(
            "Send a message to every other server running this experience. "
            "Not delivered to the sender -- a server that updates its own state "
            "only in the subscriber never sees its own change, which looks "
            "exactly like the message never arriving."
        ),
        input_schema={
            "type": "object",
            "required": ["topic", "payload"],
            "properties": {
                "topic": {"type": "string", "maxLength": 80},
                "payload": {"description": "any JSON value"},
            },
        },
        handler=reach_publish,
    ))

    server.register(Tool(
        name="interact_touchable",
        description=(
            "Make a part usable: a hold-to-use ProximityPrompt, or a "
            "ClickDetector. Ranges default to something that works at real "
            "scale -- Roblox's 32-stud default leaves a player unable to click "
            "the door they are standing in front of."
        ),
        input_schema={
            "type": "object",
            "required": ["target"],
            "properties": {
                "target": {"type": "string", "description": "full path to a BasePart"},
                "kind": {"type": "string", "enum": ["prompt", "click"]},
                "label": {"type": "string"},
                "action": {"type": "string"},
                "range": {"type": "number", "exclusiveMinimum": 0},
                "holdTime": {"type": "number", "minimum": 0},
            },
        },
        handler=interact_touchable,
    ))

    server.register(Tool(
        name="interact_sign",
        description=(
            "Readable text on a face of a part. Sized in studs, because a sign "
            "is a physical object -- a SurfaceGui at defaults makes a 20-stud "
            "wall a 1000-pixel canvas, on which normal text is invisible. That "
            "is why every first attempt at a sign looks blank."
        ),
        input_schema={
            "type": "object",
            "required": ["target", "text"],
            "properties": {
                "target": {"type": "string"},
                "text": {"type": "string"},
                "face": {"type": "string",
                         "enum": ["Front", "Back", "Left", "Right", "Top", "Bottom"]},
                "size": {"type": "number", "exclusiveMinimum": 0,
                         "description": "cap height in studs"},
                "colour": {"type": "array", "items": {"type": "integer"},
                           "minItems": 3, "maxItems": 3},
                "background": {"type": "array", "items": {"type": "integer"},
                               "minItems": 3, "maxItems": 3},
                "transparency": {"type": "number", "minimum": 0, "maximum": 1},
            },
        },
        handler=interact_sign,
    ))

    server.register(Tool(
        name="interact_label",
        description=(
            "A floating name above a part. Capped by distance -- without that a "
            "label draws from across the map and a scene collects forty of them "
            "stacked in the skyline."
        ),
        input_schema={
            "type": "object",
            "required": ["target", "text"],
            "properties": {
                "target": {"type": "string"},
                "text": {"type": "string"},
                "size": {"type": "number", "exclusiveMinimum": 0},
                "rise": {"type": "number"},
                "maxDistance": {"type": "number", "exclusiveMinimum": 0},
            },
        },
        handler=interact_label,
    ))

    server.register(Tool(
        name="interact_attach",
        description=(
            "Weld parts together, or hinge two of them for a door or lever. "
            "Refuses a weld between two anchored parts -- Roblox creates it, it "
            "does nothing, and it says nothing, which is the most common "
            "'my machine will not move' bug there is."
        ),
        input_schema={
            "type": "object",
            "required": ["anchor", "parts"],
            "properties": {
                "anchor": {"type": "string"},
                "parts": {"type": "array", "items": {"type": "string"},
                          "minItems": 1},
                "kind": {"type": "string", "enum": ["weld", "hinge"]},
                "axis": {"type": "array", "items": {"type": "number"},
                         "minItems": 3, "maxItems": 3},
                "lower": {"type": "number"},
                "upper": {"type": "number"},
            },
        },
        handler=interact_attach,
    ))

    server.register(Tool(
        name="interact_report",
        description=(
            "How much of this world can be touched or read: clickables, "
            "prompts, signs, labels, welds and hinges, plus any constraint with "
            "a dangling end. A place with zero interactive parts is scenery."
        ),
        input_schema={
            "type": "object",
            "properties": {"root": {"type": "string"}},
        },
        handler=interact_report,
    ))

    server.register(Tool(
        name="team_declare",
        description=(
            "Declare the game's teams, or read them back when given none. "
            "Refuses two teams sharing a colour: Roblox keys teams by "
            "BrickColor, so a collision merges them and every player on the "
            "second lands on the first, with no error anywhere."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "teams": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "colour"],
                        "properties": {
                            "name": {"type": "string"},
                            "colour": {"type": "string",
                                       "description": "a BrickColor name, e.g. 'Bright red'"},
                            "autoAssign": {"type": "boolean"},
                        },
                    },
                },
            },
        },
        handler=team_declare,
    ))

    server.register(Tool(
        name="badge_check",
        description=(
            "Validate a badge catalogue before wiring it. Nothing here creates "
            "a badge -- they are made on the website and their ids arrive. "
            "Checks that no id is duplicated and that every badge says what "
            "earns it, because one that does not can never be awarded."
        ),
        input_schema={
            "type": "object",
            "required": ["badges"],
            "properties": {
                "badges": {
                    "type": "array",
                    "minItems": 1,
                    "items": {
                        "type": "object",
                        "required": ["id", "name", "earnedFor"],
                        "properties": {
                            "id": {"type": "integer", "minimum": 1},
                            "name": {"type": "string"},
                            "earnedFor": {"type": "string"},
                        },
                    },
                },
            },
        },
        handler=badge_check,
    ))

    server.register(Tool(
        name="text_declare",
        description=(
            "Declare the game's text by phrase and locale, and report which "
            "phrases nobody has translated. A translator that falls back to the "
            "key puts `shop.buy.confirm` on a button; this falls back to the "
            "source language and names the gaps instead."
        ),
        input_schema={
            "type": "object",
            "required": ["phrases"],
            "properties": {
                "sourceLocale": {"type": "string"},
                "phrases": {
                    "type": "object",
                    "description": "{ key: { locale: text } }",
                    "additionalProperties": {
                        "type": "object",
                        "additionalProperties": {"type": "string"},
                    },
                },
            },
        },
        handler=text_declare,
    ))

    return server
