# RQE Game Factory charter

## Product boundary

The product of this repository is a reusable, agent-operated Roblox production
engine.  A game checked into the repository is a consumer, integration fixture
and source of new engine facts.  It is never the implicit specification of the
engine and it is never the only acceptance test.

The repository therefore has three distinct layers:

1. **Factory platform** — control plane, Studio bridge, agent protocols,
   contracts, validators, asset pipeline, quality evaluation, artifacts and
   release authority.  It must not contain product-specific names or rules.
2. **Project definition** — a versioned declarative package for one experience:
   product intent, reference benchmark, progression/economy/world/presentation
   model, asset needs, scenarios, device/viewpoint matrix and quality policy.
3. **Produced experience** — Luau, places and published content generated or
   integrated by specialized agents from that definition.

The first game exercises the factory.  A defect found while producing it earns
a reusable primitive, validator, command or reproducer.  A one-game workaround
does not count as platform progress.

## Factory contract

Given a valid project definition, the engine owns this state machine:

```text
specify -> plan -> design -> build -> integrate -> run -> inspect -> play
        -> capture -> evaluate -> repair -> impacted regression
        -> full regression -> release candidate
```

Every transition emits an immutable, hash-bound artifact.  Every factual claim
states its validation level.  A task can finish as `BLOCKED`, `INFRA_FAILED` or
`INCONCLUSIVE`; budget exhaustion, missing evidence and unavailable external
authority are never success.

The engine coordinates specialized agents.  It does not hard-code the game
those agents should build.  Agents receive bounded task inputs, ownership,
resource leases, completion checks and required artifact references.  The
implementer cannot approve its own release.

## Genericity invariants

- `rqe/`, the Studio plugin, shared libraries and platform schemas contain no
  game title, landmark, item, economy or scenario assumption.
- Product requirements are compiled from a frozen product intent and approved
  references before the candidate is evaluated.  Candidate-derived thresholds
  are rejected.
- `productId` and hashes bind intent, references, contract, visual calibration,
  scenarios, assets, build, Studio session, evidence, captures and review.
  Cross-product evidence is invalid.
- Every mandatory requirement has a live, release-integrated producer at the
  required validation level.  A fixture, disabled script or documentation-only
  adapter cannot satisfy it.
- All game integrations consume stable declarative interfaces.  Engine code
  never reaches into a particular game's instance paths or literal coordinates.
- Unknown game genres and unknown changed paths fall back to the full planning
  and regression paths, never to an optimistic shortcut.

## AI interaction surface

The factory exposes a typed, versioned capability surface rather than asking an
agent to operate Studio visually by hand.  It must cover:

- project/build/place lifecycle and exact Studio process/window/session identity;
- safe DataModel reads and fenced mutations;
- server, player and client contexts;
- world construction/inspection, physics, navigation, UI, camera and logs;
- deterministic scenarios, multi-client play, persistence and monetization
  test environments;
- capture by device/viewpoint and hybrid deterministic/visual evaluation;
- source, build, evidence and regression artifacts;
- capability discovery, effect classification, schemas, deadlines,
  cancellation, idempotency and explicit unavailable states.

The command count is not a quality metric.  Coverage is measured against this
production capability model.  Adding a command without a schema, ownership,
context, effect class, test and release integration leaves the capability
incomplete.

## Asset factory stopping criterion

The engine is not industrial until an agent can complete both branches below
for meshes, audio, animations and icons:

1. **Discover existing content** — typed search; stable ID; creator; name;
   description; useful preview imagery when available; acquisition/permission,
   license and provenance evidence; ranked selection receipt.
2. **Create original content** — versioned creative brief; generator/tool/model
   identity; prompt, seed and source hashes; type-specific validation; preview;
   rights receipt; idempotent authenticated publication; moderation polling;
   published ID; declarative integration and runtime verification.

Missing credentials, owner approval, licensing information, provider support or
Roblox moderation produces a ready, immutable publication package and a
`BLOCKED` result.  It never produces a fake ID or allows a production placeholder
through the release gate.

## Industrial acceptance

The factory itself is accepted only when all of the following are demonstrated:

- At least two materially different project definitions compile into isolated,
  deterministic production plans without platform code changes.
- The current game can remain deliberately mismatched and the product-truth
  gate blocks it for the right reasons.
- A clean project can travel through the complete state machine with one
  immutable run per attempt and a single deterministic release authority.
- Runtime, client, E2E and visual claims come from the exact built place and
  leased Studio contexts named by the run.
- Every required asset is selected or created, validated, approved, integrated
  and verified; unavailable external steps terminate honestly.
- Repair impact selects a minimal feedback regression, followed by a new full
  gate before release.
- Dashboard metrics derive only from verified final manifests and expose
  coverage, quality, cost, duration, flakiness and regressions without invented
  zeroes or global mutable evidence.

Until these conditions are met, the honest platform status is **in progress**,
regardless of how polished or functional the first game becomes.
