# Carve Wood — the five systems that make it the real game

The MVP has the loop: plant, wait, chop, carve, sell, spend. Every one of those
six verbs is currently a button press that resolves instantly. The original is
a game because four of them are *actions* and the fifth is a *negotiation*.

This maps what each system has to become, which engine module already carries
it, what changes in the pure rules, and what will go wrong. Nothing here is
built yet.

The engine turns out to already hold almost all of it — `CrateRoll` is a gacha
with pity, `ResourceNodes` is a node with hits that depletes and returns,
`FishingMinigame` is the timing-minigame shape, `GridPlacement` + `UpgradeTree`
are a buildable shop, and the `AI` family has a navigator, a behaviour tree, a
trait brain and crowd separation. The work is mostly wiring and tuning, not
invention.

---

## 1. Chopping — swing a wooden axe at the tree

**Today.** `Yard.chop(state, index)` is one call. It returns `{logs = n}`
instantly, from a ProximityPrompt.

**Target.** Equip a wooden axe. Walk to a grown tree. Swing. Each hit takes a
bite out of the trunk; after enough hits it falls and the logs drop on the
ground to be picked up.

### The mechanic

`Species` gains `toughness` — the number of hits at axe tier 1:

| Species | Toughness | At wooden axe | At iron axe (power 3) |
|---|---|---|---|
| Pine | 3 | 3 swings | 1 |
| Birch | 4 | 4 | 2 |
| Oak | 6 | 6 | 2 |
| Maple | 8 | 8 | 3 |
| Ebony | 11 | 11 | 4 |
| Amberheart | 15 | 15 | 5 |

`hits = ceil(toughness / axePower)`. The axe stops being a passive multiplier on
yield and becomes the thing that shortens the swing count — which is what
players actually feel.

### Engine

- **`Tycoon/ResourceNodes`** — `define(id, maxHarvests, replenishSeconds)`,
  `harvest(id)`, `isAvailable(id)`. A node that takes N harvests and comes back
  is exactly a tree that takes N swings and regrows. One node per plot.
- **`Feel`** — `hitstop(0.06)`, `shake`, `punch` on every connect. The
  game-feel layer already exists and is the whole difference between a swing
  that lands and a number going down.
- **`Tycoon/GroundLoot` / `PickupCrate`** — logs on the ground, so collecting is
  a walk rather than an increment.
- **`Weapon/Stance`, `Weapon/Sway`, `Anim`** — holding and swinging the axe.

### Rules that change

- `Trees.Species` += `toughness: number`
- `Yard.Plot` += `hp: number?`
- new `Yard.strike(state, index, now) -> (ok, {hp, felled, logs})`
- `Yard.chop` stays, as the pure "fell it now" the crew and the tests use
- Wire: `strike = { dir = "c2s", kind = "function", rate = 12, shape = { plot = "number" } }`

### What will go wrong

**The client must never send damage.** It sends "I swung at plot 3". Reach,
cooldown and power are the server's, read from state it owns. A payload the
server trusts is an exploit waiting for the developer console.

**The economy moves by 3–15×.** An instant chop becoming fifteen swings on an
Amberheart changes logs per minute more than any other item on this list. The
simulation has to be re-run for the whole economy, not for this feature.

**The crew has to keep working.** `crewTick` currently carves automatically. If
chopping becomes manual and the crew does not chop, going idle stops the game
dead. Decide it explicitly: the crew chops slowly, the player chops fast.

---

## 2. Carving — a minigame, and quality that matters

**Today.** `Yard.carve(state)` turns 1 log into 1 carving instantly, and
`crewTick` does it for you.

**Target.** At the bench, carve by hand. How well you carve decides what the
piece is worth.

### The mechanic

Three strokes. Each stroke runs a marker across a bar with a target zone; you
press to stop it. Zone width comes from the chisel tier and your carving skill;
species hardness narrows it.

| Result | Multiplier | How |
|---|---|---|
| Rough | ×0.7 | missed most strokes — also what the crew always produces |
| Fine | ×1.0 | the honest default |
| Masterwork | ×1.8 | most strokes in the zone |
| Flawless | ×3.0 | three perfects |

### Engine

- **`Progression/FishingMinigame`** is the existing precedent: phases
  (`idle`/`waiting`/`bite`/`result`), `cast`, `tick`, `reel`, `rollLoot`. A
  carving bench copies that shape — `begin`, `tick`, `strike`, `finish`.
- Build it **game-local first** (`systems/Carving.lua`), promote to Forge when a
  second game needs it. That is this repo's extract-after-second-use pattern.
- **`Feel.punch`** on a perfect, **`Feel.shake`** on a miss.

### Rules that change

