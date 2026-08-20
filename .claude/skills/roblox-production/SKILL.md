---
name: roblox-production
description: How to build and validate Roblox games on the RQE platform. Use whenever working in this repository - changing the game, the WorldKit library, the Studio bridge, or the validators. Covers the bridge command surface, the validation ladder, engine limits that cost hours to rediscover, and the standard a build must meet before it is called done.
---

# Producing Roblox games on this platform

You are working in a repository that is two things at once: an **agentic
platform** that can drive and measure a live Roblox Studio, and a **game** built
with it. Both matter. The game is how the platform proves itself.

New here? Read `docs/platform/OVERVIEW.md` first -- it explains the problem this
solves and why the architecture looks the way it does. This document is the
practice; that one is the idea.

## The rule everything else serves

**Never report a result you did not measure.**

The platform exists because the previous engine graded the game against a
hand-written JSON fixture and reported 38/38 PASS, all categories 100, release
allowed — for a place whose geometry had never been looked at. `frameMs: 12.4`
was a literal someone typed.

So every claim carries a level, and you say which one:

| Level | Means |
|---|---|
| `NOT_VALIDATED` | Nothing ran. A design doc is this. |
| `STATICALLY_VALIDATED` | From source, or from a live place in **edit** mode. |
| `RUNTIME_VALIDATED` | From a **running** place. |
| `VISUALLY_VALIDATED` | From a captured frame at a known camera pose. |
| `E2E_VALIDATED` | A player-equivalent actor completed a scenario. |

Evidence stamped `source="studio-bridge"` was measured. Evidence stamped
`source="headless-runtime"` mostly comes from `roblox/mvp/game-state.json`, a
fixture. Never present a fixture value as a measurement.

## Getting a live Studio

```bash
python rqe.py studio install .                                  # build + install the plugin
python rqe.py studio serve                                      # hub on 127.0.0.1:8790, separate terminal
python rqe.py studio restart .tmp/<place>.rbxlx .               # unattended: archives auto-recovery, clears lock, waits
python rqe.py studio call bridge.install_client                 # client half, needed for prompts and GUI
python rqe.py studio play_solo                                  # real Player; costs one foreground keypress
```

Changing `apps/studio-plugin/src/**` requires `studio install` **and** a Studio
restart. Studio does not hot-reload plugins.

Before any read sequence:

```python
bridge.pin_to_running()   # refs are per-DataModel; unpinned reads mix two worlds
```

## The command surface

Discover it live rather than trusting this list:

```bash
python rqe.py studio call bridge.capabilities
```

Roughly: `dm.*` (tree, properties, find), `world.*` (raycast, bounds,
ground_support, overlaps, path, summary), `run.*` (start, stop, state, players),
`actor.*` (spawn, attach, walk_to, navigate_to, interact, touch, prompts),
`client.*` (prompt_trigger, gui_tree, gui_locate, fire_remote, invoke_bindable,
probe_images, logs), `camera.*`, `log.tail`, `bridge.exec` (edit mode only).

`world.path` includes a control probe: if a trivially-connected hop fails, the
navmesh is unusable and a `NoPath` verdict says nothing about the level. Check
`conclusive` before blaming the map.

## Before you accuse the game

This is the most expensive lesson here. In one session **five** measurement
errors each looked exactly like a product defect:

- Pathfinding to an objective's **bounding-box centre** always returns `NoPath`,
  because the centre is inside the solid. Targets must be *approached*.
- A container always "overlaps" its own contents. Exclusivity checks must skip
  ancestor/descendant pairs.

- `dm.tree` **truncates at 399 children**. A count from a truncated list said
  the world was half built. It was complete: `dm.find` returned 179 trees and
  120 patches. Check `truncated` before believing any count.
- A window found by title lookup is **not the window `capture` photographs**.
  Ask `Win32CaptureBackend().studio_windows()`. Resizing one and photographing
  another produced a full-width frame labelled "mobile".
- A probe that cannot move proves nothing. Two purchases were called FAILED on
  "towers 29 to 29" while four towers had been built, because the pad renames
  each one to its catalogue id. **"I looked and saw nothing" is evidence only
  when you can show you would have seen something.**

When a measurement accuses the game, first ask what would make the measurement
wrong. Then say which one it was. On this project the instrument has been wrong
more often than the product.

## What a PASS is allowed to claim

`rqe/evidence.py`. Three claims wear the same word, and conflating them produces
confident nonsense:

    COMMAND_SUCCESS   the wire works. Nothing about the game.
    BEHAVIOR_SUCCESS  the named effect was observed happening
    E2E_SUCCESS       the game moved, in the direction expected
    FAILED            the product did not do it, and the instrument saw that
    NOT_VALIDATED     the instrument cannot tell. Never a PASS.

Two rules that cost real debugging:

- **Direction, not difference.** A purchase leaving cash at 20 to 49 is not a
  purchase; income accrued during the round trip and outran the price. Pass
  `expect="decreased"`.
- **On a live game a shared resource is a bad probe.** Use the effect only that
  action produces, and prove the probe can move before trusting that it did not.

An instrument that cannot observe must blame itself. `actor.interact` used to
call `InputHoldBegin` from the plugin DataModel, where it can never fire, and
report `prompt_did_not_fire`. Honest, and it sent readers to debug a working
handler. It now delegates to the client relay.

