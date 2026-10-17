# Saltmere

A tidal saltworks tycoon. The tide is the clock. Each player owns a plot of pans on a shared quay. Brine floods, crystals settle, the harvest window opens, and whatever is left spoils. Cash buys pans, pan levels, upgrades and crew. A spring tide (prestige) keeps the lighthouse and starts the marsh over.

This is not a renamed pad-collector. Rules live in `src/shared/Sim.lua` and nowhere else. The world, the wallet and the UI call Sim. They do not reimplement it.

## File owners

Only the owner writes the file. Everyone else reads.

| File | Owner |
|---|---|
| `DESIGN.md`, `Config.lua`, `game.json`, `default.project.json`, `src/server/init.server.lua`, `src/client/init.client.lua` | coordinator, frozen |
| `src/shared/Sim.lua` | rules |
| `src/shared/Content.lua` | content |
| `src/server/systems/Ledger.lua` | ledger |
| `src/server/systems/Marsh.lua` | marsh |
| `src/server/systems/Works.lua` | works |
| `src/server/systems/Crew.lua` | crew |
| `src/server/systems/Market.lua` | market |
| `src/server/systems/Presentation.lua` | presentation |
| `src/client/ui/Hud.lua` | hud |
| `src/server/tests/Tycoon.lua` | tests |
| `tokens/saltmere.json` | presentation |

Do not start Studio. Do not edit Forge. Do not add a second copy of a balance number.

## Loop

`collect → process → sell → upgrade → unlock → buy → prestige`

- Collect: rake a ready pan during `harvest`. Yields coarse salt, sometimes flake.
- Process: refine coarse into fine, fine into smoked.
- Sell: quay prices fall as you sell that grade during the current tide.
- Upgrade: pan level, cistern, rake, sluice, cooperage, lighthouse.
- Unlock: claim pans, buy the grader's bench and the smokehouse.
- Buy: hire rakers, graders and watches. The copper lantern is a cash cosmetic.
- Prestige: spring tide. Requires the lighthouse and enough lifetime salt.

## Tide

Global, from `Config.tide`, in seconds: flood, settle, harvest, spoil, then repeat.

| Phase | What happens |
|---|---|
| flood | Owned pans fill. Wages are paid. `soldThisTide` resets. |
| settle | Brine sits. Nothing is collected. |
| harvest | A pan whose brine / capacity reached `readyThreshold` becomes `ready`. Players and rakers may collect. |
| spoil | Rakers collect their assigned ready pans first. Any pan still ready keeps `spoilKeep` of its brine, or `watchSpoilKeep` if the player has a watch, and loses `ready`. |

`Sim.integrate(profile, dt, phase)` only adds brine, and only in `flood`.
`Sim.onPhase(profile, phase)` runs the boundary for the phase just entered.

## Profile

`Sim.newProfile()` is the save template. `Sim.reconcile` backfills old saves in place. `Sim.clone` deep-copies. `Sim.copyInto(dst, src)` copies top-level keys onto the live save table. Never replace the table Save is holding.

```lua
{
  cash = 30,
  salt = { coarse = 0, fine = 0, flake = 0, smoked = 0 },
  pans = { pan_1 = { owned = true, level = 1, brine = 0, ready = false }, --[[ others owned false ]] },
  upgrades = {}, -- missing key means level 0
  crew = {}, -- { id, role, panId }
  nextCrew = 1,
  prestige = 0,
  lifetime = 0,
  soldThisTide = { coarse = 0, fine = 0, flake = 0, smoked = 0 },
  quests = { claimed = false, collected = false, sold = false, refined = false, prestiged = false },
  slot = 0,
  cosmetic = "",
}
```

## Formulas

All of these read `Config`. Integers only for salt and cash.

```text
prestigeMult = 1 + prestige * production.prestigeYieldBonus
upgradeLevel(id) = upgrades[id] or 0
capacity = production.capacityBase
         + (pan.level - 1) * production.capacityPerLevel
         + upgradeLevel("cistern") * effects.cisternCapacity
fillPerSecond = production.fillPerSecond * (1 + upgradeLevel("sluice") * effects.sluiceFill) * prestigeMult
yield = floor(brine * production.yieldPerBrine * (1 + upgradeLevel("rake") * effects.rakeYield) * prestigeMult)
```

Flake: if `pan.level >= refine.flakePanLevel` and lighthouse >= 1, `floor(yield * refine.flakeChanceAtMaxPan)` of that yield is flake and the rest is coarse. Lifetime gains the coarse-equivalent: coarse 1, fine 4, flake 4, smoked 8, counted when those units are created.

Pan upgrade cost, current level `L` (starts at 1): `floor(panUpgrade.baseCost * (L ^ panUpgrade.costPower) * (1 + pan.col))`. Refuse at `maxLevel`.

Building upgrade cost, current level `L` (starts at 0): `floor(baseCost * (costGrowth ^ L))`. Refuse at `maxLevel`.

Price of a grade:

```text
pressure = 1 / (1 + soldThisTide[grade] * prices.pressure)
bonus = 1 + lighthouse * effects.lighthousePrice + cooperage * effects.cooperagePrice
unit = max(1, floor(prices[grade] * pressure * bonus))
```

Refine `amount` means how many outputs to make. Fine needs `grader_bench >= 1` or a grader on the crew, and consumes `amount * refine.coarsePerFine` coarse. Smoked needs `smokehouse >= 1` and consumes `amount * refine.finePerSmoked` fine.

Prestige needs `lighthouse >= 1` and `lifetime >= floor(prestige.lifetimeBase * (prestige.lifetimeStep ^ prestige))`. It increments prestige, sets cash to `prestige.cashReset`, zeroes salt, brine and ready, sets every pan level to 1, unclaims every pan except `pan_1`, zeroes every upgrade except lighthouse, clears `soldThisTide`, and keeps crew, lifetime, lighthouse and the cosmetic.

