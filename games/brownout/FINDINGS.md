# What building `brownout` on this platform found

Written from the client's seat, not the maintainer's: everything below was hit
while making a game with the engine rather than while working on the engine.
Each item says what happened, what was measured, and what it cost.

Ordered by what would hurt the next person most.

---

## 1. `World.paint` silently writes no terrain below Y = 0

**Severity: high — silent, and the default is wrong.**

`forge/luau/Forge/World/init.lua:271`

```lua
local yLow = math.max(0, math.floor(minH) - 12)
```

Every chunk's voxel write region is floored at zero. A heightfield whose
surface is below zero gets a region that starts *above* its own ground, every
voxel computes as air, and nothing is written.

Nothing reports it. `World.paint` returns `{ chunks = 256 }`, the `onProgress`
callback fires for every chunk, and `forge doctor` is clean.

**Measured.** The first build of this game put its basin floor at `Y = 0` with
`range = { -5, -1 }`. Raycasting straight down onto `Workspace.Terrain`:

| distance from origin | result |
| --- | --- |
| 0, 34, 100, 190, 300 | **no hit** |
| 400 | Y = 3.5, Slate |
| 440 | Y = 31.1, Rock |
| 460 | Y = 49.9, Rock |

The only terrain in the world was the rim, which is the part that happened to
rise above zero. Players spawned onto a floating pad over a void, 190 scenery
props became 17, and every lamp and every fuel cell failed to place because
`World.surface` had nothing to hit.

**Cost:** one full build/restart cycle to find, one to fix. Worked around by
moving the whole world to `FLOOR_Y = 24`.

**Suggested fix:** clamp to the terrain's real lower bound, not zero.

---

## 2. `bridge.exec` runs in a different Luau VM than the game's server scripts

**Severity: high — it makes the game's own instrumentation unreadable by the
tool built to read it.**

The skill calls `bridge.exec` "the one you will reach for most". It shares the
DataModel with the running game but not the module cache, so `require` inside
an exec returns a *fresh* copy of every Forge module.

**Measured, decisively.** In one exec against a running server:

```
probes via the game's own ForgeDebug Command channel:  ["shift","session","store","exposure"]
probes via require(ReplicatedStorage.Forge).Debug:     []
```

Same DataModel — `ReplicatedStorage.ForgeDebug` (created by the game's
`Debug.expose()`) is visible from the exec. Different VM — the game's four
registered probes are not.

So `Debug.info`, `Debug.count`, `Debug.probe` and `Debug.logs` are all
invisible through `bridge.exec`. Early in this build that read as "my systems
never ran", which sent the investigation in the wrong direction.

**Workaround that does work:** drive the game's own `Debug.expose()` channel —
write a JSON command into `ReplicatedStorage.ForgeDebug.Command`, poll
`.Result`. That executes in the game's VM.

One detail that will cost somebody ten minutes: the channel fires on
`Changed`, so **writing the same command twice does nothing** and the second
read comes back as the stale value or an empty string. Polling a probe in a
loop needs the command string to differ each time — a nonce field, or clearing
`.Result` and alternating the payload.

**Suggested fix:** say this in the skill, and give `StudioBridge` a
`debug_snapshot()` that uses the Command/Result channel instead of leaving
every caller to discover the boundary.

---

## 3. `bridge.exec` does not work at all in a scaffolded game

**Severity: high — first-run blocker.**

Against a running server: `E_EXEC: loadstring() is not available`.

`forge new` does not set `ServerScriptService.LoadStringEnabled`, and exactly
**one of the 36 existing games** does (`valehold`). So the bridge's primary
command fails on every freshly scaffolded project, with an error that names a
Luau function rather than the place property that has to change.

**Cost:** a full rebuild and Studio restart cycle, because the property has to
be in the place file before the play session copies it.

**Suggested fix:** put it in the scaffold template, and have the bridge return
"set `ServerScriptService.LoadStringEnabled`" rather than "loadstring() is not
available".

---

## 4. The fix for #3 is a shipping vulnerability, and nothing guards it

**Severity: high — security.**

`LoadStringEnabled = true` lets any server-side string become executable code.
It is the right dev-loop setting and the wrong production one, and right now it
lives in `default.project.json`, which is what gets published.