## The regression corpus

`corpus/briefs.v1.json`, 20 briefs across 20 genres. Run `rqe.corpus.run` after
any change to the factory.

It exists because every quality number here came from one game. First run found
the overfitting immediately: `open_world` had no structure, because the grammar
had only ever been asked for the three topologies a tower defense and a tycoon
need.

Do not assert scene-critic scores across the corpus. Those thresholds came from
two frames of one game and say so in their own calibration record.

## Reuse before generate

`rqe/sourcing/registry.py`. REUSE beats ADAPT beats GENERATE, with licence as
tie-breaker, and two brakes that matter more than the rule:

- **Identity roles are never bought**: hero, objective, landmark, machine, boss.
  Buying them is how every game from the same CC0 pack becomes the same game.
- **Modular and surface roles are never bought**: structure, wall, ground,
  paving. A bought mesh of a building is a mesh of exactly one building.
- **An unclassified role is built, not bought.** A wrong purchase is harder to
  notice than a wrong build.

CC-BY attribution is a **UI requirement**: the credit must appear in the running
game. `attributions()` returns data because it has to reach a screen.

## Authored geometry without an upload

`AssetService:CreateEditableMesh` plus `CreateMeshPartAsync` build a real
MeshPart from vertex data: no upload, no credential, no moderation. This removed
the chain that kept every important object a Part.

Blender writes `mesh.json` beside the `.glb`; `rqe/geometry/luau.py` turns it
into a module; `WorldKit.Mesh` builds it. External `.glb` enters the same door.

Two things that will bite:

- **Cache the MeshPart, not just the EditableMesh.** `CreateMeshPartAsync`
  yields; called per prop it leaves the world still building when you photograph
  it. Build one template per asset and `Clone()`.
- **A kit prop needs its own palette role.** The authored tree shipped invisible
  because it fell back to `structurePrimary`, 0.046 in luminance from the ground
  it stood on. `rqe/art/direction.py` now enforces a foliage/ground gap.

## Authoring, not only producing

`producer_run` takes a brief and decides everything. That is the shortcut, not
the default. The composable path is the one to reach for when the judgement is
yours:

    world_blockout / scene_place / scene_scatter   the world
    material_apply / tokens_inspect                the look
    sourcing_search / adopt / publish              external assets
    gameplay_check / gameplay_install              behaviour
    bridge.exec                                    anything WorldKit can do
    capture_frame                                  look at what you made

Measured: `WorldKit.Threat.build` through `bridge.exec` put a creature in the
open place in 25ms. One call, no pipeline.

**Behaviour is data.** `gameplay_*` takes rules of `when` / `require` / `then`
against a fixed vocabulary -- 6 triggers, 4 conditions, 9 effects, each mapping
onto a GameKit capability that already exists. Validated before install, so a
rule spending a currency the economy never declared is an authoring error rather
than a silent no-op on the one path nobody tested.

`gameplay_install` writes a Script into the open place rather than installing
into a live session. Connections made in a play session die with it, and
`bridge.exec` is edit-only anyway. Author in edit, then play: the rules come up
with the session and survive a restart.

Two things that will bite:

- **Lua is not JSON.** Interpolating `json.dumps(rules)` into a Script produced
  a parse error on line 11: JSON arrays open with `[` and separate keys with
  `:`. Use `_lua()`; `then` and `require` are Lua keywords and have to be
  indexed.
- **A new SDK module needs a rebuild.** Rojo packages `roblox/lib` into the
  place at build time, so `GameKit.Rules` was nil until the place was rebuilt.
  Editing an existing module is live; adding one is not.

## Bridge latency is the poll hold

Every command whose handler yields costs one poll hold, and the reason is not
obvious: Roblox serialises a plugin's HTTP, so while the poll's GET is held open
the POST carrying a finished result cannot leave.

    hold 20.0   client.info 20.05s   (client answered in 0.030ms)
    hold  1.5   client.info  1.55s   (client answered in 0.030ms)

Edit and server commands were always ~0.03s -- only the `client.*` relay pays
this. `DEFAULT_POLL_HOLD_SECONDS` is now 1.5.

**Check for a second hub before believing a latency measurement.** Two `rqe
studio serve` processes can both hold port 8790, and the older one answers.
The first attempt at this fix appeared to change nothing for exactly that
reason: `netstat -ano | grep 8790`.

## Reuse before generate, with hands

`rqe/sourcing/connectors.py` and the `sourcing_*` tools. The chain runs end to
end and is proven: Kenney CC0 -> adopt -> hash -> Open Cloud -> moderation
Approved -> asset id in the game.

- **It does not scrape.** Kenney, Quaternius, ambientCG and game-icons all serve
  downloads through forms or choosers; guessing a CDN path produced a confident
  404. `fetch` handles stable direct URLs, `adopt` takes a pack already on disk
  under a stated licence. A catalogued pack with no URL says so rather than
  failing at the network.
- **`publish` is its own tool.** It puts an asset on a real account through
  moderation; an irreversible act must never be a flag on a reversible one.
- **CC-BY credit is a UI requirement.** `attributions()` returns data because it
  has to reach a screen in the running game.

## Start with the map

