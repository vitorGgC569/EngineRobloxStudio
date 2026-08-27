---
name: build-a-roblox-game
description: Build your own Roblox game on this engine — scaffold a project, write systems against the Forge families, source and vet real assets from the Creator Store, drive a live Studio through the bridge, and publish. Use when you are making a game with this repository rather than maintaining it. Covers the four-stage asset pipeline, the credential, and the failures that are measured rather than guessed.
---

# Building a game on this engine

You are a client of this repository, not its maintainer. It gives you three
things:

- **Forge** — 59 families of Luau, from `Economy` and `Tycoon` to `Weapon`,
  `Companion` and `Netcode`. A library, not a framework: nothing runs until
  your game calls it.
- **RQE** — the asset and quality engine. Finds real assets, reads them,
  refuses the dangerous ones, and bakes the good ones into data your game can
  rebuild.
- **The Studio bridge** — a hub your tools talk to that drives a live Roblox
  Studio: run code in it, read the world, restart it, measure it.

If you are changing the platform itself rather than using it, read
`.claude/skills/roblox-production/SKILL.md` instead — it is the maintainer's
lesson book. This is the user guide.

## The one rule

**Compiling proves nothing. Running proves everything.**

This is not a slogan; it is the measured history of this repository. Type
checks, unit tests and a clean `forge doctor` have between them caught almost
no real defect. Every defect worth the name was found by executing something
that had never executed:

- a client control that called a server-only function, so every button in the
  game had never once sent a message;
- a generated Luau module with `Table.field: Type =` in it, which is a parse
  error rather than a type error, so the module never loaded at all;
- a prop that measured five studs in its spec and fourteen when built.

Write the code, then **make it run and look at what it did**. A green doctor is
permission to start testing, not evidence of anything.

## Ten minutes to a running game

```bash
python forge/forge.py new mygame
python forge/forge.py doctor mygame
python forge/forge.py build mygame
```

`new` scaffolds a project with no gameplay in it. Systems go in
`games/mygame/src/server/systems/`. `build` runs rojo and writes
`games/mygame/mygame.rbxlx`.

Then get a live Studio:

```bash
python rqe.py studio serve
```

That is the hub, on `127.0.0.1:8790`. It is a long-running server — leave it
up. Open your `.rbxlx` in Studio and the bridge plugin connects to it.

## The bridge

Everything that touches a live Studio goes through the hub as JSON-RPC. 105
commands; `bridge.exec` runs arbitrary Luau and is the one you will reach for
most.

**Sessions are the thing that will bite you.** Studio can hold an *edit*
session and a *server* session at once, and an unpinned call routes to
whichever answers. That does not error — it returns a confident answer about
the wrong world. Always say which you mean:

```python
params = {"source": lua, "_context": "edit", "_timeout": 60}
```

Or pin for a whole measurement sequence:

```python
from rqe.hub.client import StudioBridge
bridge = StudioBridge("http://127.0.0.1:8790")
bridge.pin_to_running()      # the session playing the game
bridge.pin_to_any()          # the session holding the place
```

**Studio drops its session on long runs.** Not hypothetically: a sweep of 300
assets lost it three times. Do not wait for it to come back — restart it, which
takes about ten seconds and is fully automatic:

```python
from rqe.hub import lifecycle
lifecycle.restart_for_bridge(place_path, archive_path, bridge=bridge)
```

That stops Studio, archives the recovery files that would otherwise block an
unattended start, clears the place lock, relaunches, and returns only once the
plugin has handshaken.

**Studio loads plugins at startup.** A fix to the bridge plugin is not live
until Studio restarts. If you need something to work *now*, drive it through
`bridge.exec` instead, which is always current.

## Writing the game

Families resolve lazily. `Forge.Tycoon.DropperChain` works with no
registration — the family's `init.lua` has an `__index` that finds siblings and
caches them. Touching a family does not load everything in it.

Worth knowing before you write your own version of one:

