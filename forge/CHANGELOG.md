# Forge changelog

Forge follows semantic versioning from `0.2.0` onward, with the pre-1.0 rule
that the **minor** number carries breaking changes and the patch number does
not. Once something reaches `1.0.0`, breaking changes move to the major.

## What counts as breaking

Only these. Everything else may change in a patch release:

- removing or renaming a public function, or changing what it returns
- changing the meaning of a field a caller passes in
- changing a joint name, clip name, or any string the engine matches on
- changing a default in a way that alters behaviour rather than only tuning it

Adding a function, adding an optional field, adding a module, changing a
number that only affects feel, and rewording a warning are **not** breaking.

## Deprecation

A function being removed is first marked deprecated for one minor release. It
keeps working, warns once per session naming its replacement, and appears in
this file under *Deprecated*. Nothing is deleted without that step, because an
engine that removes a call between two versions is an engine whose users stop
upgrading.

---

## 0.2.0 — 2026-09-02

The release where the engine started telling you whether a game works.

Dated rather than left as *unreleased*, because nine games in this
repository already pin `Forge.require("0.2.0")`. A version that games
depend on and a changelog that says it never shipped cannot both be true,
and the games are the ones that run.

### Added

- **`Testing`** — scenarios that run inside the live game against real rigs,
  real Humanoids and the real damage pipeline. Reported through a replicated
  channel that `forge gametest` reads.
- **`Examples`** — one runnable demonstration per module, executed by
  `forge example`. A documented example rots; an executed one fails loudly.
- **`Nav`** — pathfinding over Roblox's own navmesh, with throttled repathing,
  stuck detection and a straight-line fallback.
- **`IK`** — closed-form two-bone solving, foot planting and hand-to-target
  reach. R15 only, and it says so.
- **`Material`** — `MaterialVariant`, `SurfaceAppearance`, render fidelity and
  a shadow budget.
- **`Destruction`** — breakable scenery built around a debris budget rather
  than around fracture.
- **`Weather`** — conditions that transition rather than cut.
- **`LiveOps`** — remote config, kill switches, hash-bucketed experiments and
  localisation.
- **`Collab`** — expiring edit leases, presence and an attributed journal.
- **`Capability`** — ask Roblox what exists instead of assuming it.
- **`Catalog`** — 200 verified Creator Store pieces, script-free, with the
  pack, creator and licence attached to every entry.
- **`Weapon`** — cadence, deterministic spread, ammo, reload, recoil, falloff.
- `Rig.grip`, `Rig.buildWeapon` and `rigType = "R15"`.
- Animation **layers** and **root motion**.
- **`Economy`** — big numbers, formula curves, multi-currency wallets, an
  income engine and a faucet/sink audit. Six modules.
- **`Progression`** — the retention layer: daily-reward calendars, season
  passes, playtime ladders, rebirth and prestige, quest engine and rotation,
  crate rolls with a pity timer, offline earnings, upgrade trees. Eighteen
  modules. **Executed for the first time in this release**: sixteen of them had
  never been called by a game, a kit, a tool or a test, and
  `tests/test_forge_retention_runtime.py` now runs them headlessly.
- **`Social`** — parties, guilds, trade sessions, plot permissions, moderation
  and staff flags. The player's relationship with everyone outside the server.
- **`Tycoon`** — build-and-earn primitives: plots, droppers, conveyors,
  resource nodes, ground loot, blueprint serialisation. Eleven modules.
- **`Match`** — competitive match primitives: rounds, arenas, deploy zones,
  team spawns, wave spawners, a director. Eleven modules.
- **`AI`** — crowd and companion intelligence: behaviour trees, ground
  locomotion, perception, snapshot interpolation, a mob catalogue.
- **`Movement`** — player feel and shooting validation: strafe jumping,
  teleport pads, a scoreboard.
- **`Camera`** — where the player is looking and who decides, including the
  first-person `Viewmodel`.
- **`Companion`** — things that follow you and stay readable while they do:
  formations and idle wander, generalised from a shipped simulator.