`rqe_guide` before anything else. 129 tools cannot be used by reading 129
descriptions: nothing in the names says what comes first, what needs Studio open,
or which family does the whole job in one call. The guide carries the routes and
the traps; its inventory is generated from the live registry, so a family added
tomorrow is on the map without anyone remembering.

A test asserts the map and the registry agree in both directions -- no route
naming a tool that does not exist, no family without a description. It caught
`game_create` (the tool is `game_new`) and an `audio` family with no tools at
all, which turned out to be a missing capability door rather than a typo.

## Capability without a door is not a capability

Seven WorldKit modules -- Camera, Vfx, Guidance, Nature, Setpiece, Conveyor, Fab
-- were written, tested, shipped inside places, and reachable only by hand-written
Luau. Camera mattered most: framing is half the language of a scene and there was
no way to ask for it.

They are now `staging_*`, `camera_*`, `vfx_*`, `guidance_*`, `nature_scatter`,
`setpiece_build`, `conveyor_build`, `fab_*`, `audio_*`. Two things learned
wiring them:

- **Read the signature, do not guess it.** `Palette.theme(tokens)` does not
  exist -- themes are named tables (`BrickFarm`, `MinersRidge`) and the guess
  failed three frames deep as `attempt to index nil with 'metalDark'`, naming
  neither the tool nor the mistake. `Nature.scatter` takes `size: Vector2`, not
  a radius, and has `exclusions` -- the difference between a forest and a forest
  growing through the roads.
- **Name the alternatives in the refusal.** Every wrapper that takes a name
  lists what it has when given one it does not.

## Movement is not only for humanoids

`GameKit.Pursuit` -- chase, flee, patrol, halt -- and the matching rule effects.
Pathfinding, repath on drift or interval, stuck detection, one shared 10Hz
heartbeat for every pursuer.

`WorldKit.Threat` builds an anchored Model with a PrimaryPart and **no
Humanoid**, which is what most stylised creatures are. So pathfinding is shared
and only the last step differs: humanoids get `MoveTo`, everything else has its
pivot carried.

**Carrying is horizontal.** Waypoints sit on the navmesh, which is the floor. The
first version aimed the model's *pivot* at them, so the creature sank half its
height into the ground and stopped dead:

    62,60 / 65,59 / 70,61 / 74,62 / 77,62 / 77,62 / 77,62

Travel is now computed in XZ and the height comes from the waypoint plus half the
bounding box. Measured after: 100 studs closed round a 60-wide wall, patrol
cycling all three points at the requested 22 studs/s.

## Tweens do not run in edit mode

`Ui.meterSet` set its fill through `Ui.animate`, and TweenService does not
animate in Studio's edit mode. Every meter in every game photographed full,
whatever the attribute said -- and the scene critic captures in edit mode, so
this survived every review. `meterSet(tokens, meter, 0.35)` left
`Fill.Size.X.Scale` at 1.00 both before and after.

`Ui.animate` now applies the goal directly when nothing will animate it. Callers
get the same end state either way, which is the only promise it should make.

## Screens can be written, not only chosen

`ui_compose` and `WorldKit.Compose`: panels, text, meters, chips and buttons as
data, bound live to attributes. Proven with a sanity HUD following an attribute
through 82 -> 17 -> 95 in both bar and caption.

- **Layout is not optional.** A composed panel always gets a stack; there is no
  way to ask for the arrangement where children pile at the origin.
- **`Enabled` defaults to true.** Generated games all built screens false and
  nothing set them true, so no game the factory made could open one.
- **Vocabularies collide.** `Ui.stack` speaks `row`/`column`; a caller describing
  a screen thinks `horizontal`/`vertical`. Both are accepted.

## Publishing a place is not publishing an asset

`place_publish` ships into an experience that already exists. Open Cloud has no
endpoint that creates one -- the universe and start place must be made once in
Studio or on create.roblox.com. Saving is the default; `release: true` pushes to
every live server.

## The three that separate amateur from finished

The surface could build a world, light it, give it rules and populate it, and a
person looking at the result still saw someone's first Roblox game. Three
reasons, none of them a missing idea -- all three were capabilities that either
did not exist or had no door.

**Terrain was a green box.** The whole capability was `Fab.terrainBox`. Voxel
terrain needs no upload, no asset id and no moderation, which made it the
highest-value unclaimed ground in the engine. `WorldKit.Land` now does
heightfields, fill/carve, material painting, tinting and water. Three things the
raw API will not tell you:

- Terrain is on a 4-stud grid, and `WriteVoxels` rejects an unaligned region
  with an error that does not mention alignment. Use `Region3:ExpandToGrid`.
- **Occupancy is not visibility.** A voxel at 0.5 renders as a slope. Writing
  1.0 below the surface and 0.0 above gives a staircase; the surface cell has to
  carry the fraction.
- **`MaxExtents` is not the size of your terrain.** It is the volume terrain is
  *allowed* to occupy, a constant 64000 studs cubed. Reporting it made a
  512-stud island look like it filled the world, and framing a camera on
  `Terrain` photographs a speck. There is no "what is filled" query -- sample it
  with downward raycasts.

Measured after: 289/289 sample points on land, footprint -256..256, heights
-11.3 to +11.6, 164 Grass and 125 Rock after painting the ridges.

