# From judge to engine — the completion plan

Companion to [AUTHORING-RESEARCH.md](AUTHORING-RESEARCH.md). That document says
what the platform *permits*. This one says what we build, in what order, and why
that order.

The premise, restated: the release gate is finished and correct. It can reject.
Nothing in the system can yet *produce*. Everything below is about the producing
half, plus the specific corrections the gate work left open.

---

## The architectural spine

One decision governs most of the rest.

**The SDK must be pure Luau modules with no Studio-only dependency in the core,
because the same code then runs in three places:**

| Surface | How | What it is good for |
|---|---|---|
| Local Studio plugin | our bridge | interactive, screenshots, plugin-only privileges |
| Published experience | shipped in the game | the runtime the player actually gets |
| **Open Cloud Luau task** | `luau-execution-session-tasks` | headless, 10 concurrent per place, no local machine |

Write once, execute three ways. Concretely this means: `WorldKit`, `Fab`, `Kit`,
`Blockout`, `Mood` and the systems SDK never call `plugin:*`, `StudioService`,
`Selection` or `ChangeHistoryService`. Those live in a thin adapter above the
SDK, not inside it.

Everything that follows assumes this rule.

---

## Phase A — Absorb what Roblox already ships

Highest capability delta for the least work. Do this first.

### A1. Federate with the built-in Studio MCP server

Our hub becomes an **MCP client** of Roblox's stdio Studio server, in addition to
owning our own plugin.

Adopt immediately, because they beat us:

| Their tool | Closes |
|---|---|
| `user_keyboard_input`, `user_mouse_input` | the `VirtualInputManager` hole — GUI clicks are currently impossible for us, so every UI scenario sits at zero |
| `character_navigation` | player-driven traversal without our synthetic actor |
| `generate_mesh`, `generate_material`, `generate_procedural_model` | asset production |
| `search_asset`, `insert_asset` | discovery with previews inside the session |
| `multi_edit`, `script_grep` | script authoring against the live place |

Keep ours, because we beat them:

- typed protocol with per-command schemas (theirs returns loose text)
- lease/fencing, exact session assignment, edit↔run continuity
- measurement commands (`world.raycast`, `world.overlaps`, `world.path`,
  `quality.snapshot`)
- capture with the full integrity chain — their `screen_capture` carries no
  runId, buildHash, placeHash, camera pose or occlusion check
- immutable runs and the release gate

**The non-negotiable rule for federation: wrap, do not trust.** Every result
coming back from a Roblox MCP tool enters as untyped data. It must be re-typed,
stamped `source="roblox-studio-mcp"`, assigned a validation level, and bound to
runId/buildHash *before* it can become evidence. Skipping this reintroduces
exactly the fixture problem — an unverified string that scores.

### A2. Expose the engine itself as an MCP server

Today an agent reaches the engine through a Python CLI. That is our script, not
an engine. When `rqe` speaks MCP, any agent — Claude Code, Codex, Cursor —
inherits the typed surface *with provenance already attached*.

Namespaces, merged into one surface by a proxy so the agent sees a single tool
list:

- `roblox.*` — federated from Roblox's server
- `engine.*` — measurement, capture, runs, gate, product truth
- `sdk.*` — kits, tokens, blockout, compile

### A3. Add the Open Cloud Luau Execution backend

`rqe exec --backend=cloud`. Same command protocol, different transport: our
plugin `Dispatcher` and the cloud task must share the *same* Luau command
handlers, or the two backends drift and only one is ever really tested.

Unlocks: parallel runs, CI on a machine with no Studio, and — most importantly —
the two-games proof running concurrently instead of serially.

Constraints to design against: 5 min per task, 10 concurrent per place, binary
payloads for anything large, `SavePlaceAsync` to persist, `SerializationService`
for RBXM.

---

## Phase B — The SDK, which is the part that raises the floor

### B1. L0 — Design tokens as data

`tokens/<theme>.json` holding: palette with **roles** and harmony constraints,
scale grammar derived from character metrics, spacing and type scale, motion
curves, lighting mood presets, camera profiles.

**This is also the structural fix for the threshold-provenance problem.** Today
the visual spec is written separately from the map, which is why its floors read
as fitted to the artifact. If the builder and the spec both derive from one
token file, "the spec describes the candidate" becomes impossible by
construction — the spec describes the *tokens*, and the map is checked against
them. Calibration receipts then point at the token file, not at a measurement of
our own build.

### B2. L2 — Fabrication primitives

- `Fab.cut` / `Fab.sweep` / `Fab.fragment` over `GeometryService` — now with
  MeshPart support, so we can carve a window out of a wall instead of assembling
  it from five boxes
- `Fab.mesh` over `EditableMesh`, with mandatory nil-check, budget accounting
  and `Destroy()` discipline
- `Fab.texture` over `EditableImage`
- `Terrain.write` over `WriteVoxels` (not `FillBlock` loops)

Every primitive returns a receipt: what it produced, budget consumed, whether it
degraded. Degradation must be visible, never silent.

### B3. L3 — Kits, the professional unit of work

Roblox's own curriculum: greybox → **modular kit** → trim sheet → props. The
unit is the kit, not the part. Our WorldKit composes parts; this composes kits.

A Kit is data: a set of modules, a trim/material assignment, variation rules, and
a scale contract. Call site becomes `Kit.place(kit, cell, variant)`.

### B4. L4 — Blockout grammar

`Blockout.define(regions, circulation, landmarks, sightlines)` produces a
playable grey world that can be pathfound, measured and played **before any
art exists**. Then `Dress.apply(blockout, kit, tokens)`.

