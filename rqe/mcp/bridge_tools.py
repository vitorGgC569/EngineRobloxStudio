"""The Studio bridge, exposed through MCP.

The engine's MCP server started with only the tools that work without Studio.
That was the right first step and the wrong final shape: if MCP is the interface
to the engine, then the engine's largest surface -- 57 typed commands against a
live DataModel -- cannot be reachable only from a Python CLI.

Exposed as **four** tools rather than one descriptor per Studio command, on purpose:

  bridge_status    what is connected, and in which context
  bridge_commands  the command surface, grouped into families
  bridge_lease     acquire, renew or release a fenced build/session lease
  bridge_call      invoke any command, validated against the manifest

One `bridge_call` keeps the manifest as the single source of truth. Fifty-seven
generated tool descriptors would be a second copy that drifts, and an agent
choosing between fifty-seven near-identical names is worse off than one reading
a family listing.

Two properties are preserved across the boundary and neither is optional:

**Mutations stay declared.** `bridge_call` reports the command's effect and
idempotency alongside the result, so an agent can see that a publish or a delete
is `at-most-once` and must not be retried.

**A refusal stays a refusal.** Lease conflicts, wrong-context errors and
disconnected sessions come back as errors with their bridge error code intact,
never as an empty success.
"""

from __future__ import annotations

import os
from typing import Any

from .server import EngineMcpServer, Tool, ToolError
from ..security import SecurityBoundaryError, validate_hub_url
from ..workspace import hub_url


DEFAULT_HUB_URL = hub_url()


def _hub_url(arguments: dict[str, Any]) -> str:
    candidate = (
        arguments.get("hub")
        or os.environ.get("RQE_HUB_URL")
        or DEFAULT_HUB_URL
    )
    try:
        return validate_hub_url(str(candidate))
    except SecurityBoundaryError as exc:
        raise ToolError(str(exc)) from exc


def _bridge(arguments: dict[str, Any], *, allow_arbitrary: bool = False):
    from ..hub.client import StudioBridge

    # The token is read from the environment only. Accepting it as an argument
    # would put a credential into the agent transcript.
    return StudioBridge(
        _hub_url(arguments),
        token=os.environ.get("RQE_BRIDGE_TOKEN"),
        allow_arbitrary=allow_arbitrary,
    )


def _family(method: str) -> str:
    return method.split(".", 1)[0]


