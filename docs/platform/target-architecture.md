# D. Target architecture, E. Agent tool API, F. Roblox bridge

## D. Target architecture

The organising principle: **an agent may only assert what the platform measured,
and every measurement is stamped with where it came from.** Layers exist to keep
that stamp intact from the engine to the report.

```text
                    Product director (human)
                              │  game specification
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ Orchestrator          run registry, task graph, gates        │
│                       artifacts/run-NNNNN/                   │
└─────────────────────────────────────────────────────────────┘
        │                     │                      │
        ▼                     ▼                      ▼
┌───────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ Domain agents │   │ Validators       │   │ Evaluation       │
│ World, Game-  │   │ world, plot, UI, │   │ category scores, │
│ play, UI,     │   │ gameplay, perf,  │   │ release gate,    │
│ Economy, Data │   │ security         │   │ regression diff  │
└───────────────┘   └──────────────────┘   └──────────────────┘
        │                     │                      ▲
        └──────────┬──────────┘                      │
                   ▼                                 │
┌─────────────────────────────────────────────────────────────┐
│ Tool layer          source edits · rojo build · bridge calls │
└─────────────────────────────────────────────────────────────┘
                   │                                 │
                   ▼                                 │
┌─────────────────────────────────────────────────────────────┐
│ Bridge Hub (loopback)   typed commands, correlation ids,     │
│                         timeouts, session routing, events    │
└─────────────────────────────────────────────────────────────┘
                   ▲ long-poll
                   │
┌─────────────────────────────────────────────────────────────┐
│ RQE Studio Bridge plugin (Luau, in Studio)                   │
│   dispatcher · refs · serializer · command modules           │
└─────────────────────────────────────────────────────────────┘
                   │ direct DataModel access
                   ▼
        Roblox Studio  ──  edit mode  ⇄  run mode  ⇄  Play Solo
                   │
                   ▼
        Measurements ──► Evidence ──► Findings ──► Repair
```

### Responsibilities

| Layer | Owns | Must never |
|---|---|---|
| Orchestrator | Run ids, task order, gates, artifacts | Touch the DataModel directly |
| Domain agents | Source changes in their own file ownership | Write outside their owned paths |
| Tool layer | Build, sync, bridge calls | Invent a result when a call fails |
| Bridge Hub | Routing, correlation, liveness, timeouts | Interpret game semantics |
| Plugin | Executing typed commands in Studio | Hold policy or thresholds |
| Validators | Turning measurements into evidence | Read fixtures as if measured |
| Evaluation | Scores, gates, regression comparison | Score a category with no evidence as 100 |

### The validation ladder

Every claim carries one of these, and the platform enforces the distinction
mechanically rather than by convention:

| Level | Source | Example |
|---|---|---|
| `NOT_VALIDATED` | nothing ran | a capability that only has a design doc |
| `STATICALLY_VALIDATED` | source, or a live place in **edit** mode | `world.summary` on an unopened place |
| `RUNTIME_VALIDATED` | a **running** place | 60.22 FPS sampled during `run` |
| `VISUALLY_VALIDATED` | a captured frame from a known camera pose | plot framing review |
| `E2E_VALIDATED` | a player-equivalent actor completed a scenario | buy → place → income → rejoin |

`rqe/observe.py` already downgrades an edit-mode pass to
`STATICALLY_VALIDATED` even though it came from a live engine, because the game
was not running.

## E. Agent tool API

Two tiers. Tier 1 is what the bridge exposes today (all verified against a live
Studio). Tier 2 is designed and specified but not yet implemented — it is
labelled as such so no agent assumes it exists.

### Tier 1 — implemented and verified

```text
bridge.ping(echo?)                    → liveness proof through the whole chain
bridge.capabilities()                 → live method list, protocol, context
studio.info()                         → studio version, place, mode, service census

dm.tree(path, depth, maxNodes, …)     → bounded hierarchy slice
dm.properties(path, properties?)      → properties + attributes + tags
dm.find(className?|tag?|name?|         → query, with topLevelOnly to drop nested
        namePattern?, root, limit,       matches, each result carrying a stable ref
        topLevelOnly?)

world.raycast(origin, direction,      → real engine raycast
              ignore?)
world.bounds(path)                    → measured world-space AABB
world.ground_support(path, samples,   → grid of downward rays; per-point gap
                     maxGap)
world.overlaps(paths[], tolerance)    → pairwise intersection, ancestor pairs
                                         excluded, with separation axis+distance
world.summary()                       → instance census, unanchored, below-floor

run.start(settleSeconds)              → RunService:Run(); world comes alive
run.stop()                            → back to edit
run.state(sampleSeconds)              → FPS, memory, instances, players, log counts
run.players()                         → per-player character, leaderstats, attributes
log.tail(limit, severity?, pattern?)  → structured Output window

camera.set(position, lookAt?, fov?)   → exact viewpoint
camera.focus(path, pitch, yaw,        → frame any instance from its bounding sphere
             margin)
camera.get()                          → current pose, for screenshot metadata

bridge.exec(source, chunkName?)       → guarded Luau escape hatch (see F)
```

Addressing rule: anything taking a `path` also accepts `ref:<id>`. Paths from
`GetFullName()` are **not unique** — four sibling parts named `PlotBorder` share
one path — so refs are the correct identifier whenever a set of objects is being
reasoned about.

