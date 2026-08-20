# Production blueprints

`ProductionBlueprint` is the declarative boundary between the RQE engine and
the games it produces. It lets one engine revision plan multiple products
without treating the first game in the repository as the engine's architecture.

This layer does not write Luau, open Studio, execute an agent, measure a game or
authorize release. Compilation is `STATICALLY_VALIDATED`: it proves that the
definition is complete and isolated, then emits deterministic work for the
orchestrator.

## Ownership boundary

The blueprint declares engine-owned `sourceRoots`. Every
`GameProjectDefinition` declares a separate `sourceRoot` and `artifactRoot`.
Compilation fails before scheduling when any of these roots overlap, including
case-only differences on Windows.

Each product additionally declares:

- immutable, SHA-256-bound product-intent, reference-bundle and quality-profile
  inputs;
- subsystems and an exact one-owner rule for every subsystem write surface;
- explicit device/viewpoint capture combinations;
- scenario classes and their release relevance;
- asset needs covering discovery/creation, validation, publication and
  integration policy;
- all output artifact roots needed by the production flow.

Every artifact reference carries a `productId`. Its path must also stay inside
that product's roots. A label alone therefore cannot disguise a reference to
another game's files.

## Deterministic compilation

`compile_production_blueprint` normalizes unordered declarations and produces a
hash-bound task DAG for each product:

```text
specify -> design -> assets + subsystem builds -> integrate -> measure
        -> play scenarios -> capture matrix -> evaluate -> repair plan
        -> impacted regression -> full regression -> release candidate
```

The repair-plan node is dynamic fan-out metadata: the future executor creates
only ownership-scoped repair work required by measured findings, or records an
explicit no-op. The full regression remains mandatory. The terminal artifact
is a release **candidate**; only the independent full release gate may
authorize a release.

No task contains a game-specific implementation routine. Product identity is
carried only as namespace/provenance, while roles, stages and completion checks
remain reusable across genres and templates.

## Schemas and API

- `schemas/production-blueprint.v1.schema.json`
- `schemas/game-project-definition.v1.schema.json`
- `schemas/production-plan.v1.schema.json`
- `rqe.orchestrator.ProductionBlueprint`
- `rqe.orchestrator.GameProjectDefinition`
- `rqe.orchestrator.compile_production_blueprint`

The blueprint schema validates its engine/container shape. Each member of
`projects` is then independently validated against the game-project schema and
the semantic isolation rules. This explicit two-step composition is required
because RQE's deterministic schema validator intentionally supports only local
JSON pointers.
