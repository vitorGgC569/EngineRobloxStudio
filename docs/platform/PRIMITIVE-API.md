# The primitive API — 12 families

The bridge must offer **primitives, not game features**. A command that knows
what a plot or a conveyor is has put a game inside the platform, and the next
game inherits it as debt.

This is the target surface and an honest measurement against it. Nothing below
is aspirational marking: a family counts as present only when a typed command
exists in `schemas/bridge-commands.v1.json` and is registered in the plugin
dispatcher, or when an MCP tool exposes it with a declared schema.

Current: **81 bridge commands**, **45 MCP tools**.

Legend: ✅ present · 🟡 exists in Python but is not a bridge primitive · ❌ absent

---

## 1. Studio — 10 / 10 ✅

| Command | State |
|---|---|
| `studio.status` | ✅ `studio.info` (bridge) and `studio_status` (MCP, works with no plugin attached) |
| `studio.play` / `studio.stop` | ✅ as `run.start` / `run.stop` |
| `studio.close` | ✅ `studio_stop` — DESTRUCTIVE, and refuses to run without `confirmDiscardUnsavedWork` |
| `studio.build` / `studio.sync` | ✅ `studio_build` — Rojo, then a Luau compile pass, because Rojo packages sources without parsing them |
| `studio.open` `restart` | ✅ `studio_open` and `studio_restart` — both refuse without explicit confirmation, because they discard unsaved work |
| `studio.server.start` / `studio.client.start` | ✅ `run.server` and `run.client` name the distinction `RunService:Run()` leaves implicit: a bare server has no character, no PlayerGui and no client at all |

Lifecycle is the one family an agent needs *before* a bridge exists, so it sits
on the MCP surface directly rather than behind the plugin.

## 2. DataModel — 11 / 11 ✅

| Command | State |
|---|---|
| `instance.find` `tree` `get` | ✅ as `dm.find` / `dm.tree` / `dm.properties` |
| `instance.create` `update` `delete` `clone` | ✅ |
| `instance.children` `descendants` `tags` `attributes` | ✅ |

**Complete.** This was the largest hole in the platform and it is now closed:
before, the only way to *write* the DataModel was `bridge.exec` — arbitrary
Luau, which has no schema, so nothing could validate it before it ran or
describe what it changed after.

Every mutation is declared `at-most-once`. Creating an instance twice is not the
same as creating it once, and no retry layer may decide otherwise. Batches are
capped at 256 and destroying a subtree above that is refused rather than
performed.

## 3. World — 9 / 9 ✅

| Command | State |
|---|---|
| `world.raycast` `bounds` `overlaps` | ✅ |
| `world.pathfind` | ✅ as `world.path`, with navmesh control probe and approach points |
| `world.snapshot` | ✅ as `world.summary` + `quality.snapshot` |
| `world.region` | ✅ `GetPartBoundsInBox` rather than a descendant scan, which on a real place is the difference between a millisecond and a stall |
| `world.navigation` | ✅ probes the navmesh with a control path across open ground, separating "the destination is unreachable" from "pathfinding is not working here at all" |
| `world.spawn_points` | ✅ reports ambiguous arrival, which is how a scenario becomes flaky in a way nobody can reproduce |
| `world.terrain` | ✅ read and write voxels via `WriteVoxels`, capped at 400,000 voxels, reporting the grid snap |

## 4. Runtime — 9 / 9 ✅

| Command | State |
|---|---|
| `runtime.state` | ✅ as `run.state` |
| `runtime.logs` | ✅ as `log.tail` + `client.logs` |
| `runtime.errors` / `warnings` | ✅ split by severity, because a gate asks a different question of each: errors block, warnings report |
| `runtime.metrics` | ✅ samples a real window and reports p50/p95/p99, not an instantaneous counter — the tail is what a player feels |
| `runtime.memory` | ✅ total plus per-category; an absent Stats item lands in `unavailable` rather than reporting zero |
| `runtime.physics` | ✅ step timing plus the awake-part count, which separates "one expensive constraint" from "4,000 parts that never sleep" |
| `runtime.network` | ✅ replication in and out, remote and bindable inventory |
| `runtime.events` | ✅ the connectable surface; a plugin cannot subscribe to a game's own signals, and this says so |

Was the weakest family relative to its value. A performance budget now has a
producer for every number in it.

## 5. Player — 10 / 10 ✅

