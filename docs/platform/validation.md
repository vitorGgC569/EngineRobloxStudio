# G. Validation architecture, I. Artifact model

## G. Validation architecture

### The rule that shapes everything

A validator may only produce evidence from a measurement, and every evidence
record names its source. Today `rqe/observe.py` emits `source="studio-bridge"`
while the legacy probes emit `source="headless-runtime"`. A reader — human or
agent — can tell them apart without trusting prose.

### Determinism before vision

Anything computable from geometry is computed from geometry. Computer vision is
reserved for what genuinely requires perception: composition, ambience, finish.

| Question | Method | Not |
|---|---|---|
| Does this rest on ground? | downward raycast grid, per-point gap | looking at a screenshot |
| Do these regions overlap? | AABB intersection, ancestor pairs excluded | eyeballing a top-down render |
| Is a part below the map? | position vs. threshold | vision |
| Is UI off-screen? | `AbsolutePosition` + `AbsoluteSize` vs. viewport | vision |
| Is the lighting flat? | — | **vision** |
| Is the space visually empty? | density heuristics **plus** vision | either alone |

### Validator families

Named for the capability, never for the game (§19). `validateConveyorSystem(config)`,
never `validateAnimeCardTycoonConveyor()`.

**WorldValidator** — ground support, spawn validity, parts below the play volume,
unanchored budgets, bounding boxes, region exclusivity, instance census.
*Implemented and verified for: ground support, spawn existence, below-floor,
unanchored, instance budget, spatial overlap.*

**RegionValidator** (generalises "PlotValidator") — count, unique identity,
non-overlap, spacing, ownership, boundaries. A plot, a zone, an arena and a room
are all "regions that must be exclusive"; the primitive is `world.overlaps` over
a discovered set, not a plot-specific routine.
*Implemented: discovery by tag with name-pattern fallback, top-level filtering,
overlap with separation axis and distance.*

**UIValidator** — clipping, viewport containment, anchors, text legibility,
unreachable buttons, responsiveness, loading/error/empty states.
*Not implemented: needs `gui.tree` (Tier 2).*

**GameplayValidator** — onboarding, progression, economy, cooldowns, purchases,
inventory, upgrades, save/load, multiplayer, reconnect.
*Not implemented against a real game: needs `actor.*` (Tier 2).*

**PerformanceValidator** — startup time, FPS, memory, instance count, script and
physics time, network and replication, RemoteEvent rates.
*Partially implemented: FPS, memory, instance count are measured; per-script and
network breakdowns are not.*

**SecurityValidator** — server authority, payload validation, rate limits,
inserted-model script quarantine.
*Static only today.*

### Findings are actionable, not descriptive

A validator's job ends in something a repair agent can act on:

```jsonc
{
  "severity": "high",
  "category": "spatial_overlap",
  "location": "Workspace.Map.PlotA",
  "finding": "Workspace.Map.PlotA intersects Workspace.Map.PlotB",
  "suggestedAction": "move one region 3.2 studs along X to separate them",
  "evidence": { "overlap": [3.2, 9.26, 36.5], "separationAxis": "X",
                "aRef": "0_452597", "bRef": "0_452634" }
}
```

The separation axis and distance come straight from the measurement, so the
suggested action is derived rather than guessed.

### Scenario tests

The DSL in `contracts/scenarios/*.json` and `GameAgentBridge.run_scenario` is a
sound shape — steps of `walk_to` / `interact` / `assert` / `wait`, each emitting
PASS/FAIL. Its backend is the fixture. The plan is to keep the DSL and replace
the backend with `actor.*`, so scenario authoring survives the transition and
only the truth source changes.

### Scoring gates

The current gate blocks on `critical == 0`, `major == 0`, `gameplay >= 95`,
`persistence == 100`, `multiplayer >= 90`.

It has a defect worth naming (gap G8): **a category with no evidence scores
100**. Absence of proof and proof of correctness are indistinguishable, which is
how the engine reached a perfect score while measuring nothing. The fix is a
coverage requirement — a category must carry a minimum number of runtime-sourced
evidence records before it may score above a floor, and the gate must require
`RUNTIME_VALIDATED` evidence for gameplay, persistence and multiplayer rather
than merely an absence of failures.

Proposed dimensions, to be tightened as coverage grows:

```text
Gameplay ≥ 90    Visual ≥ 85       Reliability ≥ 95
UI/UX ≥ 85       Multiplayer ≥ 90  Persistence = 100
Performance ≥ 85 Architecture ≥ 80 Observability ≥ 80
Content density ≥ 70
CRITICAL failures = 0
```

## I. Artifact model

Every measurement pass is a run with an id, and everything it produced lives
under that id.

```text
artifacts/
  run-00003/
    run.json                     ← status, counts, reproducibility metadata
    runtime-state/
      observation.json           ← full evidence + measurements + findings
    logs/
      studio-output.json         ← structured Output window
    metrics/
      runtime.json               ← FPS, memory, instances
    screenshots/                 ← (reserved; capture not yet wired)
    report/
      summary.md                 ← human-readable derivation of the JSON
```

`reports/latest-observation.json` points at the newest pass.

### Reproducibility

`run.json` records what is needed to re-create the conditions (§25):

```json
{
  "engineVersion": "0.2.0",
  "protocolVersion": "rqe.bridge/1",
  "studioVersion": "0.733.0.7330989",
  "placeName": "MinersRidgeTycoon-qa-v7.rbxlx",
  "commit": null,
  "host": "…", "python": "3.12.10",
  "observeConfig": { "regionTag": "QARegion", "regionNamePattern": "^Plot", … }
}
```

Missing and planned: a world-generation **seed**, so a procedurally generated
map can be regenerated identically. `commit` is null because this working tree
is not a git repository.

### Machine-readable first

`observation.json` is canonical; `summary.md` is derived from it. Reports are
never authored by hand, so a human report can never disagree with the data.

Structured shape:

```json
{
  "runId": "run-00003",
  "validationLevel": "RUNTIME_VALIDATED",
  "studioContext": "run",
  "status": "PASS",
  "counts": { "PASS": 10, "WARN": 0, "FAIL": 0 },
  "measurements": { "studio": {…}, "world": {…}, "runtime": {…},
                    "regions": {…}, "regionOverlaps": {…}, "logs": {…} },
  "findings": [],
  "evidence": [ … ],
  "commandErrors": []
}
```

`commandErrors` matters: a command that failed is recorded rather than silently
skipped, so a partial pass is visibly partial instead of quietly optimistic.

### Regression comparison

With stable run ids and identical evidence shapes, two runs diff directly:
evidence that flipped PASS→FAIL is a regression, findings that disappeared are
fixes, and metrics that moved beyond a threshold are drift. Run `run-00002` →
`run-00003` is a worked example: 48 findings → 0, caused by fixing the validator
rather than the game.
