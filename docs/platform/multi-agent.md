# H. Multi-agent architecture

## Domains, not micro-agents

An agent owns a domain large enough to hold context (§15). Splitting work per
operation destroys the understanding that makes the work good.

| Agent | Owns (files) | Owns (bridge surface) |
|---|---|---|
| WorldAgent | `src/**/Services/MapService.lua`, terrain, props | `world.*`, `camera.*` |
| GameplayAgent | `Services/{Store,Plot,Progression}.lua` | `run.*`, `actor.*` |
| UIAgent | `StarterPlayer/**`, GUI modules | `gui.*`, `camera.*` |
| EconomyAgent | `Shared/{GameConfig,CardCatalog,FloorCatalog}.lua` | `run.state`, `data.*` |
| DataAgent | `Services/PersistenceService.lua` | `data.*` |
| QAAgent | `contracts/scenarios/**`, `tests/**` | everything, read-only |
| PerformanceAgent | none (advisory) | `run.state`, `world.summary` |
| SecurityAgent | none (advisory) | `dm.*`, scanner |
| ReviewerAgent | none | reads artifacts only |

Advisory agents own no files. They produce findings; the owning agent applies
the change. This keeps one writer per file without blocking analysis.

## Conflict control

**File ownership is exclusive and declared.** A task carries the paths it may
write. The orchestrator rejects a task whose write set intersects an in-flight
task's write set.

**Git worktrees for parallel implementation.** Each implementation agent works in
its own worktree, so edits never interleave in one tree. Integration is a
deliberate merge step by an integration agent, not a race.

**The bridge is a serialized shared resource.** There is exactly one Studio and
one DataModel. The hub already serializes commands per session, but semantic
conflicts remain: one agent calling `run.stop` while another is mid-measurement
corrupts both. Required: a **session lease** — an agent acquires the Studio for a
run, and mutating commands (`run.start`, `run.stop`, `bridge.exec`, `camera.*`)
are rejected without the lease. Read-only commands stay concurrent.

This is not yet implemented and is the main prerequisite for P4.

**Dependency graph over task list.** Tasks declare `blockedBy`. World generation
precedes region validation; economy precedes progression tests. The orchestrator
walks the graph and only parallelises independent branches.

## Shared state

Agents communicate through structured artifacts, never by narrating to each
other:

```text
artifacts/run-NNNNN/runtime-state/observation.json   ← what is true now
artifacts/run-NNNNN/report/summary.md                ← derived, for humans
tasks/<id>.json                                      ← intent, ownership, status
```

A repair agent consumes `findings[]` — each already carrying a location, a ref,
and a derived suggested action — and returns a patch plus the scenario or
validator that prevents the regression (§18).

## Review before integration

No agent merges its own work. The sequence is:

```text
implement → static validators → build/sync → measure (bridge)
   → validators → ReviewerAgent → integrate → re-measure → regression diff
```

The re-measure after integration is not optional: a change that passes in
isolation can still break the composed place, and only a post-merge measurement
catches that.

## Failure isolation

An agent that cannot complete its task must fail loudly and leave the artifact
tree consistent. The pattern already used by `_Collector` in `rqe/observe.py`
generalises: record the failure in `commandErrors`, continue collecting what is
still collectable, and mark the pass as partial. A partial measurement with an
explicit gap is useful; a measurement that silently omitted its failures is
worse than none.
