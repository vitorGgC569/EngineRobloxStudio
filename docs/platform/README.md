# RQE Platform architecture

Turning this repository from a quality engine that grades a fixture into an
agentic platform that measures a real Roblox game.

| Document | Covers |
|---|---|
| [ENGINE-CHARTER.md](ENGINE-CHARTER.md) | normative engine/game boundary and industrial stopping criteria |
| [current-state.md](current-state.md) | **A** current state · **B** capability matrix · **C** gaps |
| [target-architecture.md](target-architecture.md) | **D** architecture · **E** agent tool API · **F** Roblox bridge |
| [validation.md](validation.md) | **G** validation architecture · **I** artifact model |
| [multi-agent.md](multi-agent.md) | **H** parallelism and conflict control |
| [roadmap.md](roadmap.md) | **J** P0–P5 |
| [OPENAI-VISUAL-REVIEW.md](OPENAI-VISUAL-REVIEW.md) | optional fail-closed OpenAI Responses vision provider and CLI |
| this file, below | **K** first implementation slice |

---

# K. First implementation slice

## Why this slice

The repository had a defensible architecture severed at one joint: nothing could
learn a single fact about a real Roblox place. `StudioGameAdapter` called a
transport with no server behind it, `apps/studio-plugin/` was a README, and
`AgentBridge.server.lua` exposed a `BindableFunction` — which by definition
cannot be invoked from outside the Roblox VM.

Everything downstream inherited that break. Geometry probes read a hand-written
JSON fixture. `frameMs: 12.4` was a literal. The engine reported
**38/38 PASS, all categories 100.0, release allowed** for a place whose geometry
had never been measured.

So the highest-multiplier slice is not a validator, a scenario or a screenshot.
It is the channel: **agent → hub → plugin → live Studio → structured answer**.
Every other capability in the roadmap is downstream of it.

## What was built

```text
rqe/hub/protocol.py      versioned envelopes, correlation ids, error taxonomy
rqe/hub/server.py        hub: handshake, long-poll, correlation, session routing
rqe/hub/client.py        StudioBridge (agents) + PluginSimulator (transport tests)
rqe/hub/install.py       build + install the plugin into Studio
rqe/observe.py           measurement pass → evidence → findings → artifacts
rqe/cli.py               rqe studio serve|status|call|install|measure

apps/studio-plugin/src/  the Studio plugin (Luau)
  init.server.lua          lifecycle, reconnect, context re-registration
  Transport.lua            HTTP long-poll
  Dispatcher.lua           command registry
  Resolve.lua / Refs.lua   path and stable-ref addressing
  Serialize.lua            Roblox datatypes → JSON
  Errors.lua               structured errors shared with Python
  Commands/                Bridge, DataModel, World, Runtime, Session, Camera

tests/test_hub.py        13 transport tests on real sockets
```

## Verification — what was actually executed

Studio **0.733.0.7330989**, place `.tmp/MinersRidgeTycoon-qa-v7.rbxlx`,
hub on `127.0.0.1:8790`, plugin installed to `%LOCALAPPDATA%\Roblox\Plugins`.

**Handshake.** A real Studio connected and answered:

```text
session sess_f24f9b8f7ac8 | edit | MinersRidgeTycoon-qa-v7.rbxlx
bridge.ping -> {"pong": true, "echo": "post-fix", "context": "edit"}
```

**Capability discovery.** 20 commands live in the running Studio, reported by the
plugin itself rather than by a hand-maintained list.

**Simulation control, without touching the keyboard.** `RunService:Run()` from
the plugin:

```text
run.start -> started: true, context: run, workspaceDescendants: 372
```

**The first finding, within seconds of the bridge existing.** In edit mode the
audited place has an empty world:

```text
studio.info   -> workspaceDescendants: 2
world.summary -> parts: 1, classCounts: {Terrain: 1, Camera: 1}
```

The world is generated at runtime by `MapService`. The place that scored
`geometry: 100.0` had no authored geometry at all. No fixture read would ever
have surfaced that.

**The full pipeline, unattended.** Two commands, no human in the loop, no
keyboard automation:

```bash
python rqe.py studio restart .tmp/MinersRidgeTycoon-qa-v7.rbxlx .
python rqe.py studio measure . --start-run
```

`artifacts/run-00009/`:

```text
RUN run-00009  [RUNTIME_VALIDATED]  contexts observed: [edit, run]
11 PASS  0 WARN  0 FAIL   commandErrors: 0

PASS studio_bridge_connected  live Studio answered through the bridge
PASS clean_baseline           run started from a clean baseline of 2 descendants;
                              game scripts generated 370
PASS instance_budget          Workspace holds 372 instances (budget 25000)
PASS parts_below_floor        0 part(s) below y=-50
PASS unanchored_parts         0 unanchored part(s) (budget 200)
PASS spawn_exists             1 SpawnLocation(s) found in Workspace
PASS ground_support           Workspace.Map.SpawnPad rests on a surface
                              (9 raycasts, coverage 1)
PASS frame_rate               sampled 60.01 FPS over 0.6s in run context
PASS memory_budget            1556.9 MB in use (budget 4000.0 MB)
PASS spatial_overlap          4 exclusive regions, none intersecting
PASS runtime_error            0 error line(s) in the Studio output
```

**Reproducible, not lucky.** Three consecutive identical cycles, each a full
Studio restart followed by a full measurement:

```text
run           wsDesc  parts     fps    memMB  regions overlaps
run-00011        372    262   60.07   1547.7        4        0
run-00012        372    262   60.21   1579.4        4        0
run-00013        372    262   59.94   1535.1        4        0
```

Geometry is identical run to run; FPS and memory vary only as genuine
measurements of a live process do. That stability is what makes a regression
diff meaningful.

An earlier attempt at this was **not** reproducible — one cycle passed and the
next lost `world.summary` to a timeout — which is what exposed the zombie-session
defect below.

Measured plot extents — four regions, genuinely disjoint:

```text
Workspace.Map.PlotA  min [-44, -0.46, -100]   max [-6, 8.8, -63.5]
Workspace.Map.PlotB  min [  6, -0.46, -100]   max [44, 8.8, -63.5]
Workspace.Map.PlotC  min [-44, -0.46, -142]   max [-6, 8.8, -105.5]
Workspace.Map.PlotD  min [  6, -0.46, -142]   max [44, 8.8, -105.5]
```

These are the first `RUNTIME_VALIDATED` numbers this repository has ever
produced. `60.22` was sampled from `Heartbeat`; `12.4` was typed into a file.

## Dogfooding: two bugs the slice found in itself

Per §28, each defect became a capability rather than a local patch.

**Containers overlap their own contents.** The first run reported 48 intersecting
region pairs. Every one was `PlotA` versus its own `PlotBorder`. The general
rule — an ancestor/descendant pair is never an exclusivity violation — now lives
in the `world.overlaps` primitive, plus `topLevelOnly` on `dm.find` to stop
discovery returning nested matches. Result: `run-00002` 48 findings →
`run-00003` 0 findings, by fixing the validator, not the game.

**Paths are not unique identifiers.** Four sibling parts named `PlotBorder` all
return the same `GetFullName()`, so a path-addressed command silently acted on
whichever one `FindFirstChild` happened to return. Every reported instance now
carries a stable `ref` from `GetDebugId`, and any command taking a path accepts
`ref:<id>`.

**Run mode does not undo what game scripts build.** Measured directly: after
`run.stop`, the edit-mode Workspace kept all 372 generated descendants instead of
returning to 2, and running a second time layered a second world on top —
**372 → 742 descendants**. Every count, overlap and budget measured after the
first cycle would have been contaminated, and the platform would have reported
confident wrong numbers. `run.start` now reports its baseline and accepts
`requireBaselineBelow`; `studio measure --start-run` refuses to measure a dirty
place and downgrades the pass to `STATICALLY_VALIDATED` rather than guessing.
The place file on disk was never modified.

**Four bugs found in the hub itself**, each now carrying a regression test named
after the failure that produced it:

- *Dead sessions won the routing.* A Studio killed mid-playtest left a `run`
  session behind; ranking `run` above `edit` on context alone routed every
  command to that corpse. Liveness now outranks context.
