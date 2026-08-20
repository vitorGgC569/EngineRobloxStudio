# What this project is

Read this first if you have never worked here. It explains the idea; the
[skill](../../.codex/skills/roblox-production/SKILL.md) explains the practice.

## The problem

An AI agent can write Luau all day. It cannot tell whether the game works.

That gap is the whole reason this repository exists. An agent editing a Roblox
project can change files, run a linter, pass unit tests, and still have no idea
whether the map has a floor, whether the shop is reachable, whether the frame
rate collapsed, or whether the thing it just built looks like a game. Roblox is
a black box: the code goes in, and what comes out is only visible to a human
sitting in front of Studio.

So agents compensate. They assert. They write a fixture that describes what the
game *should* be, grade themselves against it, and report success.

This project began exactly there. The engine it inherited scored the game
against `roblox/mvp/game-state.json` — a file someone typed by hand:

```jsonc
"performance": { "frameMs": 12.4 },   // never sampled
"geometry":    { "floating": [] }     // never checked
```

It reported **38/38 PASS, every category 100, release allowed**. The place it
was grading had an empty Workspace. The world is generated at runtime, so there
was never any geometry for a geometry probe to look at, and nothing noticed
because nothing looked.

That is the failure this platform is built to make impossible.

## The idea

**Make Roblox answerable.** Give an agent a way to ask a running game direct
questions and get structured answers, so that every claim about the game traces
back to something measured rather than something declared.

The long-term shape is an assembly line:

```
specification → design → build → integrate → run → inspect
    → test → capture → evaluate → repair → regression → release candidate
```

with a human acting as product director rather than as a Studio operator. That
is the destination. What exists today is the first third of it, built properly.

The reusable-product boundary and the factory's stopping criteria are normative
in [ENGINE-CHARTER.md](ENGINE-CHARTER.md). In particular, the game checked into
this repository is the first integration fixture, not the product of the
platform effort and not a template every future game must resemble.

## How it works

Roblox cannot accept inbound connections, so the flow is inverted. A plugin
inside Studio long-polls a local hub for work; agents put typed commands into
that hub and block on the correlated answer.

```
agent  ──POST /rpc──►   Bridge Hub   ◄──POST /bridge/poll──  Studio plugin
                            │                                      │
                            └────  correlated response  ◄─POST /bridge/result
                                                                   │
                                                     ┌─────────────┴────────────┐
                                                     │  Roblox Studio           │
                                                     │  edit ⇄ run ⇄ Play Solo  │
                                                     └──────────────────────────┘
```

Four layers, each with one job:

**The hub** (`rqe/hub/`) routes and correlates. It knows which Studio sessions
exist, which are alive, and which context each is in. It knows nothing about
games.

**The plugin** (`apps/studio-plugin/`) executes typed commands against the real
DataModel and answers with structured data. It holds no policy and no
thresholds — it measures and reports.

**The client bridge** is a LocalScript the plugin installs into the place under
test. It exists because half of what a player does is client-only: activating a
prompt, clicking a button, seeing a GUI. A LocalScript cannot reach the hub
(`HttpService` is server-only), so the plugin calls into it through a
`RemoteFunction`. One endpoint, both halves of the engine.

**The Python side** (`rqe/`) turns measurements into evidence, evidence into
findings, and findings into artifacts under `artifacts/run-NNNNN/`.

## What "answerable" bought

Within seconds of the bridge existing it reported something no amount of
fixture-reading would have found: the audited place had **2 objects** in its
Workspace — `Terrain` and `Camera`. The map is generated at runtime, so the
geometry the old engine scored 100 on had never existed at edit time.

Since then the same channel has produced, all measured rather than asserted:

- a spawn proven to rest on ground by **nine real raycasts**
- four plots proven not to overlap, from their measured bounding boxes
- **60.06 FPS** sampled from `Heartbeat` over a real window
- a full purchase loop played by an agent: attach to a real player, walk 41
  studs along navmesh waypoints, trigger a prompt, and watch the game's own
  `StoreService.lua` move currency 1000 → 900 and grant a card

That last one is the point. The Luau the game actually ships ran. Not a Python
re-implementation of it.

## Why the game is here

The game is not a demo. It is how the platform finds out what it is missing.

The pattern is fixed: when something breaks, fix it locally **and** ask what
capability its absence revealed. Every capability in the platform arrived this
way.

