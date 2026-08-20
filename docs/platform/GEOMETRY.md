# The geometry authoring runtime

An LLM should not be building meshes vertex by vertex through text, and it
should not be limited to what Studio can assemble out of parts. This layer turns
Blender into a headless modelling runtime the engine commands.

```
brief  ->  program  ->  Blender  ->  analysis  ->  validation  ->  renders
              ^                                                      |
              +----------------------- revision --------------------+
```

The agent writes a **program** and never sees `bpy`.

## Why a program and not a script

An agent could emit Python for Blender to run. It would work and it would be the
wrong shape, for three reasons:

- **Nothing can check a script before it runs.** A program is data, so a
  reference to an object that does not exist yet is caught with the step index
  and the list of live objects — before Blender starts.
- **A revision cannot be diffed.** Two generated scripts differ everywhere. Two
  programs differ in the steps that changed.
- **An asset whose provenance is "some script we no longer have" is not
  reproducible.** The program is stored in the package, so the same program run
  again produces the same geometry.

## The vocabulary

28 operations, shaped like how a modeller describes work rather than like the
Blender API.

| Group | Operations |
|---|---|
| primitives | `box` `plane` `cylinder` `cone` `sphere` `torus` |
| transforms | `translate` `rotate` `scale` `origin` |
| topology | `bevel` `extrude` `inset` `solidify` `subdivide` `remesh` `smooth_shade` `triangulate` |
| composition | `boolean` `array_linear` `array_radial` `mirror` `duplicate` `join` `delete` |
| surface | `uv_unwrap` `material` |
| budget | `decimate` |

Anything Blender can do that is not on this list is not reachable by an agent.
That is intentional: the surface is the contract.

```json
{
  "id": "industrial_generator",
  "result": "generator",
  "steps": [
    {"op": "box", "name": "base", "size": [4.0, 3.0, 1.5], "location": [0, 0, 0.75]},
    {"op": "bevel", "target": "base", "width": 0.08, "segments": 2},
    {"op": "cylinder", "name": "reactor", "radius": 0.9, "depth": 4.0, "location": [0, 0, 3.5]},
    {"op": "box", "name": "vent", "size": [0.25, 0.9, 0.5], "location": [1.05, 0, 2.2]},
    {"op": "array_radial", "target": "vent", "count": 6, "axis": "Z", "centre": [0, 0, 2.2]},
    {"op": "join", "name": "generator", "targets": ["base", "reactor", "vent"]},
    {"op": "uv_unwrap", "target": "generator", "method": "smart"},
    {"op": "material", "target": "generator", "slots": [...]},
    {"op": "decimate", "target": "generator", "triangleBudget": 8500}
  ]
}
```

### What the compiler refuses

- an operation on an object that does not exist **at that point** in the program
- an object that survives the program but is not the result — leftover
  scaffolding exports with the asset, and a mesh that quietly contains its own
  cutting tool is a defect nobody notices until it is in the game
- a triangle budget above Roblox's 20,000 ceiling
- unknown parameters, so a misspelled option is not silently ignored

## The brief

The brief is the intent and stays fixed; the program is the attempt and changes
between revisions. When the critic says the base reads too heavy, the *program*
changes and the result is still measured against the same brief.

```json
{
  "id": "industrial_generator",
  "dimensions": [4.0, 5.5, 4.0],
  "style": "stylized sci-fi",
  "silhouette": "wide base with vertical reactor",
  "materials": ["painted_metal", "emissive_blue", "dark_rubber"],
  "triangleBudget": 8500,
  "gameplayRole": "machine"
}
```

`silhouette` is required, because it is what a visual critique scores.
References must carry a content hash — a citation nobody can check is
decoration.

## Backend selection

One tool does not suit every asset. `choose_backend` decides and says why:

| Asset | Backend |
|---|---|
| simple crate, vegetation, collectible | `procedural_model` |
| modular building, walls, roofs | `worldkit` |
| rock, cliff, outcrop | `roblox_editable` |
| stylised machine, hero asset, statue, character | `blender` |

A budget below ~400 triangles reroutes away from Blender whatever the role:
triangles go on the silhouette first, and below a floor there is nothing left
for detail.

## The asset package