**There was no animation at all.** No `Animator`, no `Motor6D`, no clips.
`Pursuit` gave creatures somewhere to go and they slid there rigid, which is the
loudest amateur tell a Roblox game has. `GameKit.Motion` is procedural -- gaits
as sines applied to part offsets -- because a Roblox `Animation` needs an
uploaded asset id and a rig, and `Threat` builds loose parts under a Model.

**One part must be the anchor and must never move.** The first version animated
every part including the PrimaryPart, which *is* the pivot -- so each frame
displaced the reference frame the next frame measured from. Measured: 3.47 studs
of drift after twenty ticks, against a promise of zero. With an anchor: exactly
0. This also makes motion compose with `Pursuit`, which drives the anchor.

**Post-processing existed and had no door.** Atmosphere, Bloom,
ColorCorrection, SunRays and DepthOfField were all written inside `Mood.lua` and
no caller could touch one. `lighting_grade` reaches them. Reuse the instances,
never stack them: two ColorCorrections multiply, and the second is invisible in
the explorer until the frame is already wrong.

**Watch for a place's existing DepthOfField.** `last-vigil` had focus at 0.05
studs from a previous `Mood.apply`, which blurs everything past the lens and
makes every capture look like a rendering bug.

## Real money has different rules

`GameKit.Commerce`: game passes, developer products and `ProcessReceipt`. There
was no `MarketplaceService` anywhere before this, so every game the factory made
was a commercial product with no way to be commercial.

**`ProcessReceipt` is the one function in a Roblox game that can lose a player's
money.** Roblox calls it *after* the charge. Return anything but
`PurchaseGranted` and it is called again -- possibly on another server, possibly
after a restart.

- **Unknown product ids return `NotProcessedYet`, never `PurchaseGranted`.**
  Telling Roblox a charge was honoured while delivering nothing is the worst
  outcome available.
- **Grant first, record second.** Both orders lose something: grant-first risks
  granting twice, record-first risks charging for nothing. Charging for nothing
  is worse, so grant goes first and the record retries hard.
- **It cannot be read back.** `MarketplaceService.ProcessReceipt` is a callback:
  assignable, not gettable. Keep your own reference or `report()` cannot say
  whether a handler is installed -- and there is no way to test the path.
- **`Commerce.simulate` is the test seam.** Proven with a real player in Play
  Solo: three calls with one `PurchaseId` granted exactly once
  (`ReceiptGrants = 1`, `ReceiptOil = 1`), and an unknown id refused.

**A DataStore handle is not a working DataStore.** With Studio API Services off,
`GetDataStore` succeeds and every `SetAsync` throws. The measured run showed
`first = NotProcessedYet` after a successful grant for exactly this reason --
correct behaviour, and invisible unless you look. `Commerce.canPersist()` answers
it by writing, because no property does.

Nothing creates a pass or a product -- not Open Cloud, not Studio. They are made
on the website and their ids arrive at `declare`.

## Never spell a Roblox name from memory

Three failures this round, all the same shape, all expensive out of proportion
to the mistake:

- `Enum.ReverbType.Concerthall` -- the real spelling is `ConcertHall`. Indexing
  a missing enum member raises at *module load*, so one character of casing took
  down every function in the file and reported only "Requested module
  experienced an error while loading", which names neither the enum nor the line.
- `Workspace.StreamingTargetRadius` and `StreamingMinRadius` -- removed from
  current Roblox. `not a valid member of Workspace`.
- `MarketplaceService.ProcessReceipt` -- a callback: assignable, never readable.

Ask the engine:

    Enum.ReverbType:GetEnumItems()
    pcall(function() return (workspace :: any)[name] end)

And build the answer into the code. `Acoustics` resolves reverbs by string and
names every valid one when the lookup fails; `ship_settings` probes each
property before touching it and reports which ones this version has. Both turn a
class of silent breakage into a sentence.

**pcall the reads too.** `ship_settings` wrapped its writes and not its reads,
so a tool designed to degrade gracefully raised instead.

## Rooms that sound like rooms

`WorldKit.Acoustics`: named spaces (cave, cathedral, hall, sewer...) as zones
with priority, following the listener. Walking into a cave and hearing the tail
lengthen tells a player they are inside before they have looked at anything.

**The hard part is the boundary, not the reverb.** A player standing on a zone
edge crosses it several times a second, and switching on every crossing stutters
worse than having no zones. A new space must win `HOLD_SAMPLES` consecutive
samples before it is applied -- about half a second of commitment at 5Hz.

Client-side only: reverb is what one person hears and a server has no single
listener. Called on the server it installs and *says* nothing will follow.

## Zero is a value

`float(arguments.get("upper") or 90)` reads naturally and is wrong. Zero is
falsy in Python, so a caller asking for `upper: 0` -- a door that closes flush
-- silently got 90 degrees. **Lua would have done the right thing with the same
expression**, which is exactly why the shape survived reading in a codebase that
moves between the two languages all day.

Thirty of these across four modules written the same afternoon. Use `_num` /
`_int`, which check `is None`.

The guard in `tests/test_authoring_surface.py` walks the AST rather than the
text: the regex version matched the sentence in `_num`'s own docstring
explaining the bug, and missed the one real survivor because its default was an
expression rather than a literal.

## Where two tools must be used together, the tool knows

