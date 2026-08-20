# The authoring SDK

The gate answers *is this broken*. This is the other half: the layers that
**build**. Read [ENGINE-PLAN.md](ENGINE-PLAN.md) for why the split exists and
[AUTHORING-RESEARCH.md](AUTHORING-RESEARCH.md) for what the platform permits.

## The spine

**Every SDK module is pure Luau with no Studio-only dependency in its core**, so
the same code runs in three places:

| Surface | How | Good for |
|---|---|---|
| Studio plugin | the bridge | interactive work, screenshots, plugin privileges |
| Published experience | shipped in the game | what the player actually gets |
| Headless Luau | `rqe.luau_harness`, or an Open Cloud task | CI, simulation, no machine needed |

This is checked, not asserted. `tests/test_sdk_runtime.py` executes the SDK
under the pinned Luau CLI with a deliberately partial engine shim. A module that
reaches for a service the shim does not provide **fails loudly** — that is the
intended result, because it means the module is not portable.

```bash
python -m unittest tests.test_sdk_runtime
```

## Layers

```
L0  Tokens      art direction as data          tokens/*.json
L1  Build/Grid  primitives                     WorldKit
L2  Fab         fabrication (CSG, editable)    WorldKit
L3  Kit         modular kits                   WorldKit
L4  Blockout    greybox grammar                WorldKit
L5  Mood/Sound/Camera   presentation           WorldKit
L6  Ui / GameKit        interface and systems  WorldKit, GameKit
L7  Templates   genre composition              Templates
```

### L0 — Tokens

`tokens/<id>.json` is the **only** place an art-direction number may live. The
Luau builder and the Python quality engine read the same file, which is what
makes a spec fitted to its own candidate structurally impossible.

```lua
local raw = require(ReplicatedStorage.Tokens.brickfarm)
local tokens = WorldKit.Tokens.define(raw)
local wall = tokens:swatch("structurePrimary")
```

```python
from rqe.tokens import load_token_set, derive_visual_thresholds
tokens = load_token_set(root, "tokens/brickfarm.json")
thresholds = derive_visual_thresholds(tokens)   # every number a rule may use
```

A token set carries **provenance**. `derivation: external-reference` must cite
hashed frames, and `external_reference_issues()` proves those frames are not the
candidate wearing a hash. `measured-from-candidate` is not a legal value.

Loading validates more than shape: stairs taller than the character can step,
doors shorter than the character, corridors too narrow for two abreast, accents
over their coverage budget, a palette with no lightness spread, too many hue
families. All refused at load, in both languages.

### L2 — Fab

Geometry boxes cannot make. **Capability is detected, never assumed**, and every
call returns `(result, receipt)`.

```lua
local wall, receipt = Fab.aperture(wall, {
    { offset = Vector2.new(0, -4), size = Vector2.new(8, 11) },
})
if receipt.status ~= "ok" then
    -- receipt.fallback names what ran instead; receipt.reason says why
end
```

`Fab.summarise(receipts)` folds a whole build into one verdict, so a caller can
ask "did anything silently come out worse than asked for" without reading every
line.

Editable mesh and image creation is memory-budgeted and returns `nil` when
exhausted. `Fab` null-checks, tracks live handles against a ceiling, and
`Fab.release` frees the slot. A leaked editable makes some later unrelated
creation fail, so release is not optional housekeeping.

### L3 — Kit

The professional unit of work is the kit, not the part. A kit declares a **cell**
grid, **modules** with footprints in cells, **variants**, and a scale contract
validated against the token grammar *before anything is built*.

```lua
local kit = Kit.define({ id = "farmstead", cell = Vector3.new(16, 16, 16), modules = {...} }, tokens)
kit:ring(parent, "wall", Vector3.new(0,0,0), Vector3.new(4,0,4))
```

Variation is seeded from `(kit id, module id, cell)`, so the same build produces
the identical world every time — which is what makes a screenshot diff mean
anything. `Kit.variantSpread` reports whether a kit is being used as a kit or as
a stamp.

### L4 — Blockout

