# A. Current state, B. Capability matrix, C. Architectural gaps

Assessment date: 2026-08-10. Every claim below was checked by reading the
implementation or by running it, not by reading documentation.

## A. Current state

The repository contains a working **Roblox Quality Engine (RQE)**: a Python
audit engine, a Luau MVP game, a declarative game contract, an evidence model,
category scoring and a release gate. The concepts are the right ones. The
problem is where the facts come from.

### What exists

| Component | Path | What it really is |
|---|---|---|
| Audit orchestrator | `rqe/audit.py` | Assembles evidence, scores, decides the gate |
| Probe catalogue | `rqe/probes.py` | 30 probes across 9 categories |
| Static Luau scanner | `rqe/scanner.py` | Source scan for suspicious scripts and asset manifest issues |
| Headless runtime | `rqe/runtime.py` | A **Python re-implementation** of the purchase/persistence rules |
| Game Agent Bridge | `rqe/bridge/` | `game.start/observe/act/...` with blackbox/graybox/whitebox modes |
| Studio adapter | `rqe/bridge/adapters.py` | Maps bridge actions onto a transport that had **no server** |
| Scoring + gate | `rqe/scoring.py` | Weighted category scores, blocks on critical/major |
| Studio detector | `rqe/studio.py` | Checks the Studio process/exe and a screenshot manifest |
| Window capture | `tools/studio_runtime_capture.py` | Real Win32 focus + keystrokes + `ImageGrab` of the Studio window |
| Map renderer | `tools/render_map_audit.py` | **Synthetic 2D illustrations** drawn with PIL from JSON |
| MVP game | `roblox/mvp/` | Luau tycoon; the world is generated at runtime by `MapService` |
| In-game relay | `roblox/runtime/AgentBridge.server.lua` | A `BindableFunction`, callable **only from inside the same VM** |
| Studio plugin | `apps/studio-plugin/` | Was a README with no code |
| CLI, dashboard | `rqe/cli.py`, `apps/dashboard/` | `audit/verify/fix/improve/bridge`; static report viewer |

### The finding that defines the current state

Running the engine as shipped:

```text
releaseAllowed: True
scores: structural/security/visual/geometry/gameplay/navigation/ui/runtime/
        performance/persistence/multiplayer  ->  all 100.0
summary: 38 executed, 38 PASS, 0 WARN, 0 FAIL
```

A perfect score, and it means almost nothing. 29 of the 38 evidence records come
from `headless-runtime`, and the geometry, UI, navigation and performance probes
read `roblox/mvp/game-state.json` — a **hand-written fixture**:

```json
"performance": { "frameMs": 12.4, "workspaceInstances": 184 },
"ui":          { "visualScore": 0.92 },
"geometry":    { "floating": [], "overlaps": [], "buried": [] }
```

`frameMs: 12.4` was never sampled. `floating: []` is an assertion that nothing
floats, which no code ever checked against a place. The fixture is the answer
key, and the engine grades itself against it.

Three specific ways this misleads:

1. **The fixture is a parallel implementation.** `rqe/runtime.py` re-implements
   the purchase, persistence and isolation rules in Python. When it reports
   `persistencePass: true`, it proves the Python copy persists — not that
   `PersistenceService.lua` does. The two can drift without any test failing.
2. **`run_purchase_scenario` returns hardcoded measurements.**
   `"consoleErrors": 0, "instanceGrowth": 0` are literals in the return value,
   consumed by the `runtime_error` and `instance_growth` probes as if measured.
3. **`reports/visual-snapshots/*.png` are drawings, not renders.** They are PIL
   `ImageDraw` schematics generated from JSON. The bundled README is honest
   about this, but the `visual` category still scores 100 from them.

`reports/studio-runtime/*.png` are, by contrast, genuine screen grabs of a real
Studio window — `tools/studio_runtime_capture.py` does real `EnumWindows`,
`SetForegroundWindow`, `keybd_event` and `ImageGrab.grab`. But it is blind
automation: fixed `time.sleep()` values, no confirmation the place loaded, and
`liveStudioCapture` is computed from *"did a file named spawn-runtime.png get
written"*, not from any evidence the game was running.

### The break in the chain

The declared architecture was sound; it was severed at the most important joint.

```text
Python StudioGameAdapter
        │  calls playtest_start / screen_capture / quality_probe_observe
        ▼
HttpJsonRpcTransport  ──►  ✗ nothing listened on the other end
        ▼
   [Studio plugin]     ──►  ✗ apps/studio-plugin was a README
        ▼
AgentBridge.server.lua ──►  exposes a BindableFunction, which by definition
                            cannot be invoked from outside the Roblox VM
```

So no code path existed by which any Python process could learn a single fact
about a real Roblox place. That is the root cause of everything above: with no
channel to reality, a fixture is the only thing left to grade against.

### What the bridge revealed within seconds of existing

Once a real channel was built (see `K` below), the first two queries against the
audited place `.tmp/MinersRidgeTycoon-qa-v7.rbxlx` returned:

```text
studio.info    -> workspaceDescendants: 2
world.summary  -> parts: 1, classCounts: {Terrain: 1, Camera: 1}
```

The place that scored `geometry: 100.0` has an **empty Workspace** in edit mode.
Its world is generated at runtime by `MapService`, so there was never any
authored geometry for a geometry probe to check. No amount of fixture-reading
would ever have surfaced that.

## B. Capability matrix