`pursuit_start` pathfound and `motion_play` animated, and nothing connected
them -- so following the guide's own route produced a creature that walked round
corners while sliding. That is the exact defect `Motion` was built to fix,
reachable by doing everything right.

Movement now animates by default, on the tool and on the `chase`/`flee`/`patrol`
rule effects; `gait: none` opts out. The broken version has to be asked for.

This is the general rule for an LLM-driven surface. Documentation that says "and
remember to also call X" is a defect report, not a fix.

## Roblox fails silently, so the tools must not

Every capability in `Interact` and `Platform` has one trap where the engine
shrugs:

- **A weld between two anchored parts does nothing.** It is created, parented,
  and has no effect. The most common "my machine will not move" bug there is.
- **A `SurfaceGui` at defaults is unreadable.** `PixelsPerStud` is 50, so a
  20-stud wall is a 1000px canvas and `TextSize = 24` is invisible. Size signs
  in studs and convert.
- **`ClickDetector` defaults to 32 studs**, which leaves a player unable to
  click the door they are standing at.
- **Two teams sharing a `TeamColor` merge.** Roblox keys teams by BrickColor;
  players on the second land on the first, with no error.
- **`AwardBadge` from a LocalScript silently does nothing.** Server only.
- **A failed teleport strands the player** with a blank screen unless
  `TeleportInitFailed` is handled.
- **A `BillboardGui` with no `MaxDistance`** draws from across the map.

## The modular kit, and the ops that were missing

`rqe/geometry/structural.py`: 15 silhouettes in four grammars -- walls (solid,
doorway, window, parapet), floors (tile, paving, plaza), members (column, beam,
railing, arch, stair, ramp) and roofs (flat, pitched). Programs went from 5 to
20.

**`structure` is one role, not seven.** The brief's vocabulary describes what a
thing *does* -- hero, machine, prop, structure -- and a wall, a floor and a
column all do the same thing. Widening that set to `wall` and `floor` would
conflate a gameplay role with a kind of geometry. The role picks the family, the
silhouette picks the piece.

**Everything snaps to 4 studs**, which is also the terrain voxel, so a wall meets
sculpted ground. Thickness does *not* snap -- it is a material property, and a
wall snapped to 4 studs thick is a bunker.

**The router sends `structure` to worldkit**, so these programs need
`backend: "blender"` to run at all. That is a live policy question, not a bug:
both paths land on the same grid and the difference is detail against runtime
cost.

Five operations added: `screw` (lathe -- balusters, turned columns), `displace`
(cliffs, erosion), `sweep` (pipes, cables, track curves -- the most limiting
absence), `loopcut` (edge flow), and `weld`.

- **`bpy.ops.mesh.loopcut_slide` needs an interactive editor and does nothing
  headless, silently.** Use `bmesh.ops.subdivide_edges` on a ring.
- **A swept curve must be converted to a mesh.** A curve object cannot be
  exported, joined or booleaned, and forgetting produces an empty `.glb`.
- **`displace` moves existing vertices**, so a box with eight of them displaces
  into a wonky box. Subdivide first; the op refuses rather than doing nothing.

**`join` with one target is refused by the validator**, correctly -- joining one
object does nothing and almost always means a name is wrong. A solid wall
genuinely is one object, so it becomes the result directly.

**`boundaryEdges == vertices` and `watertight: false` are normal here.** The
doorway wall that renders correctly reports exactly the same numbers as a mesh
that looks broken, so neither is evidence of anything on its own. Read
`validation.json`'s severity instead: the cliff was `approved: true, blocking: 0`
while `status` said BLOCKED purely on dimension agreement.

## The scene critic could not see exposure

It returned 98-100 for a frame whose character was blown to flat white, and it
was **right by its own lights**: not one of its six dimensions measured
exposure, so an image with a sheet of 255 across it satisfied hierarchy,
richness, landmark, primitive appearance, readability and cohesion exactly as
well as a correct one. That is not a mis-set threshold, it is a missing sense.

`exposureHealth` is the fraction of the frame clipped to white or crushed to
black. Weight 0.06, taken from the two largest axes in proportion, and
**blocking**: a clipped frame cannot be judged on anything else because the
information the other axes would read is gone.

Measured on a ladder ordered before anything was read:

    correct        overall 75.1   exposure 100.0   clipped 0.000
    bright x1.6    overall 69.2   exposure  64.9   clipped 0.145
    blown  x2.6    overall 54.8   exposure   0.0   clipped 0.385
    dark   x0.15   overall 43.3   exposure 100.0   clipped 0.009

**Darkness is not clipping.** The dark frame scores 100 on the axis and that is
correct -- its information is compressed, not destroyed, and comes back when the
exposure is raised. Tuning the black threshold until that frame "failed" would
have made the axis fire on every night scene, which is most of the horror game.
The overall still falls to 43.3 because the other axes see the darkness.

Two reading errors worth remembering: `SceneCritique.overall` is already 0-100,
and a frame at x0.15 is dark rather than crushed. Both were mine, both were
found by looking at the numbers rather than by trusting the label I had put on
them.

## Chat is a moderation surface

`GameKit.Chat`. Player text shown to another player must pass
`TextService:FilterStringAsync` -- **pet names over heads, player-written signs,
team names, shop listings**, not just the chat window. Games are taken down for
this.