- *Dead sessions never aged.* `last_seen` was refreshed every time the poll's
  condition variable woke, so any other session's traffic rejuvenated a Studio
  that no longer existed — it stayed "fresh" forever. The stamp now records when
  the plugin actually contacted the hub, routing prefers a session with a poll
  currently held open, and a socket that dies while its poll is answered retires
  the session immediately.
- *Queued work was discarded on a context switch.* `run.start` flips edit→run,
  the plugin re-registers, and an already-queued command was failed with
  `E_DISCONNECTED` even though the same Studio was still there. Queued work is
  now transferred to the new session; in-flight work is not, because the plugin
  may already have executed it.
- *A killed Studio still reported an open poll.* Its poll handler stays blocked
  until it tries to write, so the corpse looked like the liveliest session
  available and absorbed the next command. The hub cannot detect this alone — but
  the caller that killed the process knows, so `rqe studio restart` now retires
  those sessions explicitly via `hub.drop_sessions`. This is what turned a
  one-in-two success rate into three clean cycles in a row.

**Studio's auto-recovery dialog blocked unattended restarts.** After an unclean
exit Studio raises a modal that no automated cycle can answer.
`rqe studio restart` now owns the sequence: stop, **archive** the recovery files
(never delete — they can hold unsaved work), clear the stale `.lock`, launch with
the place as an argument, and wait for a *new* session to start polling.

## P1: the agent plays the game

The gap that mattered most is closed. An agent now drives a real player through
a real game with no human input.

**Getting a body.** `Players:CreateLocalPlayer` is blocked (`lacking capability
LocalUser`), and `Instance.new("Player")` is blocked (`lacking capability
WritePlayer`), so a Player cannot be conjured. Two paths exist and both are
implemented:

| Path | Player object | Foreground required | Good for |
|---|---|---|---|
| `run.start` + `actor.spawn` | no | no | physics, navigation, geometry, budgets |
| native `StudioTestService` Play + `actor.attach` | **yes** | **no** | the full gameplay loop |
| legacy F5 Play fallback | **yes** | yes | compatibility only; explicit opt-in |

`actor.spawn` builds an R15 rig from a `HumanoidDescription` and drops it into
the world: measured falling from y=6.5 to y=4.37 and settling on Slate, then
walking 13.5 studs under `Humanoid:MoveTo`. Real physics, no Player.

`actor.attach` binds every actor command to a Play Solo player's own character —
the body the game assigned `PlotA` and `Currency: 1000` to.

Historically Play Solo was started with a foreground F5 because
`PostMessage` was measured doing nothing to a minimised Studio window. That
path is now compatibility-only. Current automation starts/stops Play and
multiplayer tests through the plugin-only `StudioTestService` surface; the
normal background path fails closed instead of silently falling back to
foreground keystrokes.

**Reaching the client.** Prompt activation and GUI clicks are client-only, and a
plugin only ever lives in the edit and server DataModels — measured:
`InputHoldBegin()` from the server is accepted and `Triggered` never fires. A
LocalScript cannot call the hub either, because `HttpService` is server-only. So
`bridge.install_client` writes a LocalScript into the place and the plugin
reaches it with `RemoteFunction:InvokeClient`. The hub keeps one endpoint; the
client half is reached through the server half.

**The reference scenario, executed.** `contracts/scenarios/first-purchase-e2e.json`,
run by `rqe studio scenario`:

```text
SCENARIO first-purchase-e2e  [E2E_VALIDATED]  PASS
  PASS 1. attach                    real player, PlotA assigned
  PASS 2. assert                    PlotName != nil, Currency >= 100
  PASS 3. navigate_to               41 studs on real legs, 13 waypoints
  PASS 4. expect_prompt_in_range    5.5 studs, inside the 12-stud activation
  PASS 5. interact                  Triggered fired for Agoravai18
  PASS 6. wait
  PASS 7. assert                    delta Currency == -100, CardCount == +1
  PASS 8. interact                  second activation
  PASS 9. wait
  PASS 10. assert                   delta unchanged: no duplicate reward
```

