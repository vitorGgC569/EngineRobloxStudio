"""Behaviour, composable a rule at a time.

    gameplay_vocabulary   what a rule may say: triggers, conditions, effects
    gameplay_check        validate rules against what this game actually has
    gameplay_compile      turn validated rules into what the runtime installs
    gameplay_install      put them into the live place, and report what fired

The gap these close is the one the rest of the surface did not have. World,
look, sound and interface were all composable a piece at a time. Behaviour
arrived whole, from a genre recipe -- so a horror brief came out as a tower
defense wearing a horror palette, because the recipe chose the game.

`gameplay_check` is separate from `gameplay_install` for the same reason
`sourcing_publish` is separate from `sourcing_adopt`: one is free and reversible,
the other reaches a running game. A caller should be able to ask "is this rule
coherent" without committing to it.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .server import Tool


def _lua(value: Any) -> str:
    """A Lua table literal, because Lua is not JSON.

    The first version interpolated `json.dumps(rules)` straight into the Script
    and the place answered with a parse error on line 11: JSON arrays open with
    `[`, JSON objects separate keys with `:`, and Lua accepts neither. The two
    look close enough to work right up until they do not.
    """

    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "nil"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        out = value.replace(chr(92), chr(92) * 2)
        out = out.replace(chr(34), chr(92) + chr(34))
        out = out.replace(chr(10), chr(92) + "n").replace(chr(13), "")
        return chr(34) + out + chr(34)
    if isinstance(value, (list, tuple)):
        return "{" + ",".join(_lua(item) for item in value) + "}"
    if isinstance(value, dict):
        parts = []
        # `then` and `require` are Lua keywords, so those keys have to be
        # indexed rather than written as fields. The rule vocabulary uses both
        # on purpose -- they are the words a reader expects -- and this is the
        # one place that costs anything.
        reserved = {"then", "end", "require", "and", "or", "not", "if",
                    "do", "for", "in", "local", "nil", "true", "false"}
        for key, item in value.items():
            name = str(key)
            if name.isidentifier() and name not in reserved:
                parts.append(name + "=" + _lua(item))
            else:
                parts.append("[" + _lua(name) + "]=" + _lua(item))
        return "{" + ",".join(parts) + "}"
    raise TypeError("cannot express " + repr(value) + " as Lua")


def register_gameplay_tools(server: Any) -> Any:
    """Attach the gameplay authoring tools to an MCP server."""

    from ..gameplay import compile_rules, from_dicts, problems, vocabulary
    from ..gameplay.rules import RuleError
    from ..security import SecurityBoundaryError, validate_path_component

    def _known(arguments: dict[str, Any]) -> tuple[list[str], list[str]]:
        """What this game declares, so a rule can be checked against reality."""

        currencies = [str(item) for item in arguments.get("currencies") or ()]
        cues = [str(item) for item in arguments.get("cues") or ()]
        game_id = str(arguments.get("gameId") or "")
        if game_id and not cues:
            try:
                safe_game_id = validate_path_component(game_id, label="gameId")
            except SecurityBoundaryError as exc:
                raise RuleError(str(exc)) from exc
            record = server.root / "games" / safe_game_id / "audio-provenance.json"
            if record.is_file():
                data = json.loads(record.read_text(encoding="utf-8"))
                cues = sorted(data.get("cues") or {})
        return currencies, cues

    def show_vocabulary(_arguments: dict[str, Any]) -> dict[str, Any]:
        return vocabulary()

    def check(arguments: dict[str, Any]) -> dict[str, Any]:
        currencies, cues = _known(arguments)
        rules = from_dicts(arguments.get("rules") or [])
        found = {
            rule.id: problems(rule, currencies=currencies, cues=cues)
            for rule in rules
        }
        bad = {key: value for key, value in found.items() if value}
        return {
            "rules": len(rules),
            "ok": not bad,
            "problems": bad,
            "checkedAgainst": {"currencies": currencies, "cues": cues},
            "note": (
                "checked against what the game declares; an empty currency list "
                "means only shape was checked, not names"
            ),
        }

    def compile_(arguments: dict[str, Any]) -> dict[str, Any]:
        currencies, cues = _known(arguments)
        try:
            return compile_rules(
                from_dicts(arguments.get("rules") or []),
                currencies=currencies, cues=cues)
        except RuleError as error:
            return {"compiled": False, "error": str(error)}

    def install(arguments: dict[str, Any]) -> dict[str, Any]:
        currencies, cues = _known(arguments)
        rules = from_dicts(arguments.get("rules") or [])
        advisories: list[str] = []
        try:
            plan = compile_rules(rules, currencies=currencies, cues=cues)
        except RuleError as error:
            # Advice, not a gate. A caller who knows something the validator
            # does not -- a currency declared at runtime, a cue added by hand --
            # must be able to proceed, and the result says plainly that they did.
            if arguments.get("force") is not True:
                return {
                    "installed": False,
                    "error": str(error),
                    "note": (
                        "this is advice: pass force:true to install anyway. "
                        "Nothing here decides what your game may contain"
                    ),
                }
            advisories.append(str(error))
            plan = compile_rules(rules, currencies=[], cues=[])

        from ..hub.client import StudioBridge

        source = _INSTALL_SOURCE.replace("__RULES__", _lua(plan["rules"]))
        bridge = StudioBridge(allow_arbitrary=True)
        try:
            with bridge.lease_scope(
                agent_id="mcp-gameplay-install",
                context="edit",
                ttl_seconds=90.0,
            ):
                result = bridge.call("bridge.exec", {"source": source}, timeout=60.0)
        except Exception as error:
            # Edit context only, and that is the right constraint: authoring
            # writes into the place, and a play session has no place to write to.
            return {
                "installed": False,
                "error": str(error),
                "remedy": (
                    "authoring writes a Script into the open place, which needs "
                    "edit context. Stop Play Solo, install, then play -- the "
                    "rules come up with the session and survive a restart"
                ),
            }
        returned = result.get("returned") if isinstance(result, dict) else result
        return {
            "installed": True,
            "rules": len(plan["rules"]),
            "capabilities": plan["capabilities"],
            "advisories": advisories,
            "forced": bool(arguments.get("force")),
            "runtime": returned,
            "note": (
                "installed into the open place. `fired` and `refused` say which "
                "rules ran and which had a condition turn them away -- the two "
                "look identical from outside and mean opposite things"
            ),
        }

    server.register(Tool(
        name="gameplay_vocabulary",
        description=(
            "Everything a rule may say: triggers, conditions and effects, with "
            "what each one needs. Read this before writing rules."
        ),
        input_schema={"type": "object", "properties": {}},
        handler=show_vocabulary,
    ))

    server.register(Tool(
        name="gameplay_check",
        description=(
            "Validate rules without installing anything. Checks shape, and "
            "checks names against what the game declares when told."
        ),
        input_schema={
            "type": "object",
            "required": ["rules"],
            "properties": {
                "rules": {"type": "array", "items": {"type": "object"}},
                "gameId": {"type": "string",
                           "description": "reads the game's audio cues to check `play`"},
                "currencies": {"type": "array", "items": {"type": "string"}},
                "cues": {"type": "array", "items": {"type": "string"}},
            },
        },
        handler=check,
    ))

    server.register(Tool(
        name="gameplay_compile",
        description=(
            "Validate a whole set and return what the runtime would install. "
            "Refuses the set rather than the bad rule: a half-installed "
            "behaviour looks like a design choice."
        ),
        input_schema={
            "type": "object",
            "required": ["rules"],
            "properties": {
                "rules": {"type": "array", "items": {"type": "object"}},
                "gameId": {"type": "string"},
                "currencies": {"type": "array", "items": {"type": "string"}},
                "cues": {"type": "array", "items": {"type": "string"}},
            },
        },
        handler=compile_,
    ))

    server.register(Tool(
        name="gameplay_install",
        description=(
            "Install rules into the place Studio has open. Validation is "
            "advice: a problem stops the install by default and `force` walks "
            "past it, recording that it did. Nothing here decides what your "
            "game may contain."
        ),
        input_schema={
            "type": "object",
            "required": ["rules"],
            "properties": {
                "rules": {"type": "array", "items": {"type": "object"}},
                "gameId": {"type": "string"},
                "currencies": {"type": "array", "items": {"type": "string"}},
                "cues": {"type": "array", "items": {"type": "string"}},
                "force": {
                    "type": "boolean",
                    "description": "install despite validation advice; the "
                                   "result records that you did",
                },
            },
        },
        handler=install,
    ))

    return server


#: Authored into the place as a Script, not installed into a live session.
#:
#: The first version installed rules straight into the running game through
#: `bridge.exec`. Two things were wrong with that. `bridge.exec` is edit-only,
#: so it refused outright once Play Solo was running -- and more importantly,
#: connections made in a play session die with it. A rule that vanishes when you
#: stop playing is a rule you have to reinstall on every iteration.
#:
#: So the tool writes a Script into the open place instead. It runs when the
#: game runs, it survives a restart, and it is saved with the place -- which is
#: what authoring means. Emitting into `src/` for a rule that has settled is
#: still `producer_run`, and this is the loop before that.
_INSTALL_SOURCE = """
local ServerScriptService = game:GetService("ServerScriptService")

local existing = ServerScriptService:FindFirstChild("RQEAuthoredRules")
if existing ~= nil then
    existing:Destroy()
end

local script_ = Instance.new("Script")
script_.Name = "RQEAuthoredRules"
script_.Source = [==[
-- Authored behaviour. Written by gameplay_install; edit the rules, not this.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameKit = require(ReplicatedStorage:WaitForChild("GameKit"))
local WorldKit = require(ReplicatedStorage:WaitForChild("WorldKit"))

local tokens = nil
pcall(function()
    tokens = WorldKit.Tokens.define(require(ReplicatedStorage.Shared.TokenData))
end)

local installed = GameKit.Rules.install(__RULES__, {
    tokens = tokens,
    audio = WorldKit.Audio,
    world = workspace,
    announce = function(player, message)
        player:SetAttribute("RQEAnnounce", message)
    end,
})

workspace:SetAttribute("RQEAuthoredRuleCount", installed.rules)
for _, problem in ipairs(installed.problems) do
    warn("[RQEAuthoredRules] " .. problem)
end
print(("[RQEAuthoredRules] %d rules live"):format(installed.rules))
]==]
script_.Parent = ServerScriptService

return { authored = true, path = script_:GetFullName(), bytes = #script_.Source }
"""