| Command | State |
|---|---|
| `player.spawn` `walk_to` `jump` `interact` `state` | ✅ as `actor.*` |
| `player.move` | ✅ as `actor.walk_to` / `actor.navigate_to` |
| `player.teleport` | ✅ zeroes momentum, so a teleported actor does not slide off the destination |
| `player.equip` | ✅ searches character and backpack, and names what it could reach when it fails |
| `player.activate` | ✅ fires `Tool.Activated`; declared `at-most-once` because twice is two uses |
| `player.inventory` | ✅ held and stowed, and distinguishes "carrying nothing" from "cannot carry anything" |

Naming should still move from `actor.*` to `player.*` — an *actor* is our
synthetic rig and the family is really "drive a player" — but renaming is a
breaking change that deserves its own decision rather than arriving as a side
effect.

## 6. UI — 7 / 8 + federation

| Command | State |
|---|---|
| `ui.tree` | ✅ as `client.gui_tree`, with effective visibility resolved |
| `ui.state` | ✅ via `client.player_state` + `client.gui_snapshot` |
| `ui.text` / `ui.input` | ✅ `client.gui_text` reads and writes; the write sets `Text` and releases focus, and says so — no keystroke is synthesised |
| `ui.scroll` | ✅ `client.gui_scroll`, reporting the clamp so a caller cannot believe it reached somewhere it could not |
| `ui.viewport` | ✅ size, aspect, GUI inset and input capabilities; device class derived from the viewport rather than a platform enum |
| `ui.snapshot` | ✅ every visible element with a measured rectangle, plus the off-screen count |
| `ui.click` | ⚠️ declared **unsupported**: `VirtualInputManager` is refused both in a LocalScript and in a plugin (`lacking capability RobloxScript`). `bridge_call` refuses to dispatch it. **Federation is the route** — `user_mouse_input` is in `ADOPTED_TOOLS`. |

## 7. Camera and visual evidence — 8 / 8 ✅

| Command | State |
|---|---|
| `camera.set` | ✅ (plus `camera.get`, `camera.focus`) |
| `camera.orbit` | ✅ same subject, same distance, same pitch, different angle — which is what makes "the rear face is undetailed" checkable |
| `camera.follow` | ✅ including release, because a camera left Scriptable after a capture looks to a player like the game has hung |
| `camera.viewpoint` | ✅ applies a framing resolved on the engine side; the plugin holds no camera profiles, the token set does |
| `capture.frame` | ✅ `capture_frame` (MCP) with the full integrity chain; an untrustworthy frame is labelled rather than returned as evidence |
| `capture.compare` | ✅ `capture_compare` — changed fraction, bounding box and a classification |
| `capture.sequence` | ✅ `capture_sequence` takes a whole device matrix from one world state; a partial set is reported incomplete, because the missing viewpoint is exactly the one nobody looked at |

`capture.compare` was the missing piece for visual regression. Writing it
immediately caught a defect in itself: two frames of different sizes were
classified `identical`, because the dimension check ran after the pixel count. A
visual regression would have passed in silence.

## 8. Quality — 9 / 9 ✅

| Command | State |
|---|---|
| `quality.snapshot` | ✅ measures real BaseParts and visibility from playable points, and takes **no thresholds** |
| `quality.geometry` `density` `scale` `visibility` `ui` `visual` | ✅ `quality_evaluate` fetches a snapshot and applies the rules by family |
| `quality.navigation` | ✅ `quality_navigation` asks the navmesh directly, separating a broken pathfinder from an unreachable destination |
| `quality.performance` | ✅ `quality_performance` samples frame, memory, physics and network against a declared budget, and judges the p99 rather than the mean |

**The split stays where it is.** `quality.snapshot` measures inside Studio and
takes **no thresholds**; every rule is policy in Python. What changed is
reachability: a capability that cannot be called is a capability the platform
does not really offer.

## 9. Scenario — 4 / 6

| Command | State |
|---|---|
| `scenario.compile` | ✅ validates the document and reports its shape without spending a live session on a malformed step |
| `scenario.run` | ✅ plays it against a running place and names each failing step; refuses rather than pretending when no session is reachable |
| `scenario.assert` | ✅ carried by the runner's own step verdicts |
| `scenario.compare` | ✅ which step regressed and which was fixed — a repair loop needs to know it worked rather than assume. Refuses outright when the scenario was edited between runs, because comparing across an edit produces a regression report about a step that no longer exists. |
| `scenario.step` `replay` | ❌ single-stepping and re-running a stored trace |

## 10. Assets — 10 / 13

