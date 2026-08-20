# Factory control CLI

The factory exposes its declarative inventory and planner as structured JSON.
These commands inspect source-controlled definitions only. They never execute a
task, mutate a game, or authorize a release.

```powershell
python rqe.py capabilities report .
python rqe.py capabilities select . --phase runtime --phase assets
python rqe.py capabilities select . --capability runtime.world.measure `
  --minimum-validation-level RUNTIME_VALIDATED

python rqe.py factory inspect path/to/portfolio.blueprint.json
python rqe.py factory compile path/to/portfolio.blueprint.json `
  --output artifacts/plans/<plan-id>.json
```

`capabilities report` returns success when the catalog is internally valid;
`productionReadiness` remains independently `INCOMPLETE` while industrial gaps
exist. `capabilities select` is fail-closed: its exit code is non-zero unless
every selected capability is available at the requested validation floor.

Without `--output`, JSON is printed and no file is created. With it, only the
explicit path is written atomically. A `latest.json` destination is rejected so
that concurrent agents cannot accidentally share mutable global state.

`factory inspect` validates product/engine isolation and emits a versioned,
hash-identified inspection with `authorizesRelease: false`. `factory compile`
emits the versioned deterministic production plan. Its
`STATICALLY_VALIDATED` label means only that the blueprint and task DAG were
validated; it is not evidence that any task ran or that any game passed a gate.