| Problem | Local fix | What the platform gained |
|---|---|---|
| Container "overlapped" its own contents, 48 false findings | skip nested pairs | ancestor-aware exclusivity, `topLevelOnly` discovery |
| Four parts share one `GetFullName()` | address by ref | stable `GetDebugId` refs everywhere |
| Second measurement pass counted a doubled world | reopen the place | measurement-integrity guard that refuses a dirty run |
| HUD died silently, no server-side trace | fix declaration order | `client.logs` — the client's own output |
| A capture returned a different game entirely | check foreground | occlusion detection on every screenshot |

The rule that keeps this honest: when a measurement accuses the game, first ask
what would make the *measurement* wrong. Twice the validator was at fault and
the game was fine.

## The other half: building

Measuring was only ever half the job. An engine that can reject a bad game but
cannot produce a good one is a judiciary without a workshop, and the layers
below are the workshop.

**The authoring SDK** (`docs/platform/SDK.md`) is eight layers, all pure Luau
with no Studio-only dependency in the core — so the same code runs in a plugin,
in a published experience, and in a headless Open Cloud task.

| Layer | What it owns |
|---|---|
| L0 tokens | every art-direction number, in one file both the builder and the grader read |
| L2 fabrication | CSG, editable meshes and textures, terrain — each call returns a receipt, and degradation is never silent |
| L3 kits | the professional unit of work; a kit, not a part |
| L4 blockout | a playable grey world proved navigable *before* any art |
| L5 presentation | lighting mood, audio graph, camera language, VFX — no asset cost, most of the polish |
| L6 systems | economy, session-locked saves, progression, analytics, a UI design system |
| L7 templates | genre composition; two ship, and the second exists as evidence rather than as a feature |

**The geometry runtime** (`docs/platform/GEOMETRY.md`) turns Blender into a
headless modelling process the engine commands. An agent writes a *program* —
base box, bevel, extrude the reactor, array the vents radially, join, unwrap,
decimate to budget — and never sees `bpy`. It gets back an asset package it can
look at: the mesh, five fixed-angle renders, a topology analysis and a verdict
against Roblox's own rules, all before anything is published.

## Where it currently stands

**The platform measures and builds.** 79 typed commands against a live Studio,
34 MCP tools, an actor that plays the game, reproducible runs, and a fail-closed
release gate that scores an unproven category zero rather than filling it in.

Seven of the twelve primitive families are complete: DataModel, World, Runtime,
Player, Camera/capture, Open Cloud, and — bar synthesised clicks, which no
third-party plugin can have — UI.

**The game is still a functional prototype.** That is now a content problem
rather than a capability one, which is the distinction the last year of this
project was spent earning.

**What remains is the proof.** Genericity is evidenced structurally — a
grid-plot tycoon and a radial wave defence compile through the same L0–L7 stack
and disagree on every axis of their signature — but neither has been carried to
a measured, captured, reviewed release candidate. Until two or three
structurally different games make that trip, the engine is proved on paper and
not in product.

**And one ceiling is not architectural.** Moderation, developer products,
gamepasses and making an experience public are human, with unbounded latency.
`RELEASE_CANDIDATE` is the true ceiling of automation, and everything here is
arranged so that the last mile is an honest `BLOCKED` with a ready package —
never a placeholder passed off as an upload.

## Where to look

| Path | What it is |
|---|---|
| `.codex/skills/roblox-production/SKILL.md` | how to work here |
| `docs/platform/ENGINE-FACTS.md` | Roblox behaviours measured here, each one invisible when you get it wrong |
| `docs/platform/README.md` | architecture deliverables and the first slice's evidence |
| `rqe/hub/` | protocol, hub, client, Studio lifecycle |
| `apps/studio-plugin/src/` | the plugin and its command modules |
| `docs/platform/SDK.md` | the authoring SDK, layer by layer |
| `docs/platform/GEOMETRY.md` | the Blender modelling runtime |
| `docs/platform/PRIMITIVE-API.md` | the 12 primitive families, measured honestly |
| `roblox/lib/WorldKit/` | world building: tokens, fabrication, kits, blockout, presentation |
| `roblox/lib/GameKit/` | game systems: economy, saves, progression, analytics |
| `roblox/lib/Templates/` | genre composition |
| `rqe/geometry/` | the Blender worker, program vocabulary, mesh rules, asset packages |
| `rqe/mcp/` | the engine as an MCP server, and as a client of Roblox's |
| `roblox/mvp/` | the game under test |
| `artifacts/run-NNNNN/` | evidence from each measurement run |