- `Chat.filter` returns **nil** when filtering fails, so "show it anyway" is not
  reachable from the API. A game that shows raw text when the filter is down has
  the same defect as one that never filtered, only rarer.
- Filtering is **per recipient**. The same string is filtered differently by age,
  and filtering once for everybody defeats it.
- **`TextChatCommand` does nothing under `LegacyChatService`.** It parents
  cleanly, raises nothing and never fires. This project's own place is on legacy,
  so `Chat.modern()` is checked before installing anything and `report()` says
  `commandsWillFire: false` rather than listing commands that cannot run.

## A map that stops covering the territory

`rqe_guide`'s inventory is generated from the live registry and cannot drift.
Its **routes are written by hand**, and after one session of adding families 31
of 55 had no route at all -- so an agent reading the guide never learned that the
world could be made touchable, or that Blender was reachable.

There is now a test that every family appears in some route. The lesson
generalises: the generated half of a document keeps itself honest, the written
half needs a test, and the written half is the half that carries the ordering.

## Building is not looking

`corpus_look` opens built games, **runs them**, photographs and scores them.
`corpus.py` evaluates stages, and a stage is a claim about a pipeline rather than
about a game -- which is how twenty green builds sat beside a screenshot of a
green box.

Two false measurements had to be caught first, and both looked like they worked:

- **Capturing in edit context.** Three different games scored 82.7 with
  byte-identical findings -- 13% clipped, 28% primitive, the same four
  complaints. The frames were empty sky: these games assemble their worlds at
  runtime, so the editor viewport shows nothing and the critic was measuring
  Studio's own UI. Start Play Solo before the shutter.
- **Not passing `viewport`.** `critique_scene` has always taken one and its
  docstring has always said why -- "without it the ribbon and the property panel
  are measured as part of the scene" -- and **no caller in the repository passed
  it**. Cropped, `brambleway` went from 13% clipped to 0.1%: the clipping was the
  toolbar.

**Re-pin after Play Solo.** The session pinned before is the editor. Every call
kept landing there while the game ran beside it, and the capture's own integrity
check caught it: "camera.focus ran in the editor, and this capture was asked for
as gameplay evidence".

**And the crop retired half the exposure axis.** Cropped properly, `last-vigil`
showed 58% of its viewport at pure black -- because it is a night game, by
design. Crushed blacks are now measured as `crushedFraction` and never scored;
only blown highlights are. The test that was supposed to prevent this passed the
whole time, because it dimmed a frame globally rather than building real black.

## A world that moves

`WorldKit.Physics`: ropes, springs, ball sockets, sliders, pushes, holds and
ragdoll. `Interact`'s welds and hinges are rigid; nothing swung or collapsed.

- **Constraints join Attachments, not parts.** One with a nil end installs
  cleanly, does nothing, and looks right in the explorer.
- **Anchored parts ignore every one of them, silently.** First thing to check.
- **Ragdoll is not switching off the Humanoid.** The Motor6Ds keep the body
  rigid, so that gives a statue that topples in one piece. Each Motor6D has to be
  replaced by a BallSocket at the same attachment points.
- **Forces are one-ended.** `VectorForce` has only `Attachment0`, and reporting
  its missing `Attachment1` as a fault made the diagnostic fire on every push --
  which trains you to ignore the list that exists to catch real failures.

## A map that stops covering the territory

`rqe_guide`'s inventory is generated from the live registry and cannot drift.
Its **routes are written by hand**, and after one session of adding families 31
of 55 had no route at all -- so an agent reading the guide never learned that the
world could be made touchable, or that Blender was reachable.

There is now a test that every family appears in some route. The lesson
generalises: the generated half of a document keeps itself honest, the written
half needs a test, and the written half is the half that carries the ordering.

## Building is not looking

`corpus_look` opens built games, **runs them**, photographs and scores them.
`corpus.py` evaluates stages, and a stage is a claim about a pipeline rather than
about a game -- which is how twenty green builds sat beside a screenshot of a
green box.

Two false measurements had to be caught first, and both looked like they worked:

- **Capturing in edit context.** Three different games scored 82.7 with
  byte-identical findings -- 13% clipped, 28% primitive, the same four
  complaints. The frames were empty sky: these games assemble their worlds at
  runtime, so the editor viewport shows nothing and the critic was measuring
  Studio's own UI. Start Play Solo before the shutter.
- **Not passing `viewport`.** `critique_scene` has always taken one and its
  docstring has always said why -- "without it the ribbon and the property panel
  are measured as part of the scene" -- and **no caller in the repository passed
  it**. Cropped, `brambleway` went from 13% clipped to 0.1%: the clipping was the
  toolbar.

**Re-pin after Play Solo.** The session pinned before is the editor. Every call
kept landing there while the game ran beside it, and the capture's own integrity
check caught it: "camera.focus ran in the editor, and this capture was asked for
as gameplay evidence".

**And the crop retired half the exposure axis.** Cropped properly, `last-vigil`
showed 58% of its viewport at pure black -- because it is a night game, by
design. Crushed blacks are now measured as `crushedFraction` and never scored;
only blown highlights are. The test that was supposed to prevent this passed the
whole time, because it dimmed a frame globally rather than building real black.

## A world that moves

`WorldKit.Physics`: ropes, springs, ball sockets, sliders, pushes, holds and
ragdoll. `Interact`'s welds and hinges are rigid; nothing swung or collapsed.

