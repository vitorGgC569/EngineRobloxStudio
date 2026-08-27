# brownout

A night shift at an off-grid outpost. The generator is starving, and the only
fuel left is scattered out past the lamps.

    loop:        run into the dark → lift a cell → haul it home → the lights come back
    topology:    one basin, 470 studs, concentric
    session:     7-minute nights, continuous, drop-in
    currencies:  watts (persistent), charge (per-night)

## What the player does

Charge drains from the generator every second and drains faster the longer the
night runs. Charge maps to a **lit radius**, and the lit radius is the safe
zone — outside it, exposure fills, and when it fills you start taking damage.

Fuel cells sit on three rings, all of them outside the light:

| ring | distance | charge | watts | the trade |
| --- | --- | --- | --- | --- |
| 1 | 210 | 19 | 11 | a weak fallback, and safe |
| 2 | 290 | 30 | 24 | the honest run |
| 3 | 372 | 58 | 62 | a third of the night, if you make it back |

Carrying slows you, and it slows you more the bigger the cell. That is the
whole game: how far out do you go, and can you still get home.

Hit zero and the outpost blacks out — seven seconds of real dark that hurts,
then an emergency reserve restarts you at a quarter charge with your streak
gone. Survive to dawn and the shift pays.

Four upgrades, bought with watts: lantern range (buys time in the dark, never
immunity), hauler rig (carry slows you less), fast coupler (more charge per
delivery), grip boots (speed).

## Why it is built the way it is

**The lamps are the gauge.** Charge does not just drive a bar — it switches
forty real lamps on and off from the outside in. A player watching the outer
ring go dark has read the generator's state without looking at a number. It is
the cheapest legibility in the game and the reason the HUD can stay small.

**The dark is the antagonist, and it is a number.** No monster. A creature
would need pathing, animation, a spawn budget and a difficulty curve of its own,
and it would still be a worse threat than the one already there: the light is
going out and you are a long way from it.

**The beacon exists because the first honest question about a game played in
the dark is "how do I get back".** A 300-stud column of light over the
generator answers it from anywhere on the map, and the answer is not a compass
in the corner of the screen.

**Nothing the client sends can add charge.** `Grab` carries no cell id — the
server takes the player's own character position and picks the nearest cell
itself. Deposits are not a packet at all: the simulation loop checks where
characters actually are against the pad it built. `Buy` carries an id and no
price.

## What a session sounds like

Every sound is from Roblox's own licensed SFX library — the `(SFX)` clips
uploaded by ProSoundEffects, the only audio that reliably plays in somebody
else's place — and every id was verified through
`MarketplaceService:GetProductInfo` before it was written down.

The soundscape has one job beyond atmosphere: **tell you where the light is.**
The generator carries a bed whose roll-off is driven from the lit radius, so
the outpost gets quieter as the lights go out, and a player lost past the last
lamp can turn until it gets louder. That is the audio half of the beacon.

The inner ring of lamps hums, and a dark lamp is a silent one.

## Your first five minutes

Onboarding is driven by what you did, not by a timer: you are told what the
dark does the first time you walk into it, what to do with a cell the first
time you are holding one, and where to spend watts once you have some. It runs
once ever — `profile.taught` records it, so a returning player is never
explained their own game.

Watts and nights survived show in the Roblox player list, which is the one
piece of interface every player already knows how to read.

## Layout

    src/shared/Config.lua      every tunable number; systems own none
    src/shared/Channels.lua    the wire, declared once, required by both VMs
    src/shared/Sound.lua       the sound bank; every id verified, none guessed
    src/server/core/Shift.lua  authoritative state; no ticking, no instances
    src/server/core/Props.lua  place a baked prop, then check what you got
    src/server/systems/
      Ground.lua               terrain basin, the night look, spawn, scenery
      Outpost.lua              generator, lamp rings, beacon
      Cells.lua                the fuel field, lifting and dropping
      Power.lua                the tick: drain, deposits, blackout, dawn
      Exposure.lua             what the dark does to you; walk speed
      Store.lua                the four upgrades
      Roster.lua               the player list, and event-driven onboarding
    src/client/
      init.client.lua          input, the lantern, the wire
      ui/Hud.lua               gauge, clock, exposure, prompt, outfitter
    src/server/tests/Shift.lua 16 live scenarios, run in the running game

Every prop in the world — the generator, the furnaces, the storage tank, the
lamps, the rocks and trees and barrels — is baked Creator Store geometry
rebuilt from data by `Forge.Catalog.Prop`. Nothing is fetched at runtime.

## Working on it

```bash
python forge/forge.py doctor brownout
python forge/forge.py build brownout
python forge/forge.py quality brownout    # the release gate; see FINDINGS.md #16
python forge/forge.py gametest            # runs against the live session
```

`ServerScriptService.LoadStringEnabled` is on in `default.project.json`. It is
what makes `bridge.exec` work against a running server, which is the only way
to inspect a live session. **Turn it off before publishing** — it is a
dev-loop affordance, not a shipping one.