- **`State`** — the session's own truth, and who is allowed to see it.
- **`Travel`** — moving players between places, and arriving with something.
- **`Cluster`** — the engine stops assuming there is one server.
- **`Platform`** — is this game actually playable on the device in front of you.
- **`Access`** — the game is playable by people this engine had not considered.
- **`Reference`** — what a reasonable number looks like.
- **`Mark`** — tell the Quality Engine what it is looking at.
- `Forge.<Family>.<Sibling>` resolves lazily on **every** family. Five of them
  (`Audio`, `Companion`, `Core`, `State`, `Weapon`) had no resolver, so a module
  beside the index was reachable only by requiring the instance directly --
  `Forge.Audio.Bank` was nil while `Bank.lua` documented its own usage as
  `Forge.Audio.Bank.specs()`.
- `Debug.ready(name)` is emitted by `forge new` and by the production
  implementer, so every new game announces when it has finished starting.
- **`Loop`** — the degree between a primitive and a game, which this engine did
  not have. A Loop composes the primitives, carries numbers that came from a
  *measurement* rather than from taste, owns the moment it pays out, and
  **declares its own funnel** so a game built on one produces a drop-off report
  the moment it has players. `Loop.Hatch` is the first: open a thing, get a
  thing, want the next thing. Every constant in it cites the line of
  `forge/kits/halo/.../retention/*.json` it came from.
- `Telemetry.defineFunnel` and `Telemetry.seen`: funnel steps carry **names**
  and a **clock**. Steps were integers, so a report said "step 4" where a
  designer needs "hatch_another"; and there was no time, so a funnel could say
  how many people stopped and never where the time went. The only fatal gap in
  the only real retention record here hid behind a 79% conversion rate and was
  visible only as 82s becoming 218s.
- `forge analytics` reports `meanSecondsToReach` and flags dead time. It read
  the two published experiences for the first time in this release; both are
  live and neither declares a funnel, which is what `Loop` exists to end.
- `forge cost` and the production ledger: round trips to Studio, seconds,
  restarts and failures, per run.
- `forge publish --rollback` and `--list`.
- `forge preflight`, `forge inspect`, and `rqe stamp`.
- `forge publish`, `forge scene`, `forge pose`, `forge api`, `forge toolbox`,
  `forge assets`, `forge gametest`, `forge example`.

### Fixed

- **`Netcode.latency` had no body.** Its declaration swallowed `simulate`,
  `broadcastSimulation` and `resetStats`, so the entry point of the latency
  sweep did not exist until lag compensation had run once. It compiled and
  type-checked for as long as it existed.
- **`Netcode` wired itself during `require`.** `Net.on` yields on a client, so
  the require yielded, and the module loader answered "cannot resume
  non-suspended awaiting coroutine" — killing the entire client script.
- **`Anim` only drove `Motor6D`.** Roblox's current R15 player rig uses
  `AnimationConstraint`, so every clip in the engine was a no-op on the one
  character a person controls.
- **`Rig.stripDefaultAnimate` left the Humanoid's `Animator` in place**, which
  reset those joints to rest every frame.
- **`Actor` sliced a single-member scheduler group**, quartering the brain rate
  at identical peak cost.
- **`Material.define` wrote `BaseMaterial` directly**, which is plugin-only and
  threw at runtime.
- **`IK.footPlant` measured the leg from the middle of the thigh**, folding the
  character into a crouch on flat ground.
- **`Sky.install` aborted** on a `Terrain.Decoration` write that this Roblox
  build refuses, losing the water settings that followed it.
- **`UI.bar` leaked its connection** through a `local conn` that resolved to a
  nil global.

### Changed

- `Anim.JOINTS` grew from 6 to 14: R15 gains elbows, knees, wrists and ankles.
  **Breaking** for anything iterating `Anim.JOINTS` and assuming six.
- `Anim.CORE` added for the six every rig has, R6 included.
- Clips now cancel only others on their own **layer**. Clips with no layer land
  on `base`, so existing behaviour is unchanged.

### Deprecated

- Nothing yet.

## 0.1.0

The first engine surface: `Core`, `Data`, `Net`, `Save`, `Rig`, `Anim`,
`Feel`, `Combat`, `Actor`, `World`, `UI`, `Debug`, `Entity`, `Assets`,
`Scene`, `Streaming`, `Editor`, `Events`, `Inventory`, `Progression`, `Quest`,
`Ability`, `Interaction`, `Dialogue`, `Input`, `Audio`, `Visual`, `Telemetry`,
`Monetization`, `Bench`, `Netcode`.