A `.glb` on its own is not enough. An asset that cannot be inspected before
publishing is an asset published on faith.

```
asset-<id>/
  source/program.json        the program that produced this
  project/<id>.blend         so a human can open and continue it
  export/<id>.glb, .fbx
  previews/front|back|left|right|perspective.png
  analysis/topology|validation|dimensions|materials|brief.json
  manifest.json              every file hashed, plus a content hash
```

The content hash is a hash over the file hashes, so *"did this revision change
anything"* is answerable without opening Blender — which is the failure mode
when an agent revises a program and the change had no effect.

## Validation

Measurement runs inside Blender (`blender/analyse.py`) and carries no
thresholds. Policy runs on the engine side (`validation.py`). A validator that
carries its own limits into the tool that produces the artefact grades itself.

| Severity | Meaning |
|---|---|
| `blocking` | Roblox will reject it, or the asset is unusable |
| `major` | It will import and it is wrong |
| `minor` | Worth fixing, will not stop anything |

Blocking: NaN coordinates, zero triangles, over budget, degenerate faces,
non-manifold edges, disagreeing normals, duplicate faces, missing UV, a
map-sized mesh, more than one object in the export.

Major: n-gons, zero-length edges, loose geometry, duplicate vertices, inside-out
normals, too many material slots, unapplied scale, an origin outside the
geometry.

## The visual critic

Validation answers "will Roblox accept this mesh". It cannot answer "is it worth
looking at", and those are different questions: a watertight, under-budget,
correctly-unwrapped cube passes every check above and is still a cube. So the
renders are read back and scored on three axes.

| Axis | Weight | Measured as |
|---|---|---|
| Silhouette | 0.42 | Isoperimetric quotient of the outline, vertical mass balance, front-vs-side distinctness |
| Material separation | 0.28 | Luminance spread across the surface, and whether anything reads as a focal point |
| Detail distribution | 0.30 | Interior edge density, and the spread of it across views |

Approval needs both halves, and the two failures are reported separately.
`BLOCKED` goes back to a human; `REVISE` goes back to the modeller with concrete
changes phrased in the operation vocabulary — "narrow the base, or raise and
enlarge the upper form", not "the composition is weak".

### Where the thresholds come from

A ladder of four assets built by this same pipeline, ordered worst to best *by
construction* before anything was measured: a bare cube, the same form
articulated into three volumes, that form again with three contrasting
materials, and a detailed machine with ribs, vents and pipes. A bare cube is
definitionally an unmodelled asset — if a metric cannot separate it from the
machine, the metric is wrong.

| Metric | cube | articulated | + materials | detailed |
|---|---|---|---|---|
| Silhouette shape | 1.36 | 2.05 | 2.05 | 2.65 |
| Luminance spread | 28.6 | 28.8 | 71.0 | 72.0 |
| Focal contrast | 40.8 | 31.8 | 71.2 | 97.0 |
| Edge density | 0.0064 | 0.0288 | 0.0295 | 0.0478 |
| View balance | 0.06 | 0.64 | 0.88 | 0.79 |
| **Overall** | **65.2** | **80.0** | **93.9** | **100** |

Each rung moves only the axis it was built to move: the third differs from the
second in materials alone, and only `material_separation` changes (47.2 → 96.9).

Three metrics originally proposed for this module — frame coverage, distinct
tone count, empty-cell count — failed to order the ladder and are measured and
reported but **not scored**. Coverage in particular is set by where the renderer
puts the camera, not by the asset; scoring it would grade the harness and call
it the asset. Which metrics were dropped is recorded in `CALIBRATION` rather
than quietly forgotten.

### Three things this got wrong first

**Bands invented from intuition.** The first thresholds were guesses, and real
assets missed them by 10x. They were replaced by the ladder, not by adjusting
them until the candidate passed — a bar fitted to its own candidate is not a
bar.

**Colour-keying the background.** A grey asset against a grey backdrop punched
holes through its own shadowed faces, and the critic measured the holes: a bare
cube came back with a *more complex* silhouette than a ribbed machine. Renders
now use transparent film, so the mask is exact and nothing is inferred. Studio
screenshots have no alpha, so the colour-key path remains as a labelled
fallback.