There is no guard anywhere in the pipeline:

- `forge publish` does not check it or warn.
- `forge doctor` does not check it.
- `rqe/scanner.py:17` has a `dynamic_code` rule that matches `loadstring` — but
  it points at *third-party asset* source, not at the place's own properties.

So the sequence "the bridge does not work → enable loadstring → ship" is the
path of least resistance and nothing on it says stop. The scanner refusing a
Creator Store model for containing `loadstring` while the place itself enables
it is the specific shape of an inconsistency worth closing.

**Suggested fix:** `forge publish` refuses, or at minimum warns loudly, when
`LoadStringEnabled` is true and `--release` is passed.

---

## 5. The scaffold's self-test races the world it is testing

**Severity: medium — and its failure mode is a false green, which is worse than
a red.**

`init.server.lua` runs the live suite in a `task.defer` immediately after the
system loop finishes calling every `start()`. Its own comment says the suite
"runs after every system is up".

That is true and it is not the same as "after every system has finished". Any
system that builds a world *must* return from `start()` immediately and spawn
its work, or it deadlocks the systems waiting on its boot signal. So the suite
always runs against an unbuilt world.

**Measured, first run:**

```
passed=8 failed=3
  [FAIL] the world the game is played in actually got built
  [FAIL] the outpost has a generator, lamps and fuel to fetch
  [PASS] a lamp is lit exactly when the light reaches it     <-- against 0 lamps
```

The third line is the real problem. Every assertion in that scenario is inside
`for _, lamp in Outpost.lamps`, so against an empty list "all of them lit" and
"none of them lit" are both true and the scenario reports **passed**.

**Fixed in this game** by awaiting the boot signals before running the suite —
and note the second mistake, which is worth recording too: awaiting only
`cells_ready` still tested a world with no lamps, because `Outpost` and `Cells`
both wait on `ground_ready` and then race. It takes `Boot.awaitAll`.

**Suggested fixes:**
1. Have the scaffold await a documented "world ready" milestone.
2. Have `Testing` flag any scenario that finished with **zero checks executed**.
   The harness already counts checks per scenario; a scenario that asserted
   nothing is never a pass.

---

## 6. The Testing harness has no `skip`

**Severity: medium.**

`Context` offers `expect`, `expectEqual`, `expectNear`, `expectAlive`,
`expectDead`. There is no way for a scenario to say "this cannot be evaluated
in the current session".

The consequence is that any scenario needing something session-dependent — a
player, a published place, DataStore access — has to either fail honestly and
make the suite red on a legitimate run, or return early and report a pass it
did not earn. Both are wrong, and #5 shows what the second one costs.

---

## 7. The live suite runs concurrently with the live simulation

**Severity: medium — every scenario that touches game state is a race.**

`Forge.Testing` scenarios execute inside the running game, which is exactly what
makes them worth having: real instances, real Humanoids, real geometry. It also
means the game's own loops keep ticking underneath them, and nothing in the
harness offers a way to pause the world.

**Measured.** The scenario that exercises this game's core loop — lift a cell,
carry it to the generator, check the charge went up — reported:

```
[FAIL] lifting a cell and carrying it to the generator raises the charge
       - a cell delivered to the generator did not raise the charge
```

The game was fine. `Power` ticks twelve times a second and takes deposits from
anyone standing on the pad, so between the scenario teleporting the character
onto the pad and the scenario reading its baseline, the tick had already taken
the cell and raised the charge. The scenario then measured from *after* the
delivery and reported that nothing happened.

This is the harness's sharpest edge for exactly the scenarios most worth
writing, because the interesting ones are the ones that move the player around
and let the game react.

**Fixed in this scenario** by taking the baseline out at the ring while the cell
is still in hand, and by running the check during `dawn`, where the drain is
zero and deposits still count.

**Suggested fix:** a `Testing` affordance for "hold the world" — even just a
documented convention that systems check a `Testing.paused` flag in their tick —
plus a note in the scaffold that a scenario mutating shared state is racing
whatever else reads it.

## 8. A baked prop's `extents` are not the size it builds at

**Severity: medium — it is how a scene ends up with a wall in it.**