| You want | Reach for |
| --- | --- |
| money, curves, big numbers | `Economy` (`BigNumber`, `Formula`, `IncomeEngine`) |
| plots, droppers, placement | `Tycoon` (`PlotAllocator`, `DropperChain`, `GridPlacement`) |
| saves that survive a restart | `Save` (`DataStoreAdapter`, `Migrator`, `ServerProfile`) |
| levels, quests, rebirth, dailies | `Progression` (18 modules) |
| gacha, luck, seasons, leaderboards | `LiveOps` (`GachaFlow`, `Luck`, `Leaderboard`) |
| firing, spread, recoil, anti-cheat | `Weapon` (`Stance`, `Sway`, `Validate`) |
| pets, drones, anything that follows | `Companion` (`Formation`, `Meander`) |
| remotes that are not a security hole | `Net` (`Validators`, `RateLimit`) |
| terrain, lighting, world building | `World`, `Visual`, `Material` |

Two rules the engine will not enforce for you:

- **`Net.fire` is server-only.** Clients use `Net.send`. Getting this wrong
  fails inside a click handler, which means it fails at click time and never at
  load time, so it survives every startup test.
- **`Net.define` is per-VM.** Both sides must define the channels. Put them in
  one shared module and require it from both.

## Assets: four stages, each refusing what the next cannot afford

A game made of untextured boxes is the single most common reason a Roblox
project reads as unfinished. The pipeline exists to fix that without shipping
someone's backdoor.

```bash
forge shop "mining drill" --role prop --why     # search + filter on metadata
forge pack 10840642581                          # fetch one, split it, scan it
forge sweep --kind tycoon                       # do it across a topic list
forge catalogue --summary                       # read back what survived
forge catalogue --review                        # what a person must read
```

**Stage 1 — metadata.** Free, no download. Refuses on triangle budget (per
role: 1.5k scatter, 6k prop, 25k hero), on price, and on **scripts**.

**Stage 2 — fetch and read.** `rqe.assets.inspection` pulls the model in and
reads what is actually inside: unanchored parts, real dimensions, and every
script's source.

**Stage 3 — the scanner.** `require(<asset id>)` is a refusal, not a penalty.
It fetches and runs code the model's author controls, changeable long after
moderation looked at it. This is not theoretical — a sweep found it live in a
free model called "Luger Pistol" in the pistol topic. Roblox sandboxing
inserted scripts is a real mitigation and not a solution, because the danger is
a developer enabling one to see what it does. Findings split into `blocked`
(never enable) and `read-it` (a person decides), because a scanner that flags
every `HttpService` call is a scanner people learn to click past.

**Stage 4 — bake.** `rqe.assets.bake` reads a model's geometry once and emits
it as data. Your game rebuilds it with `Forge.Catalog.Prop`:

```lua
local Prop = Forge.Catalog.Prop
Prop.place("rock", seed, groundPosition, { targetHeight = 5, parent = folder })
```

This exists because **a catalogued id is not usable at runtime**:
`InsertService:LoadAsset` refuses any asset the signed-in user does not own —
measured across 36 free models spanning 2015 to 2023, it fetched none of them —
and `game:GetObjects`, which does work, is a plugin call a shipped game does not
have. So the geometry becomes versioned, diffable data instead of binary in the
repository.

Know what a baked prop is not: meshed parts rebuild as a `Part` carrying a
`SpecialMesh`, because `MeshPart.MeshId` cannot be written at runtime *or* from
a plugin. That means **no `SurfaceAppearance`** (PBR maps are lost) and **box
collision**. Right for scenery, wrong for anything a player stands on precisely.

## The credential

`docs/goal/key.txt` holds a real Roblox Open Cloud API key belonging to the
project owner. Treat it as follows and you will not have an incident:

```python
from rqe.assets import local_credentials
local_credentials.load()        # puts it in RQE_ROBLOX_OPEN_CLOUD_API_KEY
local_credentials.describe()    # metadata only — never the secret
```

- **The whole file is the key.** Not the first line, not a prefix. Reading part
  of it gives you a key that authenticates as nothing.
- **`describe()` is safe to log.** It reports owner, audience, expiry and
  length. `load()` puts the secret in the environment; nothing should ever
  print it, commit it, or send it anywhere but Roblox.
- **`.gitignore` excludes every `.txt` in this repo**, deliberately, because
  the loose notes are where a secret would end up by accident. Do not add
  exceptions.
- It expires. `describe()["expiresAt"]` is a unix timestamp; when Open Cloud
  starts answering 401, check that before anything else.

