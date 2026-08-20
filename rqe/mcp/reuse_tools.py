"""Reusing instead of starting over: assets, patterns, and Roblox's own store.

Three kinds of reuse, and the platform only had one of them.

    asset_find     Roblox's Creator Store, the largest library there is, and
                   the only one that needs no conversion
    pattern_*      code shapes worth copying, with the source
    sdk_skeleton   whole games as starting code (in engine_tools)

**The Creator Store was at zero.** The sourcing layer catalogued Kenney,
Quaternius, ambientCG, Poly Haven and game-icons -- all of which need a download,
a licence check and an upload -- while the store built into Studio, containing
orders of magnitude more and already in Roblox's own format, was unreachable.

It is reached through Roblox's MCP server rather than this bridge, because
`InsertService` and the store API are not available to a third-party plugin.
Results are stamped with their source, like every federated result.
"""

from __future__ import annotations

from typing import Any

from .server import Tool


#: Code shapes worth having on hand, with what each is for and what it avoids.
#:
#: Not a framework and not generated: these are the answers to "how do I do the
#: thing everybody does", written out so an agent can copy one and change it
#: rather than rediscover the shape.
PATTERNS: dict[str, dict[str, str]] = {
    "service": {
        "what": "A system with a lifecycle: start it, stop it, and it cleans up.",
        "why": "The shape that stops leaks. Everything it connects goes in the trove.",
        "source": '''local Core = require(game:GetService("ReplicatedStorage").Core)

local Sanity = {}
Sanity.__index = Sanity

function Sanity.start(options)
    local self = setmetatable({
        trove = Core.Trove.new(),
        drain = options.drain or 1.5,
    }, Sanity)

    -- Everything connected goes in the trove, so `stop` really stops it.
    self.trove:add(Core.Timer.every(1, function()
        for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
            Core.Actions.add(player, "Sanity", -self.drain, { min = 0, max = 100 })
        end
    end), "cancel")

    self.trove:add(Core.Events.onCharacter(function(_, player)
        Core.Actions.set(player, "Sanity", 100)
    end))

    return self
end

function Sanity:stop()
    self.trove:clean()
end

return Sanity''',
    },
    "state-machine": {
        "what": "Something with modes, and rules about moving between them.",
        "why": "A string plus a pile of `if` is how a door ends up open and closed.",
        "source": '''local Core = require(game:GetService("ReplicatedStorage").Core)

local function makeGuard(model)
    return Core.StateMachine.new({
        idle = {
            to = { "alert" },
            update = function(context, delta)
                local seen = Core.Spatial.nearestPlayer(model:GetPivot().Position, 60)
                if seen ~= nil then
                    context.machine:to("alert")
                end
            end,
        },
        alert = {
            to = { "chasing", "idle" },
            enter = function() Core.Actions.sound("0", { at = model }) end,
        },
        chasing = {
            to = { "idle" },
            enter = function(context)
                require(game.ReplicatedStorage.GameKit).Pursuit.start(model, {
                    mode = "chase", speed = 16,
                })
            end,
            exit = function()
                require(game.ReplicatedStorage.GameKit).Pursuit.stop(model)
            end,
        },
    }, "idle", { model = model })
end

return makeGuard''',
    },
    "zone-trigger": {
        "what": "Something that happens when a player enters or leaves an area.",
        "why": "`Touched` fires forty times a second and has no reliable exit.",
        "source": '''local Core = require(game:GetService("ReplicatedStorage").Core)

local safe = Core.Zone.new(Vector3.new(0, 8, 0), Vector3.new(40, 20, 40))

safe.entered:connect(function(character, player)
    if player == nil then return end
    Core.Actions.set(player, "Sheltered", true)
    Core.Actions.notify(player, "You are safe here.")
end)

safe.left:connect(function(character, player)
    if player == nil then return end
    Core.Actions.set(player, "Sheltered", false)
end)

return safe''',
    },
    "replicated-state": {
        "what": "Server state a client can read without a RemoteEvent per value.",
        "why": "Attributes replicate for free and a bound HUD follows them.",
        "source": '''local Core = require(game:GetService("ReplicatedStorage").Core)

-- Attributes on the player replicate to that player automatically, so a HUD
-- bound with WorldKit.Compose follows without any networking code at all.
local function grant(player, currency, amount)
    local now = Core.Actions.add(player, currency, amount, { min = 0 })
    Core.Events.emit("currency.changed", player, currency, now)
    return now
end

Core.Events.on("currency.changed", function(player, currency, value)
    if currency == "Embers" and value >= 6 then
        Core.Events.emit("night.survived", player)
    end
end)

return grant''',
    },
    "object-pool": {
        "what": "Reusing instances instead of creating and destroying them.",
        "why": "Thirty projectiles a second is 1800 a minute of replication churn.",
        "source": '''local Core = require(game:GetService("ReplicatedStorage").Core)

local template = Instance.new("Part")
template.Size = Vector3.new(0.4, 0.4, 2)
template.Material = Enum.Material.Neon
template.Anchored = true
template.CanCollide = false

local bolts = Core.Pool.ofPart(template, { parent = workspace, cap = 64 })

local function fire(from, to, speed)
    local bolt = bolts:get()
    bolt.CFrame = CFrame.lookAt(from, to)
    local travelled, distance = 0, (to - from).Magnitude
    Core.Timer.each(function(delta)
        travelled += speed * delta
        if travelled >= distance then
            bolts:give(bolt)   -- back to the pool, not destroyed
            return true
        end
        bolt.CFrame = bolt.CFrame + bolt.CFrame.LookVector * (speed * delta)
        return false
    end)
end

return fire''',
    },
    "round-loop": {
        "what": "Intermission, play, results, repeat.",
        "why": "The spine of every competitive game, and easy to get subtly wrong.",
        "source": '''local Core = require(game:GetService("ReplicatedStorage").Core)
local Behaviours = require(game:GetService("ReplicatedStorage").Behaviours)

local round = Behaviours.Play.round({
    intermission = 15,
    length = 180,
})

round.started:connect(function(number)
    for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
        Core.Actions.notify(player, ("Round %d"):format(number))
        Core.Actions.teleport(player, Vector3.new(0, 8, 0))
    end
end)

round.ended:connect(function(number, reason)
    for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
        Core.Actions.notify(player, ("Round %d over (%s)"):format(number, reason))
    end
end)

return round''',
    },
    "save-load": {
        "what": "State that survives a rejoin.",
        "why": "A DataStore call that is not retried loses somebody's progress.",
        "source": '''local Core = require(game:GetService("ReplicatedStorage").Core)
local GameKit = require(game:GetService("ReplicatedStorage").GameKit)

local KEYS = { "Cash", "Tier", "Best" }

Core.Events.onPlayer(function(player)
    local loaded = GameKit.Save.load(player)
    for _, key in ipairs(KEYS) do
        Core.Actions.set(player, key, (loaded and loaded[key]) or 0)
    end
end)

Core.Events.onPlayerLeft(function(player)
    local snapshot = {}
    for _, key in ipairs(KEYS) do
        snapshot[key] = Core.Actions.get(player, key, 0)
    end
    GameKit.Save.store(player, snapshot)
end)''',
    },
}


