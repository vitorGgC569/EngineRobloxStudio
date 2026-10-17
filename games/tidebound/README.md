# Tidebound

A fishing and sailing game for Roblox, built on the Forge engine in this
repository. You start with a bamboo rod, five worms and a rowboat; the sea has
five waters, sixty species, and a weather system that changes what bites.

## The loop

1. **Cast** — hold the mouse to charge, release toward open water.
2. **Fight** — when something bites, hold to pull and release to ease. Keep
   the marker inside the light. Line integrity and progress race each other;
   the timer is a real loss condition.
3. **Keep or lose it** — the catch goes into the crate. Sell at the harbor for
   a 15% bonus, or sail and sell from the field for less.
4. **Progress** — coins buy rods, bait and boats. Levels come from xp; every
   level pays a purse. Three daily quests pay in coins and xp, with a login
   streak that multiplies quest rewards.

## What is in here

| Area | Where |
| --- | --- |
| Tuning numbers (odds, prices, zones, weather) | `src/shared/Config.luau` |
| The network contract (every channel, in one file) | `src/shared/Wire.luau` |
| 60 species across 5 zones | `src/shared/FishCatalog.luau` |
| Rods, baits, boats | `src/shared/Items.luau` |
| The catch roll (pure, injectable rng) | `src/shared/Roll.luau` |
| The reel minigame math (player and audit use the same module) | `src/shared/ReelMath.luau` |
| Daily quests (deterministic per player+day) | `src/shared/Quests.luau` |
| Terrain, docks, dressing | `src/server/Services/WorldService.luau` |
| Fishing sessions and the anti-cheat rules | `src/server/Services/FishingService.luau` |
| Shops, selling, zones | `src/server/Services/EconomyService.luau` |
| Saves | `src/server/Services/DataService.luau` |
| Boats (server builds, driver's client drives) | `src/server/Services/BoatService.luau` |
| HUD, panels, reel UI, catch card | `src/client/ui/` |
| Studio boot self-check | `src/server/Tests/Smoke.luau` |

## Authoritative vs rendered

The server decides every fish, weight, mutation, price and crate change. The
client renders and reports: charge timing, where the bobber landed, and how the
fight ended. A reported win is checked against the session's own clock; the
fish itself was rolled at the bite, before the client heard of it.

Weather and the clock are server-authoritative too. One sky for everyone.

## Running it

```powershell
python forge/forge.py doctor tidebound     # authoring checks
python forge/forge.py build tidebound      # builds tidebound.rbxlx
python forge/forge.py gametest tidebound   # headless run through the Studio bridge
```

In Studio (with the bridge running), the server boots a smoke self-check and
prints `[SMOKE] PASS/FAIL` lines to Output: terrain exists where the plan says,
the catalogue is complete, rolls are deterministic and never empty, the fight
is winnable at every difficulty, and the economy ladders ascend.

## Design decisions worth knowing

- **Zone by bobber, not by angler.** Cast across a border and you fish the
  water that landed in, not the ground you stand on.
- **Bait is spent by the fish that takes it.** An empty cast costs a worm only
  when a worm was stolen.
- **Catch rolls happen at the bite.** The difficulty the player fights is
  derived from the fish already on the line.
- **The minigame math is shared.** `ReelMath` runs in the client for feel and
  in the test suite with a scripted hand, proving the hardest fish is difficult
  and not impossible.
- **Levels are derived, xp is stored.** A balance change to the curve never
  corrupts a save.
- **Boats are server-built, client-driven.** The server owns existence, crate
  capacity and luck; the driver owns the physics while their hands are on it.