- Carvings stop being a count:
  `Yard.State.carvings: { { species: string, quality: string } }`
- `Yard.sell` sums `species.value * QUALITY[q]`, not `count * value`
- `Yard.counts` still returns two numbers — the HUD does not have to know

### What will go wrong

**The crew is the whole design question.** A crew that produces Masterworks
makes the minigame pointless; a crew that produces nothing makes hiring
pointless. The answer that keeps both layers alive: **the crew always produces
Rough, and only the player's hands make Fine and above.** Write that down as a
decision, not a detail.

**`Yard.sell` stops making sense.** Selling everything at list price is a
counter's behaviour. Once pieces differ, selling belongs to the shop (§4).

---

## 3. Seeds — rolled, not bought

**Today.** `Yard.unlock(state)` buys the next tier in a line, `Trees.unlocked(level)`
gates the list, and planting costs `species.seed` in cash.

**Target.** Roll for seeds. Common through Celestial.

### The mechanic

Seven tiers: **Common, Uncommon, Rare, Epic, Legendary, Mythic, Celestial.**
A pack costs coins and yields one seed. Weights fall off hard; pity guarantees a
high tier every N rolls. Planting consumes a seed from your stock instead of
cash.

Duplicates are not waste — a second Pine seed is another Pine you can plant.
Surplus converts to **essence**, and essence buys a chosen species outright.
That is the standard answer to a bad streak, and it is what stops rolling from
feeling like a tax.

### Engine

- **`Progression/CrateRoll`** — `new({ drops = {{id, weight, rarity}},
  pityThreshold, minRarityForPity })` and `roll(rng)`. This is precisely the
  module; nothing needs writing.
- **`Core/Rng.stream("carvewood.seeds")`** supplies the generator, so a roll is
  reproducible in tests and in the economy simulation.
- **Not `Inventory`.** A plain `state.seeds: { [id]: number }` keeps `Yard`
  boring and pure. `Inventory` is for items with instances and stats.

### Rules that change

- `Species.seed` (a cash price) → `weight`; `rarity` becomes a real tier, not a
  display label. The species list grows to fill seven tiers.
- `Yard.State` += `seeds: { [string]: number }`, `essence: number`
- `Yard.plant` requires and consumes a seed
- **`Yard.unlock` and `state.level` retire**
- new `Yard.rollSeed(state, rng)`, `Yard.convert(state, speciesId)`

### What will go wrong

**This removes the current progression spine.** `state.level` is read by the
seeds panel, the tutorial steps and `Trees.unlocked`. All three change in the
same commit or the game half-works.

**A player can roll their way into an empty yard.** Guarantee a floor: every
pack contains at least one Common, and Pine seeds stay purchasable for coins.

**Old profiles must migrate.** `Yard.reconcile` already exists for this: level N
becomes the seeds that level implied.

---

## 4. A shop you build, upgrade and stock

**Today.** One shared decorative hut in the plaza; `Yard.sell` empties your
carvings at list price from a prompt.

**Target.** Your own shop, on your own yard, with the carvings physically on
display — which is what customers come to look at.

### The mechanic

Display stands are grid-placed on the yard. Each holds one carving (species +
quality) at an asking price you set. Shop tier raises stand count, footfall,
price ceiling, and how far a customer will walk to reach you.

Upgrades are a tree, not a line:

- **Counter** — more stands
- **Signage** — higher arrival rate
- **Décor** — customer patience and willingness
- **Storage** — stock buffer behind the counter

### Engine

- **`Tycoon/GridPlacement`** — `fits`, `place`, `release`, `snap`,
  `multiOffsets`, `isOccupied`. Stands are grid items with footprints.
- **`Tycoon/BlueprintSerializer`** — persists the layout into the profile.
- **`Progression/UpgradeTree`** — `visible`, `canBuy`, `buy`, with a `CostCurve`
  per node. The four branches above are its exact shape.
- **`Tycoon/PlotAllocator`** — already exists, and does the job `Grove.claimSlot`
  currently does by hand. Worth reconciling; that is the same work done twice.
- `Grove` builds the shop per player. The central hut stays as the **seed roll
  station**, which finally gives the plaza a reason to exist.

### Rules that change

- `Yard.State` += `shop = { tier, upgrades: UpgradeTree.State, stands: {...} }`
- `Yard.sell` retires in favour of `Yard.stock(...)` and customer-driven sales

### What will go wrong

**The profile is one DataStore key.** A serialized blueprint plus per-stand
contents can outgrow the value limit. Bound stands by tier and store the layout
as ids, never as instances.