Reliability is rated on what was verified, not what was intended.
`NOT_VALIDATED` means no execution evidence exists.

| Capability | Current support | Reliability | Limitations | Target | Priority |
|---|---|---|---|---|---|
| Launch Studio | `studio_runtime_capture.py` (Win32) | Works, brittle | Fixed sleeps, no load confirmation | Managed lifecycle with readiness probe | P0 |
| Open a specific place | Win32 Ctrl+O + clipboard paste | Brittle | Blind keystrokes into a modal dialog | CLI arg launch + verified place identity | P0 |
| Sync project (Rojo) | `rojo build/serve` by hand | Good | Not driven by the engine | Engine-owned build+sync step | P1 |
| **Start the game** | **`run.start` via `RunService:Run()`** | **Verified** | Run mode only; no player character | Play Solo with character | P0 done / P1 for Solo |
| Stop / restart a session | `run.stop` | Verified | — | + Play Solo teardown | done |
| Query the hierarchy | `dm.tree`, `dm.find` | Verified | Bounded by node/result caps | Streaming for huge places | done |
| Query properties/attributes/tags | `dm.properties` | Verified | No property reflection in Luau; guarded reads | Class-aware property schemas | done |
| Stable instance identity | `ref:` via `GetDebugId` | Verified | Session-scoped ids | Persistent identity across runs | P1 |
| Raycasts / ground support | `world.raycast`, `world.ground_support` | Verified (9 rays) | Axis-aligned sampling grid | Slope/edge-aware sampling | done |
| Bounding boxes / overlaps | `world.bounds`, `world.overlaps` | Verified (4 plots) | AABB only, not oriented boxes | OBB + mesh-accurate | P1 |
| Runtime metrics | `run.state` | Verified (60.22 FPS, 1586 MB) | Heartbeat-sampled FPS | Per-script/physics/network breakdown | done / P2 |
| Console errors + warnings | `log.tail` | Verified (0 errors) | Whole-session history, no run scoping | Per-run log windows + streaming | done / P1 |
| Player + character state | `run.players` | Implemented, not exercised | Needs a real player; Run mode has none | Exercise under Play Solo | P1 |
| Camera control | `camera.set`, `camera.focus` | Implemented, not exercised | Not yet paired with capture | Deterministic QA viewpoints | P1 |
| **Screenshots** | Win32 window grab only | NOT_VALIDATED as evidence | Whole window, no camera metadata | Camera-correlated, metadata-stamped captures | P2 |
| Semantic visual QA | None | NOT_VALIDATED | — | VLM review of captured frames | P2 |
| Agent plays the game | Headless fixture only | NOT_VALIDATED | Fixture returns hardcoded `elapsed 3.27`, `distance 4.84` | Instrumented in-game actor API | P1 |
| Scenario DSL | `contracts/scenarios/*.json` + `run_scenario` | Works against the fixture | Never touched a real game | Same DSL, real backend | P1 |
| Multiplayer | Two logical players in one Python dict | NOT_VALIDATED | No replication, no network | Real multi-client sessions | P2 |
| Persistence | Python dict save/load | NOT_VALIDATED | Real DataStores never exercised | Sandboxed test DataStores | P2 |
| Asset safety | `rqe/scanner.py` source scan | Works, static only | Cannot see inserted models | Pre-insertion model quarantine | P2 |
| Run artifacts | `artifacts/run-NNNNN/` | Verified | Screenshots dir still empty | Full evidence bundles | done / P2 |
| Reproducibility metadata | `run.json` | Verified | No seed capture yet | Seeded, replayable runs | P1 |
| Multi-agent orchestration | None | NOT_VALIDATED | — | Task graph + file ownership | P4 |

## C. Architectural gaps

Ordered by how much they block the industrial vision.

**G1 — Truth came from a fixture, not the engine.** *(closed for the measured
subset; see K)* Probes read `game-state.json`. Until every quality claim traces
to a measurement, the score is a self-portrait. The fixture-backed probes still
exist and still report 100.

**G2 — The Python runtime is a second implementation of the game.** Gameplay,
economy and persistence rules live twice: in Luau and in `rqe/runtime.py`. Only
the Luau version ships. Any assertion about game rules must eventually execute
Luau, not its Python twin.

**G3 — No player actor.** `run.start` brings the world to life but Run mode has
no character. Walking, touching, prompting and buying — the entire §5 surface —
still have no real implementation. This is the largest remaining gap.

**G4 — Screenshots are not evidence yet.** Captures exist but are window grabs
with no camera pose, no run id and no scenario step. `camera.focus` now makes
viewpoints deterministic; nothing yet pairs a capture with its metadata.

**G5 — Multiplayer and persistence are unproven.** Both are asserted by a Python
dictionary. Roblox replication, ownership races and DataStore behaviour have
never been exercised.

**G6 — The plugin needs a Studio restart to change.** Studio logs
`Hot reload attempted but not actually enabled`. Every new typed command costs a
restart, which is why `bridge.exec` exists as an escape hatch.

**G7 — Environments are undifferentiated.** No separation between development,
test, staging and production for DataStores, monetization or analytics (§21).

**G8 — Scoring rewards silence.** A category with no evidence scores 100. Absent
proof and passing proof are indistinguishable, which is precisely how the engine
reached a perfect score while measuring nothing. Gates should require positive
runtime evidence, not merely an absence of failures.

**G9 — No multi-agent substrate.** No task graph, file ownership, locking or
merge control (§14).
