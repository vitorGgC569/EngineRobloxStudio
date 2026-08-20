# J. Roadmap

Each slice must work end to end before the next begins. A slice is done when it
produces real evidence, not when its code exists.

## P0 — Foundational infrastructure

The layer everything else stands on: a real channel to Roblox.

- [x] Versioned wire protocol with correlation ids, deadlines, error taxonomy
- [x] Bridge Hub: handshake, long-poll, result correlation, event buffer
- [x] Studio plugin: dispatcher, typed commands, reconnect with backoff
- [x] Stable instance refs (`GetFullName` is not unique)
- [x] Session routing by liveness and `clientId` supersede
- [x] Deterministic simulation control (`run.start` / `run.stop`)
- [x] Runtime telemetry: FPS, memory, instance counts, structured logs
- [x] Geometric primitives: raycast, bounds, ground support, region overlap
- [x] Artifact tree with run ids and reproducibility metadata
- [x] Transport test suite on real sockets (16 tests)
- [x] Unattended Studio lifecycle: stop, archive auto-recovery, clear lock,
      launch, wait for a new session
- [x] Measurement-integrity guard: refuse to measure a place a previous run
      already generated a world into
- [ ] Session lease so parallel agents cannot corrupt one another's runs
- [ ] Seed capture for reproducible world generation
- [ ] Retire fixture-backed probes, or mark them `STATICALLY_VALIDATED`

## P1 — Gameplay automation

Make the agent a player.

- [x] `play_solo` — a real Player and character (one real keystroke; Studio
      ignores synthesised input)
- [x] `actor.spawn` — a physical R15 rig with real physics, no Player needed
- [x] `actor.attach` — drive the real player's character
- [x] `actor.walk_to` (straight line) and `actor.navigate_to` (navmesh waypoints)
- [x] `actor.interact`, `actor.touch`, `actor.jump`, `actor.prompts`
- [x] `world.path` — objective reachability, with a navmesh control probe
- [x] Client instrumentation bridge: prompt activation and GUI access, reached
      through the server with `RemoteFunction:InvokeClient`
- [x] `client.gui_tree` with `AbsolutePosition`/`AbsoluteSize` and off-screen flags
- [x] Scenario DSL repointed from the fixture to the real game
- [x] The §5 opening loop, end to end, including purchase idempotency
- [ ] The rest of the §5 scenario: place item → confirm income → leave → rejoin
      → confirm persistence
- [ ] `client.gui_click` exercised against a real button
- [ ] Per-run log windows instead of whole-session history
- [ ] UIValidator and GameplayValidator as validators, not just commands

## P2 — Visual validation

- [ ] `capture.screenshot` paired with `camera.get`, stamped with run id,
      scenario, step, resolution and camera pose
- [ ] Named viewpoint sets: map overview, each region, plaza, interiors, UI
- [ ] Multiple resolutions and aspect ratios
- [ ] Replace synthetic PIL renders with real frames; keep them only as
      explicitly-labelled schematics
- [ ] Semantic visual QA: floating/buried objects, clipping, gaps, lighting,
      empty terrain, cropped UI, illegible text, scale inconsistency, composition
- [ ] Automatic failure evidence capture on any FAIL
- [ ] Performance profiling beyond FPS: per-script, physics, network, replication
- [ ] Environment separation for DataStores, monetization, analytics (§21, G7)

## P2A — Production asset pipeline

This is a stopping criterion for the industrial game factory, not optional
polish. A campaign cannot finish while a production-required mesh, sound,
animation or icon remains an untracked placeholder.

- [ ] Search approved existing assets by typed query and return stable id,
      creator, name, description, type, license/usage status and preview images
      when Roblox exposes them
- [ ] Rank candidates against the experience definition and preserve the
      complete query/result/selection receipt instead of silently choosing an id
- [ ] Create or ingest mesh, audio, animation and icon source packages through
      deterministic, type-specific validation and preview generation
- [ ] Quarantine every imported model before integration; inspect scripts,
      descendants, external references, budgets and provenance
- [ ] Publish idempotently through authenticated official APIs, recording owner,
      request hash, operation id, resulting asset id and moderation state
- [ ] Treat missing credentials, account approval, moderation or unavailable
      Roblox capability as explicit `BLOCKED`, with a ready-to-publish package
- [ ] Integrate published ids through the declarative asset registry; game code
      must not accumulate untracked numeric literals
- [ ] Release gate rejects `production-required` placeholders, rejected assets,
      stale previews, unknown licenses and source/published-content hash mismatch
- [ ] Fake-provider contract tests plus credential-gated live tests cover
      search → preview → select/create → validate → publish → integrate

## P3 — Autonomous repair loops

- [ ] Root-cause linkage: finding → owning file → responsible agent
- [ ] Repair proposal with a justification for **why** this change
- [ ] Mandatory regression artifact per fix: test, validator, assertion or
      scenario (§18)
- [ ] Automatic regression diff between consecutive runs
- [ ] Loop termination conditions and an iteration budget — never a blind loop

## P4 — Multi-agent production

- [ ] Task graph with declared file ownership and `blockedBy`
- [ ] Git worktree isolation per implementation agent
- [ ] Studio session leasing for mutating commands
- [ ] Integration agent and ReviewerAgent gates
- [ ] Post-merge re-measurement as a required step

## P5 — Industrial scaling

- [ ] Multiple concurrent Studio instances, one hub
- [ ] Real multi-client sessions: 2, 4, and a reasonable maximum
- [ ] Race conditions, ownership contention, replication assertions
- [ ] Specification → release-candidate pipeline driven from a prompt
- [ ] Cross-project validator library that grows with every game shipped
- [ ] Coverage-aware gates: a category may not score 100 without evidence

## Sequencing rationale

P1 before P2 because a screenshot of a world no agent can act in only proves the
world renders. P2 before P3 because a repair loop without visual evidence
optimises for what is measurable and lets the game look wrong. P4 last among the
build phases because parallelism multiplies whatever correctness already exists —
including its absence.
