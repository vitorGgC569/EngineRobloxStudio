# Working in this repository

This is a Roblox game engine (`forge/luau/Forge`, 232 modules), a second library
the production pipeline writes against (`roblox/lib`: GameKit, WorldKit), a CLI
that drives Studio (`forge/`), a shelf of finished projects salvaged from real
games (`forge/kits/`), and the games built on all of it (`games/`).

## Start here, in this order

```bash
pip install -e .                  # gives you `forge` and `rqe` as commands
forge preflight                   # is this machine ready; names what is missing
forge find "<what you are about to build>"
```

`preflight` first, always. Every missing piece used to be discovered by running
a real command and failing several frames into it: a missing `numpy` surfaced
inside a visual metric, an uninstalled Studio plugin surfaced as "the bridge did
not return JSON". It answers what is missing and the one command that fixes it.

**Every command exits with a code that says what to do next**, not just `1`:

| | | |
|---|---|---|
| `1` findings | the game is wrong | fix the game |
| `3` environment | the machine is incomplete | `forge preflight` |
| `4` no-studio | nothing is running | `rqe studio restart` · retryable |
| `5` no-credential | a key is missing or too narrow | supply one |
| `6` blocked | **the instrument could not measure** | says nothing about the game |
| `7` conflict | another agent holds the resource | wait, or another checkout |
| `8` upstream | Roblox failed | retry with backoff |

`6` is the one worth learning. A blocked measurement is a failure of the
harness, and reading it as "the game is broken" sends you to debug code that
works. Add `--json` to any command for the same thing as an envelope.

## Where everything else is written down

This file is the index. Nothing below repeats what these say.

| | |
|---|---|
| [docs/engine-map.md](docs/engine-map.md) | every engine module, one line each |
| [docs/architecture.md](docs/architecture.md) | how the halves fit together |
| [docs/game-agent-bridge.md](docs/game-agent-bridge.md) | the 107 bridge commands |
| [forge/CHANGELOG.md](forge/CHANGELOG.md) | what shipped, and what "breaking" means |
| [.claude/skills/build-a-roblox-game](.claude/skills/build-a-roblox-game/SKILL.md) | making a game **with** this repo |
| [.claude/skills/roblox-production](.claude/skills/roblox-production/SKILL.md) | maintaining the repo itself |

## Before you write a system, ask whether it exists

```bash
python forge/forge.py find "<what you are about to build>"
```

Searches four shelves at once — the Forge engine, `roblox/lib`, every game's
source, and every kit. Ask it with a sentence, not a filename — `find "hold a weapon in the hand"` works; you are
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
- `reuse_search` — the same four shelves, over MCP

A kit is a **finished game**, not a folder of assets. Read one before
rebuilding what it holds.

## Verify by running, not by compiling

Typing and linting have never caught a real bug in this repo. Running the game
has caught every one.

```bash
forge doctor <game>      # authoring notes, not a gate
forge build <game>
forge gametest <game>    # opens, boots, runs scenarios, prints
forge playtest <game>    # plays it and photographs the screen
forge inspect <path>     # the live DataModel; --client asks the other side
forge cost [game]        # what production cost: round trips, seconds, restarts
```

Both DataModels are readable through `forge inspect`. Without `--client` it asks
the server; with it, the running client,
which is the only place a viewmodel, a `LocalTransparencyModifier`, or anything
else built client-side exists. Ask the right side: a first-person weapon was
debugged for hours by writing state into a TextLabel and reading it back
through the GUI tree, because the client half had no other way out.

`gametest` is the cheap loop: no screenshots, finishes in about a second, and
it is what should be reached for first. Scenarios live in
`<game>/src/server/tests/` and register through `Forge.Testing`. The assertion
API is `t:expect(...)` and `t:expectEqual(...)` — colon methods.

`forge new` ends a bootstrap with `Debug.ready(name)` and the production
implementer emits it too, so a game announces when it has finished starting.
Keep it last. Without it everything that photographs or measures the game has to
guess, and a server that spends twelve seconds carving terrain gets photographed
at second two.

**Two agents need two checkouts.** There is one Studio, one hub and one port per
machine, and `rqe/workspace.py` takes a cross-process lease on each. A second
agent in the same checkout is refused with exit `7` naming who holds it; in a
second checkout, with `RQE_HUB_PORT` set, it runs alongside.

**The suite is the gate and it can be run.** `pytest -m "not slow"` is 1,534
tests in about three minutes; a bare `pytest` adds the 44 that run a whole
production pipeline. It used to be twelve minutes, so nobody ran it — which is
how six failing tests sat unnoticed for twenty-five commits.

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
one module and nothing else hardcodes them. The same rule holds for the tooling:
a derived hash lives in `rqe/stamps.py` and is cut by `rqe stamp --write`, and
the hub's address comes from `rqe.workspace.hub_url()` — both were duplicated
constants that drifted, and one of them killed a release gate for twenty-five
commits.

Adding a bridge command means **five** places: the plugin handler, the
forwarder, `schemas/bridge-commands.v1.json`, a capability in
`quality/production-capabilities.v1.json`, and a caller. A capability with no
caller is one this repository has shipped before and nobody could reach.