- **Constraints join Attachments, not parts.** One with a nil end installs
  cleanly, does nothing, and looks right in the explorer.
- **Anchored parts ignore every one of them, silently.** First thing to check.
- **Ragdoll is not switching off the Humanoid.** The Motor6Ds keep the body
  rigid, so that gives a statue that topples in one piece. Each Motor6D has to be
  replaced by a BallSocket at the same attachment points.
- **Forces are one-ended.** `VectorForce` has only `Attachment0`, and reporting
  its missing `Attachment1` as a fault made the diagnostic fire on every push --
  which trains you to ignore the list that exists to catch real failures.

## Repath for a reason, not because time passed

Every repath resets the waypoint index to 1. So recomputing on a timer means a
creature **restarts its journey** every interval and can never finish a long
one.

This looked fine for a whole session. A short chase round a wall worked --
100 studs closed, measured -- because each new path pointed the same way. Given
a 100-stud crossing it oscillated within five studs of where it started,
forever, reporting `chase` the entire time.

Repath on: the target moved (`REPATH_DISTANCE`), the waypoints ran out, or
progress stopped. Age is a safety net at 8 seconds, far above a journey, for a
pursuer whose target vanished in a way the other triggers missed.

After the fix, the same creature crossed a gap by `PathfindingLink`: Z -40 to
+43, five studs from its quarry.

**Declare `Costs` or links are invisible.** `PathfindingService` ignores every
`PathfindingLink` in the place unless the agent has a `Costs` table naming the
labels. A creature then refuses to leave its island and reports `unreachable`,
which reads as broken pathfinding rather than a missing declaration.

**Diagnose the path before the movement.** Computing the path directly showed 13
waypoints crossing the gap with two labelled `Jump` -- so pathfinding and the
link were both fine and the bug was downstream. That one check turned a
link-shaped mystery into a general movement bug.

## The compliance surfaces

Two now, and they have the same shape: not taste, enforced.

- **Chat.** Player text shown to another player must be filtered.
- **PolicyService.** Whether *this* player may be shown paid random items,
  offered external links, or allowed to trade -- decided by Roblox per player,
  by age and country. `GameKit.Reach` gates them, and `policy_check` refuses a
  feature that is not gated.

**An unreadable policy denies.** Defaulting to permissive means an outage is the
one moment every restriction lifts. The restrictive default is also not cached,
so a player is not pinned to it once the service returns.

**MemoryStore is not a DataStore.** It expires, and expiry is not an error -- so
an inventory stored there disappears silently. `Reach.shared` requires a
lifetime rather than defaulting one, because a caller who has not chosen has not
understood.

**`PublishAsync` does not deliver to the sender.** A server that updates its own
state only in the subscriber never sees its own change, which looks exactly like
the message never arriving.

## The engine: a library, not a factory

The platform now helps somebody *program* rather than programming for them. The
rule everything here follows: **the library saves time, it is never the only
way.** Every function is Luau you could have written, `sdk_source` hands you the
code to copy, and `run` reaches anything the tools do not.

    Core        Signal Trove Timer StateMachine Zone Spatial Pool Curve
                Events (everything that can happen) Actions (everything you can do)
    Behaviours  doors lifts platforms hazards pickups chests switches
                checkpoints rounds shops health spawners guards turrets teams
    skeletons   obby tycoon survival tower-defense, as readable starting code

`Events` and `Actions` are **open function libraries, not a rule vocabulary**.
The `gameplay_*` DSL still exists as a shortcut; it is no longer the path, and
its validation now takes `force`.

## The loop that was costing a minute an iteration

Adding a module used to mean: write the file, run Rojo, restart Studio, reopen
the place, try again. Measured on this machine, twelve times in one session.

    code_write -> code_reload -> run       0.34s, 41 -> 42, no restart

**Reloading means a new identity.** Roblox caches `require` per ModuleScript
instance forever, so setting `.Source` on a module that has already been
required changes nothing. Reload destroys it and creates a new one with the same
name and parent -- a different instance is a different require key, and that is
the only way to invalidate the cache. Anything already holding the old table
keeps it, and the result says so.

**`code_write` compiles before it writes**, so a syntax error arrives as
`[string "rqe.compile"]:2: Expected identifier ... got 'return'` with a line
number, rather than becoming a module that fails at require time saying nothing.

**`test.run` puts the assertion in the same process as the fact.** 16 checks
over `Core` ran in 4.2ms inside the engine. The Python suite can only check
Python.

## Two things that broke while building it

**A `resolve` that returns the parent when the leaf is missing is right for
reading and wrong for creating.** `ReplicatedStorage.Scratch` resolved to
`ReplicatedStorage`, so every written module landed one level too high and
`code_reload` could not find it. Read and create need different answers to the
same question.

**Search only worked in one language, and failed like an answer.**
`sdk_search("como faco uma zona de gatilho")` returned `Life.health` and
`Physics.ragdoll` -- the doc comments are English. Portuguese terms are now
folded to their English partners and accents stripped, because a search that
silently fails for a whole language is worse than one that refuses.

## Overwriting a file you have not read destroys it

`world_tools.py` already existed. Writing a new module at that path removed six
`world_*` tools, six `scene_*` tools, `ui_click` and the federated input surface
-- and the `.pyc` was regenerated by the failed import a moment later, so both
copies were gone.

