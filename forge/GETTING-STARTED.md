# Forge, in one sitting

A game engine for Roblox whose intended user is an agent, and whose one rule
is that it never writes gameplay. It gives you rigs, animation, damage,
pathfinding, netcode, persistence and a way to prove any of it still works.
What the game *is* stays yours.

If you read nothing else, read the last section. The measurement loop is the
part of this project that is unusual; everything above it is a library.

---

## Five minutes

```bash
forge new mygame              # scaffold a project wired to the engine
forge doctor mygame           # authoring checks over its Luau
forge build mygame            # rojo build -> mygame.rbxlx
```

Open the place, press Play. The scaffold ships a live suite that runs on
bootstrap and publishes a report:

```bash
forge gametest                # read what the running game just proved
```

That command is the point of the whole project. It answers "does the game
still work" without a person watching a screen.

---

## Where things live

```
src/shared/     Config and Content — every number the game balances on
src/server/     systems/ — your gameplay, one module with a start() each
src/server/tests/   scenarios that run inside the live game
src/client/     input, feel, HUD
```

The rule the scaffold enforces by shape: **no system is a template of a
genre.** Forge supplies the arc query and the damage pipeline; whether a third
combo hit does more is a decision, and decisions live in your game.

---

## Finding the API

Do not read 30,000 lines of Luau. Two commands:

```bash
forge api                     # writes forge/catalog/api.json
forge api --module Anim       # print one module's surface
forge example Combat          # run that module's example and see the result
```

`api.json` carries every module, every public function, its signature, its
summary and its usage examples — generated from the source, so it cannot drift
into fiction. `examples` in that file lists which modules have a demonstration
you can execute.

`forge example` runs them for real, inside Studio, in about a second. An
example that has rotted fails there rather than in your hands.

---

## The modules you will reach for first

| | |
|---|---|
| `Rig` | characters built from a table, R6 or R15 |
| `Anim` | procedural clips, markers, layers, root motion |
| `Combat` | damage pipeline, hitboxes, status, projectiles |
| `Weapon` | cadence, spread, ammo, reload, recoil |
| `Actor` | state machines, perception, population |
| `Nav` | real pathfinding, repathing, stuck detection |
| `World` | heightfields, painting, scatter |
| `Catalog` | 200 verified Creator Store models, script-free |
| `Save` | profiles that migrate, checksum and roll back |
| `Net` | a declared wire contract with rates and shapes |
| `Netcode` | prediction, reconciliation, lag-compensated rewind |
| `Testing` | scenarios inside the live game |

The rest — `Feel`, `UI`, `Input`, `Audio`, `Visual`, `Weather`, `Destruction`,
`LiveOps`, `Telemetry`, `Monetization`, `Editor`, `Scene`, `Streaming` — are in
`api.json` with the same treatment.

---

## Things that will bite you

Written down because each one cost this project real time.

**Ask before you write.** `Capability.set` writes a property if this Roblox
build has it and records the miss if not. `Terrain.Decoration` does not exist
on every build and `MaterialVariant.BaseMaterial` is plugin-only; a bare
assignment to either throws and takes out every line after it.

**Never invent an asset id.** `forge assets verify` loads every id your game
references inside Studio and the doctor refuses any that is not in the
registry. Three separate sets of ids in this project were written from memory
and none of them worked.

**Do not yield while a module is being required.** `Net.on` resolves its remote
with `WaitForChild`, which yields; calling it at a module's top level suspends
the `require` and the loader answers "cannot resume non-suspended awaiting
coroutine" — killing the whole script.

**R6 has six joints and R15 has fifteen.** Elbows, knees, wrists and ankles
exist only on R15, so anything posed with `IK` or written against
`rightForearm` silently does nothing on an R6 rig. `Anim.CORE` is the six every
rig has.

---

## Publishing

```bash
forge publish mygame          # a private Saved version
forge publish mygame --release   # push it live
```

Open Cloud can upload a version to an experience that already exists; it
cannot create one. Make the experience once in Studio, then this owns every
push after it. The key comes from `ROBLOX_OPEN_CLOUD_KEY` and never appears in
an argument or a log.

---

## The measurement loop

This is the part worth copying even if you never use the engine.

Every static check in this project — the compiler, the doctor, the unit tests
— reads source, and source cannot tell you whether an attack lands. So the
engine has four ways to be *run*:

```bash
forge example                 # every module's demonstration, ~1s, edit mode
forge pose bow_draw           # pose a clip and report joint angles + hand distance
forge gametest                # scenarios inside the live game
forge assets verify           # load every asset id and record the verdict
```

Each one found real bugs that every static check had passed over: a netcode
function with no body, an animator that resolved no joints, a pathfinding
layer that had never computed a path, a leg measured from the wrong bone.

Write scenarios that assert **rules**, not numbers. "Armour reduces damage" is
true next month. "A husk takes exactly 14" turns every tuning pass into a red
build, and a suite people route around is worse than none.