Two payoffs: iteration on layout becomes cheap, and the gate can grade layout
separately from dressing — so a bad map and an ugly map stop being the same
finding.

### B5. L5 — Presentation

- `Mood.apply(preset)` — `Technology = Future`, Atmosphere, Clouds, ClockTime,
  the five post effects, ExposureCompensation, all from one token
- `Sound.graph(spec)` — the AudioAPI node graph from a declaration
  (`AudioPlayer` → `Wire` → `AudioEmitter` → `AudioListener`, plus fader/EQ/
  reverb). High leverage: few source sounds become a full soundscape, which is
  what you want when moderation is the bottleneck.
- `Camera.profile(genre)`, `Vfx.*`

This layer costs nothing in assets or moderation and is the largest single
contributor to whether a screenshot reads as professional.

### B6. L6 — Systems SDK

Economy, progression, session-locked save, shop, and a UI design system on
Flexbox (`HorizontalFlex`/`VerticalFlex` + `UIFlexItem`, `AutomaticSize` as flex
basis) driven by the L0 tokens. This is where per-game services stop being
rewritten from scratch.

### B7. L7 — Genre templates

Tycoon first (we have one to harvest). Then a structurally different genre —
which is also the generality proof.

---

## Phase C — Close the asset loop, one path at a time

### C0. The one-time human checklist

Document and get done, once:

- 13+ **ID verification** on the account/group
- **"Allow Mesh / Image APIs"** toggle in Game Settings → Security
- Studio beta flag **"CreateAssetAsync Luau API"**
- Open Cloud API keys with `asset:write` and `luau-execution-sessions:write`

Until these are done, every asset path is honestly `BLOCKED` — which the pipeline
already models correctly.

### C1. Close **one** loop end to end: images

`EditableImage` → `AssetService:CreateAssetAsync` (Image) **from our local
plugin** → real assetId → integrate. 30 req/min.

Images first because: cheapest, lowest moderation friction, no external tool
needed, and it unblocks card art, icons and UI — the three places the current
game looks worst. Also proves the `CreateAssetAsync` path without needing an
Open Cloud key.

### C2. Then meshes

`GenerationService.GenerateModelAsync` (or MCP `generate_mesh`) → validate →
`CreateAssetAsync` (Mesh) → integrate. Budget for Roblox's own stated limits:
single objects, manual rescale, texture quality still weak. Blender-headless →
FBX/glTF → Open Cloud stays as the higher-quality alternative.

### C3. Then audio

Offline synthesis → Open Cloud Assets API. Moderation latency is the gate, not
the code — plan for `BLOCKED` as a normal state with a resumable job.

### C4. Animation

Default path is **procedural Motor6D/CFrame**: no asset, no upload, no
moderation, works in all three execution surfaces. Uploaded `.rbxm` animations
are the exception, not the rule. `RegisterKeyframeSequence` is Studio-only and
must never appear in shipped code.

---

## Phase D — Instruments for "good" and "fun"

### D1. `AnalyticsService` inside the systems SDK

Funnel events (onboarding, progression, shop), economy events (sinks, sources,
wallet balance) and custom events emitted by default from L6, so every game the
engine produces is instrumented without anyone remembering to do it.

### D2. Headless economy simulation

Lune or Python over the same catalogs the game uses. Thousands of simulated
player-hours producing pacing curves, time-to-first-upgrade, sink/source
balance. This is what tells you the second upgrade is mispriced — the engine
currently cannot form that sentence.

### D3. First-90-seconds scenario

A standard gate for every genre template: can a new player understand the loop,
reach the first meaningful action, and complete it, within 90 seconds.

---

## Phase E — Corrections the gate work left open

| # | Correction | Status |
|---|---|---|
| E1 | Contract/spec/build identity must match the intended product | Product Truth built — verify it actually blocks, and that the current game stays blocked |
| E2 | Threshold provenance | solved structurally by **B1**; until then, calibration receipts must cite external references |
| E3 | Orphan requirements (`card_gallery` → disabled script) | probe registry reports `UNPRODUCIBLE` — verify |
| E4 | A single `critical` VLM finding vetoes release (40 penalty vs 95 floor) | require deterministic corroboration before a `critical` blocks; separate "scores" from "vetoes" |
| E5 | `maximum_evidence_age_seconds: 3600` uniform | freshness per evidence type — a full playtest + capture + review cannot close in one hour |
| E6 | `_category_fallback` scoring 100 without an enumerated plan | reportedly removed — verify |

---

## Phase F — The only proof that matters

**A second game, in a structurally different genre, through the same path.**

Not a re-theme. Different loop, different progression shape, different camera,
different UI. Everything about genericity is a design intention until this
passes, and it is the cheapest way to discover that a "generic" abstraction is
actually shaped like the first game.

---

## Recommended first three moves

1. **A1 — MCP federation.** Largest capability delta for the least work.
   `user_mouse_input` alone converts every UI/E2E requirement from
   permanently-zero to measurable.
2. **B1 — tokens as the single source for builder *and* spec.** Structurally
   removes the tautology risk before more spec is written on the old footing.
3. **B4 — blockout grammar.** Makes layout iteration cheap and separates "badly
   laid out" from "ugly", which the gate currently cannot distinguish.

---

## The risk to keep watching

The engine has more than doubled in size while the produced game is still at
zero. There is a real failure mode where verification keeps getting more
sophisticated for something that never gets made. Phases B and C are the only
ones that move the produced artifact; A, D, E and F make that movement possible
or visible. If a month passes with no work in B or C, the ratio has gone wrong.