`Prop.place` scales by `targetHeight / spec.extents[2]`. Two things go wrong.

**The extents disagree with the built model.** Asking for a 14-stud storage
tank produced one measuring 31. Crates asked for at 2.2–3.4 came back at 9.

**One axis is not a size.** `Terrible Furnace` is baked at 4.8 × 0.8 × 4.8.
Asking for `targetHeight = 8` multiplies everything by 10 and produces a prop
**48 studs wide and 8 tall** — which is what put a stone wall across the middle
of the outpost in the first screenshot, hiding the generator the whole game
points at.

An audit of all 28 baked props found a wall-shaped variant (footprint more than
3.5× the height) filed under **bush, conveyor, furnace, log and pipe** — five of
the sixteen topics. `Camping Log Seat` is 8.1 long and 1.2 tall.

**Fixed in this game** with `src/server/core/Props.lua`: place, measure the
built model, correct the scale to the height actually asked for, reseat it on
the ground, and refuse anything whose footprint is still absurd for its role —
retrying at `seed + 1`, which picks the topic's other variant.

**Verified after the fix.** Re-measuring the outpost in the running game:
`GasStorage` came back 6.3 x **14.0** x 6.3 against a request for 14, the
48-stud furnace was gone — the retry had picked the topic's other variant, a
proper 8 x 8 x 8 `Furnace` — and the scenery scatter reported **zero** props
with a footprint over 20 studs.

**Suggested fixes:** record footprint alongside height in the bake so `Prop`
can offer a `targetSize`, and have `forge catalogue` flag the wall-shaped
variants rather than filing them under a topic a caller will trust.

---

## 9. `forge assets verify` is all-or-nothing, slow, and clobbers its own registry

**Severity: medium.**

The verifier itself is well built — it loads each id in Studio and refuses to
record a failure it has not seen, which is exactly right. Three things around it
are not.

**No scope.** Adding one sound to one game means re-verifying every asset in the
repository. A run over 192 ids took **roughly fifteen minutes** here, with no
`--game` or `--only` flag to narrow it.

