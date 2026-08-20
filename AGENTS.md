# Agent instructions for Roblox Quality Engine

## Read this first

`docs/platform/OVERVIEW.md` explains what this project is and why it is built
this way -- read it first if you have never worked here.

`.codex/skills/roblox-production/SKILL.md` is the working guide for this
repository: the bridge command surface, the validation ladder, what "done"
means, and the standard a build has to meet. `docs/platform/ENGINE-FACTS.md`
lists Roblox behaviours measured here that are invisible when you get them
wrong -- read it before debugging anything that "should work".


## Boundaries

- Treat `contracts/` as the source of truth for release requirements.
- Treat a finalized immutable `artifacts/<runId>/run.json` plus its hash-bound
  artifacts as the source of truth. `reports/latest*` files are diagnostic
  compatibility pointers and must never authorize release or be joined to a
  build without a verified run/manifest hash.
- Distinguish measurements from assertions. Evidence with `source="studio-bridge"`
  was measured in a real Studio; evidence with `source="headless-runtime"` mostly
  originates from `roblox/mvp/game-state.json`, a hand-written fixture. Never
  present a fixture value as a measurement.
- Label every claim: `NOT_VALIDATED`, `STATICALLY_VALIDATED` (source, or a live
  place in edit mode), `RUNTIME_VALIDATED` (a running place),
  `VISUALLY_VALIDATED`, `E2E_VALIDATED`.
- Build reusable primitives, not per-game routines: `validateConveyorSystem(config)`,
  never `validateAnimeCardTycoonConveyor()`.
- Keep black-box agent tests free of instance paths, direct pivots and white-box state.
- Use gray/white-box observations only after a human-mode failure needs diagnosis.
- Keep gameplay mutations server-authoritative; never trust client price, item or ownership fields.

## Verification before handoff

```powershell
python -m unittest discover -s tests -v
python rqe.py release .
python rqe.py bridge demo . --mode blackbox
rojo build roblox/mvp/default.project.json --output .tmp\MinersRidgeTycoon.rbxlx
```

For any claim about the game's world, performance or runtime behaviour, measure
it through the Studio Bridge instead of asserting it:

```powershell
python rqe.py studio serve                 # separate terminal; needs Studio open
python rqe.py studio status --wait 60
python rqe.py studio call run.start --params '{\"settleSeconds\":6}' --timeout 60
python rqe.py studio measure .
python rqe.py studio call run.stop
```

Changing the plugin under `apps/studio-plugin/src/` requires
`python rqe.py studio install .` **and a Studio restart** — Studio does not
hot-reload plugins. `bridge.exec` exists to avoid a restart when prototyping.

If the release gate is blocked, inspect `artifacts/<runId>/gate.json` and its
immutable evidence bundle. Legacy `verify`/`audit` output is diagnostic only and
cannot release. Do not claim a Studio playtest succeeded unless the Studio
adapter has returned real evidence; the headless adapter is explicitly labeled
as headless evidence.