### Tier 2 — specified, not implemented

```text
actor.spawn(profile)                  → an instrumented player-equivalent actor
actor.walk_to(target, timeout)        → humanoid movement with a real path
actor.jump() / actor.look(dx, dy)
actor.interact(promptRef)             → fire a ProximityPrompt as that actor
actor.click_gui(guiRef)
actor.activate_tool(toolRef)
actor.state()                         → position, health, inventory, cash

gui.tree(player)                      → rendered GUI with AbsolutePosition/Size
gui.hit_test(player, point)           → which element receives this click

capture.screenshot(camera, size)      → frame + camera pose + run/step metadata
capture.viewpoints(spec)              → a named, reproducible viewpoint set

data.get(scope, key) / data.set(...)  → sandboxed test DataStore access
net.remotes() / net.activity(window)  → RemoteEvent inventory and traffic

session.play_solo(players)            → real Play Solo with characters
session.multi_client(n)               → n clients against one server
```

The Tier 2 boundary is deliberate: `actor.*` is the single largest missing
capability (gap G3), and specifying it without building it is honest, whereas
shipping a fixture behind those names is exactly the failure this platform
exists to eliminate.

## F. Roblox bridge

### Why long-polling

Roblox offers no inbound socket and no WebSocket client. A plugin can only make
outbound HTTP requests. So the plugin drives the loop and the hub holds requests
open. This is the same mechanism Rojo uses, which is the proof it is viable.

Crucially, **plugins may use `HttpService` regardless of the place's
`HttpEnabled` setting**, so no game configuration change is required.

```text
agent ──POST /rpc──►  Bridge Hub  ◄──POST /bridge/poll── plugin   (held ≤20s)
                          │                                 │
                          └── correlated Response ◄─POST /bridge/result
```

### Endpoints

| Endpoint | Caller | Purpose |
|---|---|---|
| `GET /health` | anyone | liveness, protocol version |
| `POST /bridge/hello` | plugin | handshake: protocol, clientId, place, context |
| `POST /bridge/poll` | plugin | long-poll for a command batch |
| `POST /bridge/result` | plugin | return correlated responses |
| `POST /bridge/event` | plugin | push events (logs, heartbeats) |
| `POST /rpc` | agent | JSON-RPC 2.0; blocks on the correlated answer |

### Protocol `rqe.bridge/1`

Command and response envelopes carry what is needed to keep evidence honest:

```jsonc
// command
{ "protocol": "rqe.bridge/1", "id": "cmd_…", "method": "world.bounds",
  "params": { "path": "ref:0_452597" }, "deadlineMs": 15000, "issuedAt": "…" }

// response
{ "id": "cmd_…", "ok": true, "result": { … }, "elapsedMs": 4.1,
  "context": "run", "place": "MinersRidgeTycoon-qa-v7.rbxlx" }
```

`context` is stamped **per response, not per session**, because a playtest can
start between two commands and the agent must see that in the answer itself.

Error codes are shared by both sides (`rqe/hub/protocol.py::ErrorCode` and
`Errors.lua`): `E_UNKNOWN_METHOD`, `E_BAD_PARAMS`, `E_NOT_FOUND`, `E_TIMEOUT`,
`E_EXEC`, `E_DISCONNECTED`, `E_PROTOCOL`, `E_UNAUTHORIZED`,
`E_UNSUPPORTED_CONTEXT`.

### Session routing rules

Learned the hard way — both rules exist because their absence produced real
failures during bring-up:

1. **Supersede by `clientId`.** A Studio switching edit ⇄ run re-registers. The
   prior session is retired immediately rather than left to go stale.
2. **Liveness outranks context.** A Studio killed during a playtest leaves a
   `run` session behind. Ranking `run` above `edit` on context alone routed every
   command to that corpse while a healthy plugin sat idle. Sessions not seen
   within one poll-hold window are no longer candidates.
   Regression test: `tests/test_hub.py::test_a_live_edit_session_beats_a_dead_run_session`.

### Timeouts, retries, resilience

- Commands carry a deadline; expiring in the queue yields `E_TIMEOUT`.
- A late answer to a timed-out command is **dropped**, never handed to the next
  caller (`test_slow_command_times_out_and_is_not_delivered_late`).
- The plugin reconnects with exponential backoff, capped at 15s, and rehandshakes
  automatically — verified by restarting the hub under a live plugin.
- Poll hold is 20s, comfortably under Roblox's 60s HTTP ceiling, and costs about
  3 requests/minute against a ~500/min budget.

### On the official Studio MCP

This machine has Roblox's own `StudioMCP.exe`, but its Studio-side plugin was not
installed (no `%LOCALAPPDATA%\Roblox\Plugins` folder existed). It is a general
MCP surface aimed at chat clients — insert model, run code — not a programmable,
typed, correlated measurement API that Python validators can call and that
stamps every answer with its Studio context. The two can coexist; the bridge here
is the one the quality engine depends on.

### Security posture

`bridge.exec` executes hub-supplied Luau. That is a genuine arbitrary-code
channel, and the trust boundary is the loopback socket. It exists because Studio
will not hot-reload plugins (gap G6), so without it every new capability costs a
Studio restart. This matches the ecosystem norm — Rojo can write arbitrary
scripts into a place, and the official Studio MCP exposes a run-code tool. Run
the hub with `--token` if anything untrusted can reach this machine's ports.