def register_reuse_tools(server: Any) -> Any:
    """Attach store search and the pattern library."""

    def asset_find(arguments: dict[str, Any]) -> dict[str, Any]:
        """Search Roblox's Creator Store, through their own MCP server."""

        from .client import ADOPTED_TOOLS, FEDERATED_SOURCE, StudioMcpClient

        query = str(arguments["query"])
        wanted = "insert_asset" if arguments.get("insert") else "search_asset"
        if wanted not in ADOPTED_TOOLS:
            return {"ok": False, "error": f"{wanted} is not an adopted tool"}

        client = StudioMcpClient()
        try:
            client.spawn()
            client.initialize()
            payload: dict[str, Any] = {"query": query}
            if arguments.get("limit"):
                payload["limit"] = int(arguments["limit"])
            if arguments.get("assetId"):
                payload["assetId"] = arguments["assetId"]
            result = client.call_tool(wanted, payload)
        except Exception as error:  # noqa: BLE001
            return {
                "ok": False,
                "error": str(error),
                "source": FEDERATED_SOURCE,
                "why": (
                    "the Creator Store is reached through Roblox's own MCP "
                    "server: InsertService and the store API are not available "
                    "to a third-party plugin"
                ),
            }
        finally:
            try:
                client.close()
            except Exception:  # noqa: BLE001
                pass

        out = result.to_dict() if hasattr(result, "to_dict") else {"result": str(result)}
        out["source"] = FEDERATED_SOURCE
        out["note"] = (
            "already in Roblox's format -- no download, no licence conversion, "
            "no upload. Check the creator and the licence before shipping it"
        )
        return out

    def pattern(arguments: dict[str, Any]) -> dict[str, Any]:
        name = str(arguments.get("name") or "").strip()
        if not name:
            return {
                "patterns": {
                    key: value["what"] for key, value in sorted(PATTERNS.items())
                },
                "note": (
                    "copy one and change it. These are the answers to 'how does "
                    "everybody do this', not a framework you have to adopt"
                ),
            }
        found = PATTERNS.get(name)
        if found is None:
            return {"error": f"no pattern {name!r}", "patterns": sorted(PATTERNS)}
        return {"name": name, **found}

    server.register(Tool(
        name="asset_find",
        description=(
            "Search Roblox's Creator Store -- the largest asset library there "
            "is, and the only one already in Roblox's format. Reached through "
            "Roblox's own MCP server, because InsertService is not available to "
            "a third-party plugin. Results are stamped with their source."
        ),
        input_schema={
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 50},
                "insert": {"type": "boolean",
                           "description": "insert it into the place rather than listing"},
                "assetId": {"type": "string"},
            },
        },
        handler=asset_find,
    ))

    server.register(Tool(
        name="pattern",
        description=(
            "Code shapes worth copying: a service with a lifecycle, a state "
            "machine, a zone trigger, replicated state, an object pool, a round "
            "loop, save and load. Call with no name to list them."
        ),
        input_schema={
            "type": "object",
            "properties": {"name": {"type": "string"}},
        },
        handler=pattern,
    ))

    return server
