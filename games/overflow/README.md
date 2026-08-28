# overflow

A sorting line that speeds up until you drown in it.

    loop:        read the queue → be at the right lever → pull as the crate arrives
    topology:    one hall, a 156-stud belt, four chutes
    session:     continuous shifts, four strikes each, ~90s at first and longer as you learn
    currencies:  score (the shift), coins (the account)

## What the player does

Crates ride a trunk belt past four chutes — ORE, GRAIN, SCRAP, FLUX — each with a
lever on the catwalk above. Stand at a lever, pull it as its crate passes, and
the crate drops in. Pull the wrong one, or none, and you take a strike. Four
strikes ends the shift.

You never pick anything up. The verb is **anticipate and route**: the strip
across the top shows the next four crates in the order they will arrive, and the
whole skill is reading it and being in the right place when they get there.

The belt speeds up with every correct sort — not with the clock, so a player who
is struggling is not also being accelerated. A streak multiplies the score and a
mistake takes it away.

Four upgrades, bought with coins: wider chutes (a bigger catch window), slow
levers (gates stay open longer), the line brake (the whole line runs slower), and
a spare bin (one more strike).

## Why it is built the way it is

**The queue strip is a control surface, not a readout.** Routing is only a skill
if you can plan, and planning needs a future you can see. The crates are decided
before they exist so the strip can never promise one the belt will not deliver —
there is a scenario that asserts exactly that.

**Crates are anchored and stepped by the server, not thrown onto a physical
belt.** A physical crate can be shoved off by a player standing wrong, moves at
whatever friction decides rather than the number the difficulty curve is built
on, and is not reproducible — so a scenario about it would be a scenario about
the weather.

**The camera is placed, not inherited.** Roblox's default third-person camera
frames the catwalk and hides the belt behind its own edge; three screenshots in a
row came back that way. This is a 2.5D composition, so the camera sits above and
behind the walkway, aimed at the line, and never rotates. Left on screen is
always upstream.

**Nothing the client sends can add a point.** `Pull` names a chute and nothing
else. The server checks the player is standing at that lever, then decides from
the crate *it* has on the belt what the pull was worth. The obvious exploit
against any other design is to read the belt and send the matching chute from
across the room; the range check is what makes running the actual game.

## Built without a content pipeline

The publishing account behind this repository is moderated — Open Cloud answers
`{"errors":[{"code":0,"message":"User is moderated"}]}` and every
`rbxassetid://` returns HTTP 403 on *read*, including a Roblox asset from 2006.
So `Forge.Catalog.ItchAssets` (470 models), `Forge.UI.ItchIcons` (348 icons) and
every uploaded sound were unavailable while this was built.

What it is made of instead:

- **`Forge.Catalog.Prop`** — baked geometry stored *in the place*, which fetches
  nothing. The head-end dropper and the crates beside each chute.
- **Procedural parts** for the hall, the belt, the chevrons, the chutes and the
  levers.
- **`rbxasset://` sounds** — the four that ship with the Roblox client, used
  deliberately: a lever click, a crate thud, an `oof` for a mistake, and an
  explosion pitched right down for the end-of-shift horn.
- **`UI.theme`** for the interface, since the skinned catalogue is an asset too.

See `FINDINGS.md` for what that cost and what it says about the pipeline.

## Layout

    src/shared/Config.lua       every tunable number; systems own none
    src/shared/Channels.lua     the wire, declared once, required by both VMs
    src/shared/Sound.lua        the bank, built from what ships with the client
    src/server/core/Shift.lua   authoritative state and the pure rules over it
    src/server/systems/
      Mill.lua                  the hall, the belt, the chutes, the light
      Line.lua                  crates: the decided queue, movement, chutes
      Play.lua                  the tick: gates, strikes, shifts, the horn
      Store.lua                 upgrades, and the player list
    src/client/
      init.client.lua           input, the camera, the panel opener
      ui/Hud.lua                score, queue strip, strikes, legend, workshop
    src/server/tests/Line.lua   13 live scenarios, run in the running game

## Working on it

```bash
python forge/forge.py doctor overflow
python forge/forge.py build overflow
python forge/forge.py playtest overflow --panel shop
```

`playtest` is the rung that matters: it opens the place, plays it, photographs
it, and refuses a build whose interface is absent, off-screen, too small to
touch, or a flat colour. Look at the pictures it writes even when it passes —
it measures presence, not taste.