**Fixed edge threshold.** Dark materials compress every gradient on them, so the
detail measure was reading how light the palette was. Two ladder rungs with
identical geometry scored 2x apart. The threshold now follows local surface
brightness, and those two rungs land within 2% of each other.

## A defect the critic found before it shipped

Building the calibration ladder surfaced a real bug in the runtime: `op_material`
appended material slots but never assigned any face to them. In Blender every
polygon keeps `material_index` 0, so an asset declaring three materials rendered
entirely in the first one — while the manifest reported three. A receipt that
overstated the artefact, which is the failure this project exists to prevent.

Fixed in three places: `material` steps take an `assign` index and paint the
faces; the analysis reports `materialSlotsUsed` and `unusedMaterials` alongside
the declared count; and validation raises `material-unused` when a slot reaches
no geometry.

## The revision loop

```
build -> critique -> revise -> build -> ...
```

`GeometryPipeline.refine` runs the loop; it does not invent the geometry. A
`reviser` callable is handed the critique and the program that produced it and
returns the next program, because deciding that a narrower base means scaling
*this* box rather than *that* one is modelling, and a pipeline that guessed at
it would be authoring blind.

Two guards, both for failure modes that are invisible in a final score:

- A program already built stops the loop (`stoppedBecause: "unchanged"`). Without
  it the loop burns its budget re-rendering one asset and reports the same score
  three times as though it had tried.
- `regressedAt` names any revision that scored *worse* than the one before it,
  and `best` returns the highest-scoring attempt rather than the last one. A
  revision can make an asset worse, and returning the final attempt regardless
  would ship a regression the loop itself measured.

Verified end to end against real Blender: revision 1 `REVISE` at 79.97 with the
finding "reads as a single flat value, no focal point", a reviser acting on that
specific finding, revision 2 `APPROVED_FOR_IMPORT` at 93.88.

## Two convention traps, both found by running it

**Blender resolves relative paths against its own base.** A relative output
directory made Blender write renders to `C:\.tmp\...` — the drive root. It
reported success, returned the paths it was given, and the files were nowhere
near them. Every path handed to Blender is now absolute, resolved at the worker
boundary.

**Blender is Z-up; Roblox is Y-up.** A brief asking for a 6-stud-tall reactor
was silently compared against a depth. The analysis now reports both
conventions explicitly (`dimensions` and `dimensionsYUp`), and everything
comparing against a brief uses the Y-up figures — the same convention the
exported glTF uses.

## Tools an agent sees

```
mesh_vocabulary   the operation surface, before writing a program
mesh_brief        state the intent, find out which backend suits it
mesh_build        execute a program, get an asset package back
mesh_inspect      topology, dimensions, materials, integrity
mesh_validate     Roblox's rules against any mesh file
mesh_previews     render paths, for the visual critic
mesh_compare      what changed between two revisions
visual_score      score the renders, get concrete revisions back
visual_thresholds the bar, and the ladder it was calibrated on
```

Not `bpy.ops.mesh.foo(...)`. Nothing here publishes: publishing is irreversible
and does not belong inside a loop.

## Running it

```bash
python -m unittest tests.test_geometry
```

```bash
python -m unittest tests.test_visual_critic
```

56 geometry tests and 17 critic tests. 11 of the geometry tests drive a real
headless Blender; they skip loudly and by name when none is installed, and
`test_the_worker_reports_its_own_absence` verifies the absence is reported
rather than swallowed.

The critic tests need no Blender: they build synthetic frames from primitives
with known properties — a flat square has no interior detail by construction, a
striped one has a lot — so each assertion has a reason that does not depend on
what is installed. The ones that matter are structural rather than arithmetic:
that no renders raises instead of scoring zero, that a flat square is never
approved, that a dark palette is not mistaken for a lack of modelling, and that
the reference ladder still orders.

Blender is discovered from `BLENDER_PATH`, `PATH`, then the usual install
locations, newest first. Minimum 3.6.

### Re-checking the calibration

```bash
python tools/critic_calibration.py
```

Rebuilds all four rungs and prints what they measure now against what is
recorded in `CALIBRATION`, then exits non-zero if the ladder no longer orders. A
calibration that cannot be reproduced is a claim rather than evidence, and a
drift in Blender, in the render settings or in a metric would otherwise surface
as a run of assets that all quietly scored 90.