**No progress until a chunk of twenty completes.** For most of those fifteen
minutes the process produced zero bytes of output, which is indistinguishable
from a hang — and this session had a real hang in the same neighbourhood
(finding #13), so the ambiguity costs a decision every time.

**`verify()` writes the whole registry**, not the ids it was asked about. A
scoped run would erase everything it did not check, and two runs in flight at
once silently clobber one another. Working around it meant calling the
`assets.verify` bridge command directly for nine ids and merging the result into
the registry by hand.

**Also worth flagging:** the full run reported a long wall of
`AssetFetchStatus.Failure` for `rbxassetid://12xxxxxxxxxxx` ids belonging to
other games in the repo. Whether those are genuinely broken or a batching
artefact, the registry now carries them as failures and the doctor will refuse
them for whoever owns those games.

**Suggested fix:** a `--only` / `--game` scope, per-id progress, and a merge
rather than a rewrite.

---

## 10. Roblox audio privacy makes almost every search result unusable, and nothing says so

**Severity: medium — a whole asset class that fails as silence.**

`toolbox.search(..., category=CATEGORY_AUDIO)` works and returns plenty. Almost
none of it can be played: Roblox's audio privacy rules make user-uploaded sound
private to its uploader, so an id lifted from a search result is overwhelmingly
likely to be silence in somebody else's place.

Searching ten queries and keeping only the **official licensed library** — clips
named `(SFX)`, uploaded by ProSoundEffects — narrowed several hundred results to
**nineteen distinct usable ids**, and only a handful were relevant to this game.

`forge shop` has `--official` for exactly this reason on the model side. Audio
search has no equivalent, and nothing in the pipeline warns that a private audio
id passes every check and then plays nothing.

**Suggested fix:** an `--official` equivalent for audio search, and a line in the
skill — verify the creator, not just that the id resolves.

## 11. `lifecycle.restart_for_bridge` crashes on string paths

**Severity: low — but it is the first call in the skill's own workflow.**

`rqe/hub/lifecycle.py:104`

```
TypeError: unsupported operand type(s) for /: 'str' and 'str'
```

`archive_recovery_files(archive_root)` does `archive_root / f"..."` and requires
a `Path`. The skill documents the call as
`lifecycle.restart_for_bridge(place_path, archive_path, bridge=bridge)` with no
indication that string paths are not accepted.

**Suggested fix:** `Path(archive_root)` at the top of the function.

---

## 12. `forge doctor` matches inside comments

**Severity: low — but a permanent false positive is a checker people stop
reading.**

```
error   src\server\systems\Power.lua:19  RenderStepped is client-only
```

Line 19 is prose inside a `--[[ ]]` block: a heading reading "Why 12Hz and not
RenderStepped", explaining why the file deliberately does not use it. The only
way to a clean doctor was to reword the documentation.

---

## 13. `stop_play_solo` reported success and the session kept running

**Severity: low.**

`stop_play_solo` returned `{"keySent": "Shift+F5", "stopped": false}` with the
correct Studio window focused, and the server session was still connected forty
seconds later. Recovering needed a full Studio restart.

Related: after the first `restart_for_bridge`, the hub at `127.0.0.1:8790` was
gone and had to be started again by hand. `restart_for_bridge` restarts Studio
but assumes the hub outlives it, and there is no note saying so.

---

## 14. `Terrain.MaxExtents` is a trap worth adding to the skill's list

**Severity: low — documentation.**

It is the *allowed* volume of the Terrain object, ±32000 on a completely empty
one. It has nothing to say about whether anything was written.

This build's own test used it to assert "terrain exists" and went green against
a world with no floor in it at all. The honest check is a raycast where the
player actually stands, and that is the version that caught #1.

---

---

## 15. A game's asset manifest is generated repo-wide, so other games' broken assets block yours

**Severity: high — it makes the security gate unpassable for a clean game.**

`brownout` references **exactly nine asset ids**, every one of them verified and
passing:

```
$ grep -roh "rbxasset[^\"']*" games/brownout/src | sort -u
rbxassetid://9112775414   rbxassetid://9112795463   rbxassetid://9112795583
rbxassetid://9112840253   rbxassetid://9113848518   rbxassetid://9114057128
rbxassetid://9116771817   rbxassetid://9116948636   rbxassetid://9125446564
```

Its generated manifest, `games/brownout/assets/asset-manifest.json`, holds
**46 entries**, of which **33 are marked `rejected`**. Among them:
`rbxassetid://0`. None of the rejected ones appear anywhere in this game's
source — they are the repository-wide verified registry, copied in wholesale.

The Quality Engine then reports:

```
security.asset_manifest   FAIL (critical)  Manifesto de assets invalido ou incompleto
  assets[4].status precisa ser approved ... assets[45].scriptScan precisa ser clean
assets_are_traceable      fail (admissible evidence is not positive: FAIL)
```

So a game whose own assets are entirely clean fails the security gate on the
verification status of assets belonging to other people's games. It cannot be
fixed from inside the game.

**Note in passing:** the same run's `security.asset_scripts` probe passed — 16
scripts scanned, no suspicious patterns — and **did not flag
`LoadStringEnabled` in the project file**, which is finding #4 confirmed by the
platform's own security probe.

**Suggested fix:** generate the per-game manifest from the ids the game actually
references — `forge assets scan` already computes exactly that.

---

## 16. The release gate is not passable, and some of it is structurally unproducible

**Severity: medium — a gate nobody can clear is a gate people route around.**

`forge quality brownout` blocks with 24 blockers on a first run, which the tool
itself says is expected. The problem is what the blockers are.

Nine of them are **`unproducible`**, not failed:

```
the_landmark_reads: unproducible
  (quality.snapshot-validator: status is PARTIAL; not integrated into the
   immutable release runner; source 'visual-review' is not allowed)
```

The visual validators exist, run, and produce answers — they are simply not
wired into the release runner, and the runner refuses their evidence. No amount
of work on a game changes that.

**And no game in this repository has ever passed.** `provingground`, the most
mature project here, has 40-odd recorded release runs; its best still carries
**27 blockers**.

What did pass on a first run is worth saying, because it is the part that works:

| category | score |
| --- | --- |
| performance | 100 (2,475 instances against a 40,000 budget) |
| runtime | 100 |
| structural | 80 |
| navigation | 0 — *coverage* zero, meaning unmeasured |
| security | 0 — blocked by finding #15 |
| visual | 5.6 — blocked by the unproducible validators |

`world.spawn_exists` is the sharpest example of the coverage problem: it reports
`status: PASS` and `coverage: 0.0, conclusive: false` in the same record. A pass
that does not count toward the thing it passed.

---

## 17. `local_credentials.describe()` reports the key expired while it authenticates

**Severity: low — but it is the diagnostic the skill tells you to trust first.**

```
forge publish brownout --check  ->  key: authenticates (HTTP 200)
describe()["expiresAt"]         ->  1786576386  =  2026-08-12
today                           ->  2026-08-27
```

The key works. The metadata says it stopped working fifteen days ago. The skill
says "when Open Cloud starts answering 401, check that before anything else" —
so the one field a person is told to trust is the one that disagrees with
reality, in the direction that causes a wild goose chase.

---

## 18. Smaller things

- **`forge gametest <game>` does not take a game.** The skill documents it that
  way; the parser answers `unrecognized arguments: brownout`. It runs against
  whatever session is live.
- **One report, two languages.** Quality Engine evidence mixes Portuguese
  (`Manifesto de assets invalido ou incompleto`) and English (`Live Studio
  answered through the bridge`) in the same JSON, sometimes in adjacent records.

# Opportunities, not defects

**The bake is the bottleneck.** 365 assets are catalogued; 28 are baked, across
16 topics, two per topic at best. A game that wants scenery variety runs out
almost immediately — this one places 190 props drawn from eight topics and the
repetition is visible. Baking is the step between "catalogued" and "usable" and
it is where the leverage is.

**`Prop.place` returns nil for an unknown topic, silently.** A typo'd topic name
is an invisible no-op that leaves a hole in the scene with no line of code to
trace it back to. A `warn` costs nothing.

**`Net.define` being per-VM is documented and unenforced.** Both sides declaring
the same list is load-bearing, and the failure — a button that works in Studio
and does nothing live — is expensive. `Net` could hash its manifest and compare
on the first packet.

**Nothing in the toolchain can see overexposure, and it is the most common way
a lit scene goes wrong.** Three separate visual defects in this build were
invisible to `forge doctor`, to the type checker and to twelve passing
scenarios, and each took a screenshot to find: terrain restained to a warm sand
in a game about darkness, a HUD panel behind the Roblox topbar, and a player
rendered as a white blob because four lamps of the inner ring overlapped on the
generator pad while the bloom threshold sat at 1.05.

The last one is worth a check. `Visual.defineLook` accepts any bloom threshold,
and below roughly 1.2 every ordinary lit surface blooms — which reads as a
broken renderer rather than as a chosen look. A warning at define time would
cost nothing. Measuring the fraction of blown-out pixels in a capture would
cost a little more and would catch all three.

**A `forge run` that does build → restart → play → report in one command.**
That cycle ran seven times during this build, each time as four separate calls
of my own with a three-minute wait, and getting the order or the arguments
wrong is most of what went wrong above.

---

# What the platform got right

Worth saying, because the list above is only failures.

**The measured-trap documentation is real and it saved time.** `Model:GetExtentsSize()`
being pivot-oriented, `MeshPart.MeshId` being unwritable, `Net.fire` being
server-only — these were correct, specific, and would each have cost hours.

**`Forge.Core.Boot` is the right shape.** A latch that returns instantly when
already signalled makes the whole "systems start in an arbitrary order and wait
for what they need" pattern safe to write. Two of the bugs above were found
*because* the boot signals made the ordering explicit enough to reason about.

**`Net` makes the safe path the easy one.** Declaring a channel with a rate and
a shape is less typing than not doing it, which is the only reason that kind of
rule ever holds.

**The asset scanner refusing `require(<id>)` is the right call**, and the
"blocked" / "read-it" split is the reason it stays useful instead of becoming a
thing people click past.

**The screenshot is the criterion, and it earned that.** The terrain being the
brightest thing on screen in a game about darkness, the gauge sitting behind the
Roblox topbar, and the 48-stud furnace were all invisible to `forge doctor`, to
the type checker, and to eleven passing scenarios. One look found all three.
