# Working in this repository

This is a Roblox game engine (`forge/luau/Forge`, 232 modules), a CLI that
drives Studio (`forge/`), a shelf of finished projects salvaged from real games
(`forge/kits/`), and the games built on all of it (`games/`).

## Before you write a system, ask whether it exists

```bash
python forge/forge.py find "<what you are about to build>"
```

Searches the engine, every game's source, and every kit at once. Ask it with a
sentence, not a filename — `find "hold a weapon in the hand"` works; you are
searching precisely because you do not yet know it is called `Rig.grip`.

This is not a suggestion. In one session an agent hand-wrote a hand-grip
welder, a first-person viewmodel and a joint-by-joint poser, all of which
already existed as `Rig.grip`, `Camera.Viewmodel` and `Forge.Anim` — and then
began writing a zombie system while `forge/kits/infected/` held a complete,
running zombie survival game with three hand-built maps. That cost most of a
day, and one command would have prevented all of it.

- `forge map` — every engine module, one line each ([docs/engine-map.md](docs/engine-map.md))
- `forge kits` — every salvaged project and what is inside it
- `forge api --module <Name>` — one module's full surface

A kit is a **finished game**, not a folder of assets. Read one before
rebuilding what it holds.

## Verify by running, not by compiling

Typing and linting have never caught a real bug in this repo. Running the game
has caught every one.

```bash
python forge/forge.py doctor <game>     # authoring notes, not a gate
python forge/forge.py build <game>
python forge/forge.py gametest <game>   # opens, boots, runs scenarios, prints
python forge/forge.py playtest <game>   # plays it and photographs the screen
```

`gametest` is the cheap loop: no screenshots, finishes in about a second, and
it is what should be reached for first. Scenarios live in
`<game>/src/server/tests/` and register through `Forge.Testing`. The assertion
API is `t:expect(...)` and `t:expectEqual(...)` — colon methods.

End a game's bootstrap with `Debug.ready(name)`. Without it, everything that
photographs or measures the game has to guess when it is up, and a server that
spends twelve seconds carving terrain gets photographed at second two.

## Traps that cost hours and produce no error

These are Roblox behaviours, not bugs in this repo. Every one of them was found
the expensive way.

- **Roblox avatars have no `Motor6D`.** Joints are `AnimationConstraint` paired
  with `BallSocketConstraint`. The usual posing recipe — find the joint,
  multiply its `C0` — compiles, runs, and does nothing. Use `Forge.Anim`, which
  handles both rig kinds, and never write `Humanoid.HipHeight` to fake a pose:
  root height is a term in a physics solve there, and forcing it launches the
  character.
- **Constraint rigs are posed before the physics step, not before the frame.**
  A goal written at `RenderStepped` is thrown away by the solve. `Anim.bind`
  handles this; hand-rolled posers do not.
- **`InsertService` models arrive with `Archivable = false`.** `Clone()`
  silently returns a Model with no parts in it. `Catalog.Place.template`
  normalises this; if you fetch a model another way, do it yourself.
- **Catalogue props are often rigged** — Motor6D, bones, an
  `AnimationController`. A skinned mesh follows its bones, not the CFrame you
  welded it at, so strip the rig before welding one rigidly.
- **Unanchored parts welded across a distance explode the solver.** Build
  anchored, weld, then release. Anything else hands the physics engine a large
  impulse and it answers by throwing the character.
- **`bridge.exec` runs in a different Lua VM than the running game.** Module
  state is not shared; only the DataModel is.
- **A place opened from a local file is always named `"Game"`.** Do not identify
  which project is running by asking Studio.

## House style

Comments explain *why*, in prose, and are worth the space when they record a
decision or a defeat. `--:` for a line, `--[[ ]]` for a block. Match the density
of the file you are editing. Do not narrate what the next line does.

Never write a balance number in two places. If a game has tunables, they live in
one module and nothing else hardcodes them.