| Command | State |
|---|---|
| `asset.generate.image` | ✅ `assets.create_image` — EditableImage → `CreateAssetAsync` → real asset id |
| `asset.status` (capability form) | ✅ `assets.capabilities` |
| `asset.search` `preview` `inspect` `validate` `prepare` `publish` `integrate` | 🟡 `rqe/assets/*` — real Open Cloud provider, moderation polling, content-addressed packages |
| `asset.generate.mesh` | ✅ the geometry runtime: `mesh_brief` `mesh_build` `mesh_inspect` `mesh_validate` `mesh_previews` `mesh_compare` `mesh_vocabulary` drive headless Blender and return an inspectable asset package |
| `visual.score` `visual.thresholds` | ✅ the renders read back and scored on silhouette, material separation and detail distribution, with the revisions phrased in the operation vocabulary. Thresholds come from a four-rung reference ladder, never from the candidate; unreadable renders raise rather than score zero |
| `asset.inspect` | ✅ `cloud_asset` reports moderation state — a published asset id is not an approved one |
| `asset.generate.audio` | ✅ deterministic synthesis of the functional cues; Roblox takes mp3 and ogg, so the wav-to-uploadable step is a named `BLOCKED` when ffmpeg is absent |
| `asset.generate.animation` | ✅ R15 KeyframeSequence as `.rbxmx`. `RegisterKeyframeSequence` is Studio-only and deliberately unused; for most motion, driving Motor6D from code needs no asset at all |

Image was chosen as the narrow end of the wedge deliberately: cheapest to
generate, fastest through moderation, no external tool, and it unblocks card
art, icons and UI. Mesh followed through Blender, which is the route for
anything a primitive cannot express.

`APPROVED_FOR_IMPORT` now takes both halves. Topology validation says Roblox
will accept the mesh; the critic says whether it is worth looking at. A
watertight, under-budget, correctly-unwrapped cube passes the first and fails
the second, and the two are reported as different verdicts: `BLOCKED` goes back
to a human, `REVISE` goes back to the modeller with changes.

## 11. Open Cloud — 7 / 7 ✅

| Command | State |
|---|---|
| `cloud.operation` | ✅ Luau Execution: create, poll, logs, with TIMEOUT and BLOCKED as distinct states |
| `cloud.universe` `place` | ✅ read and metadata patch; place *content* is refused, because it is published as a version and conflating the two overwrites a build with a field edit |
| `cloud.publish` | ✅ saves by default; releasing to live servers needs explicit confirmation |
| `cloud.version` | ✅ the other half of a rollback — publishing without seeing what came before is a one-way door |
| `cloud.datastore` | ✅ turns a persistence claim into evidence; a save only the game can read is a save nobody can verify |
| `cloud.asset` | ✅ moderation state, which is where "published" and "approved" stop being the same thing |

A missing key is `BLOCKED` before a request is formed and a refused key is
`DENIED` with the scope it needs. Neither is confused with a server that
answered nothing.

## 12. Factory — 4 / 13 as MCP tools

| Command | State |
|---|---|
| `factory.inspect` | ✅ compiles a project definition into its production DAG and reports the shape |
| `factory.compile` | ✅ `plan_compile` — the fail-closed measurement plan |
| `capabilities.list` | ✅ `capabilities_report`, which states on every response that it cannot authorise a release |
| `release.blockers` | ✅ orphan requirements, token conformance, minimum visual score |
| `factory.create_project` `execute` `resume` `abort` | 🟡 orchestrator DAG, journal and executor exist in Python |
| `capabilities.select` `explain` · `release.evaluate` `promote` | 🟡 |

---

## Totals

| Family | Present | Remaining |
|---|---|---|
| **Studio** | **10 / 10** | — |
| **DataModel** | **11 / 11** | — |
| **World** | **9 / 9** | — |
| **Runtime** | **9 / 9** | — |
| **Player** | **10 / 10** | — |
| UI | 7 / 8 | `click` |
| **Camera / capture** | **8 / 8** | — |
| **Quality** | **9 / 9** | — |
| **Scenario** | **6 / 6** | — |
| **Assets** | **13 / 13** | — |
| **Open Cloud** | **7 / 7** | — |
| **Factory** | **13 / 13** | — |

**112 of 113 primitives resolve against the live registries.** Eleven families
are complete.

One is structurally impossible for us: `ui.click` needs `VirtualInputManager`,
which is refused both in a LocalScript and in a plugin. Roblox's own MCP server
has it, so federation is the route and `bridge_call` refuses to dispatch our
stub rather than pretending.

### This table is generated from checked data, not maintained by hand

Every row above is derived from `rqe/primitives.py`, where each of the 113 names
a concrete target — an MCP tool or a bridge command — and
`tests/test_primitives.py` resolves every one of them against the live MCP
server and the live bridge registry.