Greybox first: build the level in simple shapes, prove it plays, then spend on
art. `Blockout.validate` answers the expensive questions as arithmetic and graph
connectivity, before a single part exists:

- do regions overlap or contain one another
- is every region reachable from spawn
- is a corridor narrower than the grammar allows
- is a landmark too short, or too far from where it must orient

Discovering "the shop is unreachable" here costs nothing. Discovering it from a
live pathfinding failure costs a whole measurement run.

### L5 — Presentation

`Mood.apply(tokens, "farm-noon")` sets lighting technology, atmosphere, clouds,
sky and the five post effects from one token preset. Idempotent: it sweeps what
it previously created, because two stacked ColorCorrections produce a look
nobody chose. Costs nothing in assets or moderation, and is the largest single
contributor to whether a screenshot reads as professional.

`Sound.mixer` builds the AudioAPI node graph from the token bus definitions, with
a declared classic-`Sound` fallback. The multiplier matters here: uploaded audio
is bottlenecked on moderation, and a routing graph turns few samples into a full
soundscape.

`Camera.frame(tokens, profile, subject)` composes a shot from the subject's own
bounds, so a viewpoint survives the world moving underneath it. This is both the
genre camera language and the source of deterministic capture viewpoints.

### L6 — Ui and GameKit

`Ui` is a design system on Flexbox driven by tokens. Three measured defects are
impossible rather than documented: layouts always set `SortOrder = LayoutOrder`
and children always get an explicit order; `AutomaticSize` is used as the flex
basis; helpers are declared before use.

`GameKit` runs the game:

- **`Economy`** — one function for every currency movement. Atomic read-compare-write,
  analytics emitted from the same place, and a ledger that a headless simulation
  can replay.
- **`Save`** — session-locked profiles over `UpdateAsync`, with heartbeat,
  autosave, stale-lock takeover and `BindToClose`. Plain `GetAsync`/`SetAsync` is
  how Roblox games duplicate items and lose hours.
- **`Progression`** — the ladder, plus `pacing`, which computes time-to-tier from
  an income curve with **no game running**.
- **`Analytics`** — funnel, economy and custom events, validated locally because
  the service silently drops malformed ones.

### L7 — Templates

A template composes L0–L6 from a compact definition and owns no geometry, no
colours and no thresholds.

Two ship, and the second exists as evidence rather than as a feature:

| | Tycoon | Defense |
|---|---|---|
| topology | grid of private plots around a hub | one shared radial arena |
| progression | linear cost ladder | escalating wave ladder |
| income | idle, owned by the player | burst, per wave cleared |
| space | partitioned | contested |

`Templates.differ(a, b)` compares structural signatures. If two genres produce
the same signature, one is the other renamed and the generality claim is not
evidenced.

## Running the SDK headlessly

```python
from rqe.luau_harness import run_or_raise

result = run_or_raise(
    root,
    libraries=["roblox/lib/WorldKit", "roblox/lib/GameKit", "roblox/lib/Templates"],
    body=luau_source,
    data={"TOKENS": token_dictionary},
)
```

`data` entries become Lua globals, so the same catalogue the game ships is the
one the simulation reads.

## Gates

```bash
python -m rqe.luau_check --root .      # every Luau file must compile
python -m unittest tests.test_tokens   # token discipline, both languages
python -m unittest tests.test_sdk_runtime   # the SDK executed outside Roblox
```

The compile gate exists because Rojo packages sources without parsing them: a
place can build cleanly from Luau that never runs, and this repository has
already lost a HUD that way with no error anywhere.

## What the harness has already caught

Written down because a gate nobody has seen fail is a gate nobody should trust.

| Defect | Consequence if shipped |
|---|---|
| `Tokens.deepFreeze` recursing into shared tables | `table.freeze` errors on the second visit; token loading dies |
| `Economy:balance` re-seeding on a zero balance | infinite money — twenty purchases from a wallet that could afford three |
| A helper referenced above its own definition in `Sound` | works until something calls it during module load, then kills the module silently |