**Player-set prices break both ways.** Someone will price at 1 for instant sales
and someone at 10⁹ for none. The willingness rule in §5 has to make both bad —
and that must be tuned in simulation *before* the shop is built, not after.

---

## 5. Customers — NPCs who walk, browse and decide

**Today.** Nothing. Selling is a prompt on a counter.

**Target.** NPCs arrive, walk the boardwalk, stop at shops, look at what is on
display, and decide: buy, haggle, or walk away.

### The mechanic

A customer carries a **budget**, a **taste** (preferred species and rarity
band), a **patience**, and a **haggle** nerve.

```
fallback(
  sequence( pick a shop -> walk to it -> browse -> evaluate -> transact ),
  meander                              -- when nothing appeals
)
```

Per displayed carving:

```
appeal      = tasteMatch(species, rarity) * qualityWeight(quality) * decor
willingness = appeal * budget

price <= willingness * 0.80   ->  buys without comment
price <= willingness * 1.25   ->  haggles: offers willingness * 0.85
otherwise                     ->  walks away
```

Walking away is information. A shop that sells nothing is telling you the price
is wrong, and that is the feedback loop the current counter has none of.

Arrival rate is a function of shop tier, signage, and how full the stands are —
**what you put on display drives who turns up.** That is the "oferta" half.

### Engine

- **`AI/Navigator`** — `update(pos, dt) -> (dir, arrived)`. Goal-seeking, far
  cheaper than PathfindingService, and the boardwalk makes the paths simple.
- **`AI/BehaviorTree`** — `sequence`, `fallback`, `action`, `run(root, blackboard, dt)`.
  The tree above, directly.
- **`AI/TraitBrain`** — `decide(mobPos, targets, state, now)`. Traits are the
  customer's personality.
- **`AI/CrowdSeparation`** — stops six customers occupying one stand.
- **`AI/GroundLocomotion`, `AI/MobCatalog`** — the body and the archetypes.
- **`Companion/Meander`** — the idle wander when nothing appeals.
- **`Dialogue`** — `define`, `begin`, `choose`, `finish` for the haggle.
- **`AI/Perception`** — what a customer can see from where they stand.

### Rules that change

Customers are **not** in the profile — they are ephemeral and server-side. But
the valuation is a rule and belongs with the others:

```lua
Yard.valuation(customer, item) -> number
```

pure, so willingness can be simulated without a single NPC — the same way the
whole economy was played through before a Part existed.

### What will go wrong

**Population cost.** Six yards times several customers, each running a tree and
a navigator. Cap the total, tick brains on a budget rather than per frame, and
keep `Navigator.update` off the render path. **`AI/SnapshotInterp`** exists to
smooth a low tick rate — use it instead of raising the rate.

**NPCs will block the boardwalk.** `CrowdSeparation` solves NPC-vs-NPC.
NPC-vs-player needs them non-collidable, or made to give way.

**A player who walks away sells nothing.** If selling requires answering
haggles, idling stops income — which undoes the offline-growth promise. Needs
an auto-accept threshold, or the crew minding the counter.

---

## Cross-cutting

**`Yard.lua` stays pure.** It is the reason forty simulated minutes of economy
were played before a single Part existed. All five of these tempt you to reach
for an Instance from inside a rule. Rules in `Yard` / `Carving` / valuation;
Instances in `Grove` / `Timber` / `Customers`.

**Four of the five move the money rate** — chopping (slower), carving quality
(higher variance), rolling (a different cost shape), customers (list price gone
entirely). Re-simulate the economy as a whole, not per feature. And the standing
warning: *the simulation tick must match the growth times.* Pine grows in 20s;
ticking at 60s under-harvests 3:1 and reads as a brutal economy that is really
a broken stopwatch.

**New remotes**: `strike`, `carveBegin`, `carveStrike`, `rollSeed`,
`convertEssence`, `placeStand`, `stockStand`, `setPrice`, `buyUpgrade`,
`haggleReply`; and server→client `customerArrived`, `customerOffer`, `saleMade`.

**Every new panel goes in the gate.** `forge playtest carvewood --panel <name>`
measures whatever it opens. A panel that is not named in the run ships
unmeasured — and the panels are where the small controls always turn out to be.

---

## Order, and why it is a chain rather than a menu

1. **Axe & chopping** — self-contained, only `chop` changes. Ships alone.
2. **Seed rolling** — replaces the progression spine. Do it before anything
   depends on species variety.
3. **Carving minigame** — introduces *quality*, which both §4 and §5 need.
4. **Shop building** — needs quality, or it displays six identical things.
5. **Customers** — needs the shop, or they have nowhere to walk and nothing to
   value.

Building 4 before 3 gives a shop full of identical items. Building 5 before 4
gives customers with no destination.