Measured state change: `Currency 1000 -> 900`, `CardCount 1 -> 2`,
`CardCollection field_lantern -> field_lantern,tunnel_mole`, zero console errors.
The game's own `StoreService.lua` processed that purchase — not a Python
re-implementation of it.

**Scenario isolation.** The first attempt at a repeat run failed, correctly:
gameplay state survives, so the second pass began already owning the pack and
the purchase assertion failed for the wrong reason. Scenarios now open with a
`reset` step.

Historical isolation used a **full Studio restart** because the old
Shift+F5/F5 lifecycle could leave bridge sessions in the wrong context after a
second cycle. The current lifecycle uses `StudioTestService` test identities
and waits for context transitions explicitly. Routine playtest/gametest flows
reuse a compatible persistent edit session through `ensure_studio_session()`;
cold restart is now an explicit recovery/bootstrap operation rather than the
normal reset path.

That diagnosis came from a screenshot. Logs showed two `edit` sessions and
nothing else; one frame of the Studio window showed the game running with
`AVAILABLE FUNDS $900` and the character at the counter. Visual evidence earned
its place the first time it was needed.

## Honest status

| Claim | Level |
|---|---|
| Agent can command a live Studio and get structured answers | `RUNTIME_VALIDATED` |
| Simulation start/stop from an agent, no keyboard | `RUNTIME_VALIDATED` |
| Unattended Studio restart, auto-recovery dialog bypassed | `RUNTIME_VALIDATED` |
| Measurement refuses a contaminated place | `RUNTIME_VALIDATED` (run-00005) |
| World geometry, spawn support, region exclusivity measured | `RUNTIME_VALIDATED` |
| FPS, memory, instance counts, console errors measured | `RUNTIME_VALIDATED` |
| Transport correctness (correlation, timeout, liveness, reconnect) | `RUNTIME_VALIDATED` (16 tests) |
| Full cycle reproducibility | `RUNTIME_VALIDATED` (3 consecutive clean cycles) |
| `camera.focus` | `RUNTIME_VALIDATED` (framed `Workspace.Map`, 171×27×170 studs) |
| `camera.set` | implemented, **not exercised** |
| `run.players` | `RUNTIME_VALIDATED` (real player, plot and currency read) |
| **Agent plays the game** (walk, interact, buy) | **`E2E_VALIDATED`** (10/10 steps) |
| Objective reachability by navmesh | `RUNTIME_VALIDATED` (`world.path`, with a control probe) |
| GUI tree / GUI click | implemented, **not exercised** |
| Screenshots as evidence | `STATICALLY_VALIDATED` native `StudioCaptureService` pipeline; live background revalidation required after plugin 2.1 reload. Legacy window grabs are opt-in fallback only. |
| Multiplayer, persistence | `NOT_VALIDATED` — Python fixture only |
| The legacy 38-probe audit's 100.0 scores | fixture-backed; unchanged by this slice |

The legacy audit still reports what it always reported. This slice did not
rewrite it, and its scores should not be trusted until its probes are repointed
at measurements or relabelled `STATICALLY_VALIDATED`.

## Using it

```bash
python rqe.py studio install .
```

```bash
python rqe.py studio serve
```

Then, in another terminal, restart Studio unattended — it loads plugins only at
startup (`Hot reload attempted but not actually enabled` in the Studio log):

```bash
python rqe.py studio restart .tmp/MinersRidgeTycoon-qa-v7.rbxlx .
```

```bash
python rqe.py studio status --wait 60
```

```bash
python rqe.py studio call world.ground_support --params '{"path":"game.Workspace.Map.SpawnPad","samples":9}'
```

```bash
python rqe.py studio measure . --start-run
```

Play the game, end to end, with evidence per step:

```bash
python rqe.py studio scenario contracts/scenarios/first-purchase-e2e.json .
```

Measure a place that a previous run already generated a world into and the pass
is refused, not fudged:

```text
RUN run-00005  [STATICALLY_VALIDATED]   10 PASS  0 WARN  1 FAIL
[critical] studio: the place was not in a clean state, so the run was refused
```