What needs the key: Open Cloud asset lookups (`MarketplaceService` metadata via
the web API), publishing places, DataStore access from outside a game. What does
*not*: the toolbox search endpoints, which are the ones Studio's own toolbox
window uses and answer unauthenticated.

## Publishing

```bash
python forge/forge.py publish mygame --universe <id> --place <id>
python forge/forge.py publish mygame --check          # test the credential only
```

Without `--release` it saves privately; with it, live servers get the update.

**Publishing is not cosmetic — it changes what works.** A local `.rbxlx` has
`PlaceId = 0`, and Roblox authorises delivery of non-public assets against the
universe making the request. A place with no universe gets only public,
already-cached assets, so sounds fail "not authorized", textures render grey,
and none of it is your code's fault. Publishing this project's game once turned
19 runtime errors into 0.

Related: **group-owned assets need a place owned by that group.** An asset
uploaded to a group will not load in a personal universe, however free it is.

The publish endpoint rate-limits and reports it as **HTTP 409 "Server is
busy"** — that is throttling, not an outage. Wait seven or eight minutes.

## The validation ladder

Climb it in order; each rung costs more and finds different things.

1. `forge doctor <game>` — authoring checks over your Luau. Cheap. Catches
   server-only calls in client code, field/method shadowing, broken requires.
2. `python -m pytest tests/ -k <area>` — the Luau harness executes real modules
   headless against a partial Roblox shim. Good for pure logic; it cannot
   raycast, so do not assert on anything that needs a world.
3. **Run it in Studio.** `bridge.exec` against a live session, with real
   `Humanoid`s and real geometry. This is where the defects are.
4. `forge gametest <game>` — gameplay scenarios inside the live game.
5. Publish and play it. Nothing else finds what publishing finds.

## Traps, measured rather than guessed

Each of these cost hours here. None are inferable from documentation.

- **`MeshPart.MeshId` cannot be written**, at runtime or from a plugin
  ("lacking capability NotAccessible"). `SpecialMesh` with `MeshType.FileMesh`
  can. Scale is `Size / MeshSize`, because a FileMesh ignores the Part's size.
- **`Model:GetExtentsSize()` is oriented to the model's pivot**, not to world
  axes. If the pivot is rotated — and an inherited `PrimaryPart` pivot usually
  is — it answers with the axes permuted. Set `Model.WorldPivot` explicitly.
- **`Terrain:SetMaterialColor` rejects `Enum.Material.Water`.** Water has its
  own properties on `Terrain`. Use `Forge.Material.water`.
- **`ContentProvider:PreloadAsync` is not a good existence check.** It reports
  failure for assets that demonstrably exist, and four probe shapes were tried
  before that was believed. Use `MarketplaceService:GetProductInfo`, which asks
  the web API instead of the content CDN and returns the authoritative asset
  type as a bonus.
- **`Thing.__index = Thing` means an instance field shadows a same-named method
  permanently.** `forge doctor` checks for this now because it cost a day.
- **Replicated `Model`s arrive before their children.** Resolve parts lazily on
  the client; do not read them at the moment the model appears.
- **Lua patterns are not regular expressions.** No alternation, no `{n,m}`
  quantifiers. Writing `a|b` or `x{200,}` in a `string.find` silently matches
  nothing.
- **`run.stop` leaves Studio unable to accept F5.** It calls
  `RunService:Stop()`, which ends the session without releasing the UI. Use
  `rqe.hub.lifecycle.stop_play_solo(bridge)`, which sends Shift+F5 the way a
  person would. It is a Python helper, not one of the 105 bridge commands.
- **Never spell a Roblox enum, class or property from memory.** They fail
  silently: a wrong `Enum.Material` name is a plastic part, a wrong asset id is
  a grey square. Look it up or probe for it.

## When something does not work

Ask, in this order:

1. Is there a live session, and did my call reach the one I meant? Check
   `_context`, and check `bridge.status()` for what is actually connected.
2. Is Studio running the code I just wrote, or the build from before? A place
   file on disk is not the place in memory. Rebuild and restart.
3. Is this an asset authorisation problem wearing a costume? Grey textures,
   silent sounds and "not authorized" all mean the place, not the code.
4. Did I measure it, or infer it? Every wrong conclusion recorded in this file
   came from a correct measurement and a confident inference laid on top.