That exists because this table was wrong twice while being read as authoritative.
It listed six primitives as missing that had already shipped (`scenario.step`,
`scenario.replay`, `asset.prepare`, `asset.integrate`, `factory.create_project`,
`capabilities.select`), and it reported Quality as complete while pointing at
`quality_evaluate` — a tool in a module the count I ran by hand never loaded, so
I could not tell a real gap from my own mistake. Prose drifts silently: nothing
fails, the table just stops being true. A renamed tool now fails a test instead.

---

## The MetaWorldModel authoring surface — 25 / 35

A *different* list, kept separate on purpose. The 113 above are the engine's
**control** surface: drive Studio, read the DataModel, measure a running game.
The list the MetaWorldModel document specifies at its end is the **authoring**
surface — what an agent needs to *make* something. They overlap without being
the same, and averaging them would let a complete control surface hide an
incomplete authoring one.

| Group | State |
|---|---|
| `mesh.*` | **9 / 9** — brief, create, modify, inspect, optimize, validate, render, compare, export |
| `material.*` | **3 / 3** — create, apply, validate |
| `asset.*` | **7 / 7** |
| `visual.*` | **4 / 4** — capture, inspect, compare, score |
| `world.*` | 2 / 6 — `validate` and `inspect` only |
| `scene.*` | **0 / 6** |

The four families that carry the document's central claim — the modelling loop —
are whole. The two that are not are recorded with what exists behind them rather
than deleted:

**`world.plan` `blockout` `dress`** are real capability with no named tool.
WorldKit implements them in Luau (`roblox/lib/WorldKit/Blockout.lua`,
`Dress.lua`) and they run through `sdk_run`. A capability that cannot be called
by the name it was specified under is not the same as one that ships, so they
are counted as gaps.

**`world.optimize` and all of `scene.*`** are the largest genuine hole.
`instance.create` writes the DataModel and `Kit.seedFor` gives deterministic
scatter, so the parts exist; the semantic layer the document asks for — place by
role and kit and cell, scatter, align, replace, variant — is not built on top of
them. Mesh instancing and draw-call reduction belong here too.

### The material family, and why it is a family

Material separation is 28% of an asset's visual score and it fails totally: the
surface reads as one value, the eye lands nowhere, and every hour of modelling
underneath is wasted. So it gets three tools rather than a parameter.

Colours come from the token set — a program naming its own RGB is a second
palette that drifts from the game's. Application is per part *before* the join,
because that is the only ordering that survives. And `material_validate`
predicts what the critic will measure from the palette alone, before Blender
runs: a build plus five renders costs a minute, a flat palette is knowable in
milliseconds.

The prediction was checked against a real measurement. For the slots the critic's
calibration ladder was built with, it predicts a luminance spread of **69.6**
where the critic measured **71.0** on the actual renders — within 2%. For the
single-grey rung it predicts 0.0 against 28.6 measured, the whole difference
being lighting, which is why the tool reports a prediction and says plainly that
it is not a substitute for scoring the frames.

---

## How MCP fits

MCP is one interface to the engine, not the engine. The shape is:

```
agent → MCP → engine → { bridge → Studio | Open Cloud → Roblox }
                ↓
          orchestrator → capability DAG → evidence → validators → gate
```

Three tools carry the whole live surface rather than one tool per command:

- `bridge_status` — what is attached and in which context
- `bridge_commands` — the surface, grouped into families, with each command's
  effect, idempotency and valid contexts
- `bridge_call` — invoke anything, validated against the manifest before dispatch

One `bridge_call` keeps the manifest sovereign. Fifty-seven generated
descriptors would be a second copy that drifts, and an agent choosing among
fifty-seven near-identical names is worse off than one reading a family listing.

Two properties survive the boundary and neither is optional. Every result
carries the command's `effect` and a `retryable` flag derived from its declared
idempotency, so an agent can see that a publish must not be repeated. And a
refusal keeps its bridge error code, because flattening a lease conflict into a
generic failure is how a retryable problem gets treated as permanent.

## Ordering

1. **Runtime** (2/9) — the weakest family relative to its value. A performance
   budget nobody measures is a comment.
2. **UI** via federation — the adopted tools are declared; wiring
   `user_mouse_input` into the scenario runner is what unblocks E2E.
3. **Capture and compare** — visual regression needs a diff, and there is none.
4. **Factory and scenario over MCP** — pure plumbing over code that already works.
5. **Open Cloud publish/version** — makes CI real.
6. **Studio lifecycle as MCP tools** — must sit above the bridge, not behind it.

## Definition of done

Two or three structurally different games through the whole path. The current
generality evidence is structural — a grid-plot tycoon and a radial wave defence
compile through the same L0–L7 stack and disagree on every axis of their
signature — but neither has been carried to a measured, captured, reviewed
release candidate.
