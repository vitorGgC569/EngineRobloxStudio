# RQE Studio Bridge (plugin)

Makes a running Roblox Studio addressable: an agent sends typed commands, the
plugin executes them against the real DataModel and returns structured results.

## Install

```powershell
python rqe.py studio install .
```

Builds with Rojo into `%LOCALAPPDATA%\Roblox\Plugins\RQEStudioBridge.rbxmx`.
**Restart Studio once** — plugins are loaded only at startup (the Studio log
says `Hot reload attempted but not actually enabled`).

The plugin auto-connects to `http://127.0.0.1:8790` on load; an agentic platform
cannot depend on a human clicking a toolbar button. The `RQE > Bridge` toolbar
button toggles the connection manually.

## How it talks

Studio cannot accept inbound connections, so the plugin drives the loop:
handshake, then poll → execute → report. The hub holds each poll for up to 20s,
well under Roblox's 60s HTTP ceiling and about 3 requests/minute against a
~500/min budget. Plugins may use `HttpService` regardless of the place's
`HttpEnabled` setting, so no game configuration change is needed.

On a failed request the plugin backs off exponentially to 15s and re-handshakes.
When the Studio context changes (edit ⇄ run) it re-registers, so the hub always
knows whether an answer came from an edited place or a running game.

## Modules

| File | Role |
|---|---|
| `init.server.lua` | lifecycle, toolbar, poll loop, context re-registration |
| `Transport.lua` | HTTP long-poll, handshake, backoff |
| `Dispatcher.lua` | command registry; drives `bridge.capabilities` |
| `Resolve.lua` | path → Instance, including `ref:<id>` |
| `Refs.lua` | stable ids via `GetDebugId` (paths are **not** unique) |
| `Serialize.lua` | Roblox datatypes → JSON-safe values |
| `Errors.lua` | structured errors mirroring `rqe/hub/protocol.py` |
| `Commands/Bridge.lua` | ping, capabilities, studio info |
| `Commands/DataModel.lua` | tree, properties, find |
| `Commands/World.lua` | raycast, bounds, ground support, overlaps, summary |
| `Commands/Runtime.lua` | run state, players, log tail |
| `Commands/Session.lua` | run start/stop, guarded `bridge.exec` |
| `Commands/Camera.lua` | deterministic viewpoints |

## Adding a command

Add a handler to a `Commands/*` module and one entry in `Dispatcher.lua`.
`bridge.capabilities` reports the registry directly, so the advertised surface
cannot drift from the code. Reinstall and restart Studio.

## Security

`bridge.exec` runs Luau supplied by the hub. The trust boundary is the loopback
socket. It exists because Studio will not hot-reload plugins, so without it each
new capability costs a restart. Run the hub with `--token` if anything untrusted
can reach this machine's ports.