Hiring spends `crew.hireCost[role]`. Crew cap is `crew.max`. Ids are `crew_N` using `nextCrew`. On flood, wages are `crew.wage[role]` each. If cash cannot cover every wage, dismiss crew from the end until it can, then charge. A dismissed crew member is named in `toast`.

`amount` must be an integer in `1..10000`. Unknown ids fail. A failed action returns the original profile unchanged.

## Result

Every mutating Sim call returns `(profile, result)`:

```lua
{ ok: boolean, reason: string, toast: string?, delta: any? }
```

Reasons: `not_enough_cash`, `not_owned`, `already_owned`, `not_harvest`, `not_ready`, `missing_upgrade`, `bad_amount`, `bad_id`, `crew_full`, `need_lighthouse`, `need_lifetime`, `max_level`. Empty reason when `ok`.

`integrate` and `onPhase` return `ok = true` even when nothing changed. Toasts fire once, when a quest flag flips: first claim, first collect, first refine, first sell, first prestige.

## Module APIs

### Ledger

```lua
function Ledger.start()
function Ledger.get(player): any?
function Ledger.each(): () -> (Player, any)
function Ledger.mutate(player, reducer: (any) -> (any, any)): (boolean, any)
function Ledger.sync(player)
```

`mutate` clones, runs the reducer, and on `ok` copies into the live profile, syncs, and fires `Notify` when `toast` is set. `sync` fires `StateSync` with cash, salt, pans, upgrades, crew, prestige, lifetime, quests, cosmetic, `prices` (all four grades via `Sim.price`) and `prestigeNeed`.

### Marsh

Builds the quay and, per adopted player, a plot of six anchored pans plus a walkway and a `SpawnLocation`. Assigns `profile.slot` if it is 0, using the first free slot from 1 to `maxPlayers`.

```lua
function Marsh.start()
function Marsh.phase(): string
function Marsh.remaining(): number
function Marsh.tideIndex(): number
function Marsh.onPhase(fn: (string, number) -> ())
function Marsh.onCollect(fn: (Player, string) -> ())
function Marsh.onClaim(fn: (Player, string) -> ())
function Marsh.onSell(fn: (Player) -> ())
function Marsh.onPrestige(fn: (Player) -> ())
function Marsh.assignSlot(player): number
function Marsh.adopt(player, slot: number)
function Marsh.setPanVisual(player, panId: string, brine: number, capacity: number, ready: boolean)
```

Prompts go through `Forge.Interaction` with distinct ids, `AlwaysShow` behaviour (the registry does this), range 14, short holds. Collect and claim prompts call the bound handlers with the pan id stored as attribute `PanId`. The quay prompt calls onSell. The lighthouse prompt calls onPrestige. Handlers may be bound after the prompt exists; the prompt reads the current handler at trigger time.

Parts stay anchored. No unanchored weld. BillboardGui on a plot uses `MaxDistance` 80. Colours come from `Config.colors`.

### Works

Binds collect and claim. On heartbeat, `integrate`s every profile with `dt` and the current phase, copies back, and refreshes pan visuals at most a few times a second. On `Marsh.onPhase`, calls `Sim.onPhase`. Collect and claim go through `Ledger.mutate`.

### Crew

No extra remotes beyond Hire and AssignCrew. Those handlers live here. Auto-collect is inside `Sim.onPhase`, not a second implementation.

### Market

Owns Sell, BuyUpgrade, UpgradePan and Prestige. Sell-all-coarse for the quay prompt uses the player's coarse balance as the amount. Buying `lantern` also sets `cosmetic = "lantern"`.

### Presentation

Sets Lighting for a late-afternoon marsh: low brightness, coloured fog, few lights. Four copper lanterns on the quay at most. If `cosmetic == "lantern"`, a client-visible lantern is the HUD's job; the server only stores the flag. Do not use a marketplace asset id.

### Hud

`Hud.mount(screen)`, `Hud.applyProfile(payload)`, `Hud.applyTide(payload)`. Rebuild labels from the payload. Buttons use `UI.button(..., { onClick = ... })` and `Net.send`. LayoutOrder on every child of a list. Override `UI.theme` from `Config.colors` before building. Buttons: collect, claim, upgrade pan, sell 1, sell all, refine 1 fine, refine 1 smoked, buy each upgrade, hire each role, assign a raker to a pan, prestige.

### Network

Defined in the boot scripts. Do not add remotes anywhere else.

| Name | Dir | Shape |
|---|---|---|
| StateSync | s2c | |
| Tide | s2c | |
| Notify | s2c | |
| ClaimPan | c2s | `{ panId = "string" }` rate 3 |
| CollectPan | c2s | `{ panId = "string" }` rate 4 |
| Refine | c2s | `{ kind = "string", amount = "number" }` rate 3 |
| Sell | c2s | `{ grade = "string", amount = "number" }` rate 4 |
| BuyUpgrade | c2s | `{ upgradeId = "string" }` rate 3 |
| UpgradePan | c2s | `{ panId = "string" }` rate 3 |
| Hire | c2s | `{ roleId = "string" }` rate 2 |
| AssignCrew | c2s | `{ crewId = "string", panId = "string" }` rate 3 |
| Prestige | c2s | `{ confirm = "boolean" }` rate 1 |

Client sends with `Net.send`. Server listens with `Net.on` and answers with `Net.fire`.

## Boot order

`Marsh`, `Ledger`, `Works`, `Crew`, `Market`, `Presentation`. Each module returns a table with `start()`. `Debug.probe` in each system, under its own name. `Debug.ready` stays last in `init.server.lua`.