def register_bridge_tools(server: EngineMcpServer) -> EngineMcpServer:
    """Add the live-Studio surface to an engine MCP server."""

    def bridge_status(arguments: dict[str, Any]) -> dict[str, Any]:
        bridge = _bridge(arguments)
        try:
            health = bridge.health()
        except Exception as exc:  # noqa: BLE001 - unreachable hub is an answer
            return {
                "reachable": False,
                "hub": _hub_url(arguments),
                "reason": f"{type(exc).__name__}: {exc}",
                "sessions": [],
            }
        try:
            status = bridge.status()
        except Exception:  # noqa: BLE001
            status = {}
        sessions = status.get("sessions", []) if isinstance(status, dict) else []
        return {
            "reachable": True,
            "hub": _hub_url(arguments),
            "health": health,
            "sessions": sessions,
            "sessionCount": len(sessions),
            # A hub with no plugin attached is reachable and useless, and the
            # difference matters to whatever plans the next step.
            "pluginConnected": any(
                isinstance(item, dict) and item.get("pollWaiting", 0) for item in sessions
            ) if sessions else False,
        }

    server.register(Tool(
        name="bridge_status",
        description=(
            "Report whether the bridge hub is reachable and which Studio sessions are "
            "attached, with their context. A reachable hub with no plugin is not a "
            "usable bridge, and this distinguishes them."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {"hub": {"type": "string", "minLength": 1}},
        },
        handler=bridge_status,
    ))

    def bridge_commands(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..hub.commands import load_default_registry

        registry = load_default_registry(verify_dispatcher=False)
        wanted = arguments.get("family")
        families: dict[str, list[dict[str, Any]]] = {}
        for method in registry.methods():
            family = _family(method)
            if wanted and family != wanted:
                continue
            spec = registry.require(method)
            families.setdefault(family, []).append({
                "method": method,
                "effect": spec.effect,
                "idempotency": spec.idempotency,
                "contexts": list(spec.contexts),
                "availability": spec.availability,
                "selector": spec.selector,
                "params": spec.params_schema if arguments.get("includeSchemas") else None,
            })
        if wanted and not families:
            raise ToolError(
                f"unknown command family {wanted!r}; available: "
                + ", ".join(sorted({_family(item) for item in registry.methods()}))
            )
        return {
            "families": {name: sorted(items, key=lambda item: item["method"]) for name, items in sorted(families.items())},
            "familyCount": len(families),
            "commandCount": sum(len(items) for items in families.values()),
        }

    server.register(Tool(
        name="bridge_commands",
        description=(
            "List the Studio command surface grouped into families, with each command's "
            "effect, idempotency and valid contexts. The manifest is the single source "
            "of truth; this reads it rather than restating it."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "family": {"type": "string", "minLength": 1},
                "includeSchemas": {"type": "boolean"},
            },
        },
        handler=bridge_commands,
    ))

    lease_schema: dict[str, Any] = {
        "type": "object",
        "additionalProperties": True,
        "required": ["leaseId", "fence", "runId", "agentId", "buildId", "session"],
        "properties": {
            "leaseId": {"type": "string", "minLength": 1},
            "fence": {"type": "integer", "minimum": 1},
            "runId": {"type": "string", "minLength": 1},
            "agentId": {"type": "string", "minLength": 1},
            "buildId": {"type": "string", "minLength": 1},
            "session": {"type": "string", "minLength": 1},
        },
    }

    def bridge_lease(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..hub.protocol import BridgeError

        operation = arguments["operation"]
        bridge = _bridge(arguments)
        try:
            if operation == "acquire":
                required = ("runId", "agentId", "buildId", "session")
                missing = [name for name in required if not arguments.get(name)]
                if missing:
                    raise ToolError("acquire requires " + ", ".join(missing))
                lease = bridge.acquire_lease(
                    run_id=arguments["runId"],
                    agent_id=arguments["agentId"],
                    build_id=arguments["buildId"],
                    session_id=arguments["session"],
                    ttl_seconds=float(arguments.get("ttlSeconds", 30)),
                )
            elif operation == "renew":
                if not isinstance(arguments.get("lease"), dict):
                    raise ToolError("renew requires the complete lease receipt")
                lease = bridge.renew_lease(
                    arguments["lease"],
                    ttl_seconds=float(arguments.get("ttlSeconds", 30)),
                )
            else:
                if not isinstance(arguments.get("lease"), dict):
                    raise ToolError("release requires the complete lease receipt")
                lease = bridge.release_lease(arguments["lease"])
        except ToolError:
            raise
        except BridgeError as exc:
            raise ToolError(f"{getattr(exc, 'code', 'E_BRIDGE')}: {exc}") from exc
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc
        return {"operation": operation, "lease": lease}

    server.register(Tool(
        name="bridge_lease",
        description=(
            "Acquire, renew, or release the exclusive fenced lease required by Studio "
            "commands whose manifest selector.build is required. Pass the returned "
            "receipt unchanged to bridge_call and renew it before it expires."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "required": ["operation"],
            "properties": {
                "operation": {"type": "string", "enum": ["acquire", "renew", "release"]},
                "runId": {"type": "string", "minLength": 1},
                "agentId": {"type": "string", "minLength": 1},
                "buildId": {"type": "string", "minLength": 1},
                "session": {"type": "string", "minLength": 1},
                "ttlSeconds": {"type": "number", "minimum": 1, "maximum": 300},
                "lease": lease_schema,
                "hub": {"type": "string", "minLength": 1},
            },
        },
        handler=bridge_lease,
    ))

    def bridge_call(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..hub.commands import CommandValidationError, load_default_registry
        from ..hub.protocol import BridgeError

        registry = load_default_registry(verify_dispatcher=False)
        method = arguments["method"]
        try:
            spec = registry.require(method)
        except Exception as exc:  # noqa: BLE001
            raise ToolError(str(exc)) from exc

        params = arguments.get("params") or {}
        try:
            spec.validate_params(params)
        except CommandValidationError as exc:
            raise ToolError(f"{method} parameters are invalid: {exc}") from exc

        if spec.availability != "supported":
            raise ToolError(
                f"{method} is declared {spec.availability} in the manifest and will not be dispatched"
            )

        allow_arbitrary = spec.effect == "arbitrary"
        if allow_arbitrary:
            from .capabilities import require_arbitrary_code

            require_arbitrary_code()

        bridge = _bridge(arguments, allow_arbitrary=allow_arbitrary)
        if arguments.get("pinToRunning"):
            try:
                bridge.pin_to_running()
            except Exception as exc:  # noqa: BLE001
                raise ToolError(f"could not pin to a running session: {exc}") from exc

        try:
            result = bridge.call(
                method,
                params,
                timeout=float(arguments.get("timeoutSeconds", 30)),
                lease=arguments.get("lease"),
            )
        except BridgeError as exc:
            # The bridge's own refusals -- lease conflicts, wrong context, a
            # disconnected session -- keep their code. Flattening them into a
            # generic failure is how a retryable problem gets treated as a
            # permanent one, and the reverse.
            raise ToolError(f"{getattr(exc, 'code', 'E_BRIDGE')}: {exc}") from exc
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        return {
            "method": method,
            "effect": spec.effect,
            "idempotency": spec.idempotency,
            # Surfaced with every result so an agent can see, without consulting
            # anything else, that this call must not be repeated.
            "retryable": spec.idempotency != "at-most-once",
            "result": result,
        }

    server.register(Tool(
        name="bridge_call",
        description=(
            "Invoke any Studio bridge command by name, validated against the command "
            "manifest before dispatch. Returns the result plus the command's effect and "
            "whether it is safe to retry. Use bridge_commands to discover the surface."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "required": ["method"],
            "properties": {
                "method": {"type": "string", "minLength": 1},
                "params": {"type": "object"},
                "hub": {"type": "string", "minLength": 1},
                "timeoutSeconds": {"type": "number", "exclusiveMinimum": 0, "maximum": 300},
                "pinToRunning": {
                    "type": "boolean",
                    "description": (
                        "Route to the session running the game. Without it, consecutive "
                        "reads can land on different DataModels and quietly mix two worlds."
                    ),
                },
                "lease": lease_schema,
            },
        },
        handler=bridge_call,
    ))

    return server