It was recoverable only because the implementations live in `rqe/world/` and the
wrapper was thin. **Check that a path is free before writing a new module at
it**, and prefer a new filename over a plausible one.

## Engine limits

Read `docs/platform/ENGINE-FACTS.md` before debugging anything that "should
work". The expensive ones:

- **Prompt exclusivity**: the nearest prompt sharing a key silently suppresses
  the others. Visible, in range, enabled, and impossible to trigger.
- **GUI clicks cannot be synthesised** — refused in LocalScripts *and* plugins.
  Fire the same RemoteEvent the button fires.
- **Client errors are invisible server-side.** Use `client.logs`. A LocalScript
  that dies from a declaration-order mistake takes the whole HUD with it and
  reports nothing.
- **Run mode does not undo what game scripts build.** Reopen the place between
  measurement passes or every count is doubled.

## What "done" means

A build is not done because it runs without errors. That bar produced a map that
passed 35/35 tests and looked like a prototype.

**Function** — the loop completes end to end with an actor, and every step emits
PASS/FAIL. Zero console errors, server and client.

**Structure** — no overlapping exclusive regions; every objective reachable by
navmesh from spawn; nothing below the play volume; instance and memory budgets
met; FPS sampled in a running session.

**Craft** — this is the bar that was missed for most of this project:

- Scale is deliberate. Measure it. A 171×170 map with 38×36 plots reads as a
  diorama; the numbers said so before anyone looked.
- One visual language. Materials, palette and lighting come from `WorldKit`
  themes, not from literals at the call site.
- Restraint with light. Neon and PointLights are additive; a bright flat-colour
  world needs almost none.
- World text appears by proximity. A label is for someone close enough to act.
- Silhouette and landmarks. A player must be able to navigate by looking.
- Density with purpose. Empty ground and cluttered ground are both failures.

**Honesty** — anything unfinished is named, with the reason. A dead button that
looks alive is worse than one labelled unavailable. The Robux store marks
products "indisponível" because their ids do not exist yet; that is correct
behaviour, not a gap to paper over.

## Building the world

Compose from `roblox/lib/WorldKit` — `Palette`, `Build`, `Grid`, `Conveyor`,
`Nature`, `Sky`. It belongs to the platform, not to any one game.

When you need something new, ask whether it is a need of *this* game or a
capability any Roblox production needs. Generalisable things go in WorldKit:
`validateConveyorSystem(config)`, never `validateAnimeCardTycoonConveyor()`.
A 454-line service of literal coordinates is the failure mode to avoid.

Scatter must be seeded. A map that regenerates differently every run cannot be
regression-tested: a screenshot diff would flag the noise instead of the change.

## Every fix earns a guard

When something breaks, the fix is not done until the same failure cannot return
silently. Prefer, in order: a test, a validator, an assertion in a scenario, a
structural rule.

Name the guard after the failure. `test_a_live_edit_session_beats_a_dead_run_session`
says what went wrong; `test_session_routing` does not.

## What the platform still cannot do

State these plainly rather than working around them quietly:

- **The production asset pipeline is not complete yet.** This is a release
  blocker, not a permanent boundary. The target capability covers discovery
  with name/description/license/preview, creation and validation of meshes,
  sounds, animations and icons, idempotent publication through an authenticated
  Roblox account, and automatic integration of the resulting ids into the
  declarative experience definition. If Roblox requires account approval or a
  credential that is unavailable, return an explicit `BLOCKED` publication
  package; never report an upload that did not happen.
- **The scene critic measures absence of greybox, not quality.** It scores 10
  of the 17 named dimensions; three more are measured and deliberately unscored
  because they ranked the reference ladder backwards, an empty green plate
  beating a dense gameplay frame. Calibration is two captures of one game and
  the thresholds are labelled aspirational in its own record. **100/100 means it
  ran out of questions, not that the scene is good.**
- **Only Kenney has a fetchable catalogue.** Quaternius, ambientCG, Poly Haven
  and game-icons are catalogued with licence and coverage, but reach the
  factory through `adopt` rather than `fetch`.
- **Two plugin copies fight silently.** Studio loads every file in the plugins
  folder; a stale `.rbxm` beside a fresh `.rbxmx` answers first and reports
  `E_UNKNOWN_METHOD` for commands the new one implements. `studio install` now
  reports `competingCopies`.
- **No monetisation.** Developer product ids must be created in the owner's
  Creator Dashboard.

## Checklist

Before calling a change done:

- [ ] Measured against a live Studio, not asserted
- [ ] Validation level stated, and it matches what actually ran
- [ ] `client.logs` and `log.tail` both clean
- [ ] A guard exists for anything that was fixed
- [ ] Reusable parts live in WorldKit, not in the game
- [ ] Every production-required asset is discovered or created, previewed,
      provenance-checked, published/approved and integrated; no placeholder is
      allowed to pass the release gate
- [ ] Every PASS states its evidence level; ambiguous instruments returned
      NOT_VALIDATED rather than a verdict about the product
- [ ] The regression corpus still builds 20/20
- [ ] Anything sourced externally has its licence recorded, and CC-BY credits
      reach a screen in the running game
- [ ] Anything unfinished is named with its reason
- [ ] `python -m pytest -q` passes
