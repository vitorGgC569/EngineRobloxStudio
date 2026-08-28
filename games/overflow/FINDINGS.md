# What building `overflow` found

A second game on this platform, against the updated skill. Several findings from
the first pass are now fixed in the engine — recorded at the end, because a
report that only ever grows is a report nobody believes.

---

## 1. The account is moderated, and the engine's own content pipeline is what did it

**Severity: critical — it disables every published asset in the engine.**

```
$ curl -H "x-api-key: …" https://apis.roblox.com/assets/v1/assets/104285640237364
HTTP 403 {"errors":[{"code":0,"message":"User is moderated"}]}
```

Measured inside Studio, signed in as the owning account (`5812220258`), every
asset id answers 403 — on **reads**:

| id | what | result |
| --- | --- | --- |
| `104285640237364` | ItchAssets model, this account | 403 |
| `108832923675081` | ItchIcons image, this account | 403 |
| `9112775414` | ProSoundEffects sound, verified working the day before | 403 |
| `1818` | a public Roblox asset from 2006 | 403 |

The last row is the decisive one. This is not about which assets; it is the
account.

**And the cause is the pipeline itself.** `ItchAssets` records *470 models
published 2026-08-27*; `ItchIcons` records *348 icons and 59 sheets, published
2026-08-27*. That is roughly 880 uploads in one day. The skill's own trap list
says it arrives "after roughly a thousand uploads in a few hours" and is "an
account state, not a rate limit you can wait out".

So the engine published the catalogues that the skill now tells a game to build
on, and the act of publishing them took away the ability to load them.

**What it costs a game.** Unusable for this build: `Forge.Catalog.ItchAssets`
(470 models across 63 topics), `Forge.UI.ItchIcons` (whole icons, sprite sheets
and every nine-slice frame), `Forge.Catalog.Place` (which is `LoadAsset` plus
scaling), and every `rbxassetid://` sound. `overflow` is built from the 32 baked
props, procedural geometry, `rbxasset://` client built-ins and `UI.theme`.

**Suggested fix:** publish in batches with real gaps, and record the upload
count and date in the generated catalogue so the next person can see how close
to the line the account is. A `forge assets health` that makes one read and
reports "moderated" would turn a two-hour mystery into one line.

---

## 2. The moderation also breaks Roblox's own character animations, and that fails the gate

**Severity: high — the quality gate cannot go green for reasons a game cannot fix.**

```
error  a script errored
       Failed to load animation with sanitized ID rbxassetid://507785072:
       assetId: https://assetdelivery.roblox.com/v1/asset?id=507785072&serverplaceid=0
```

Between 24 and 32 of these per run, from Roblox's stock walk/run/idle set, which
the `Humanoid` requests for every spawned character. `forge playtest` counts any
output error as an `error`, so the run fails.

Destroying Roblox's `Animate` LocalScript on `CharacterAdded` **before** waiting
on anything took 25 down to 24 — so most of these come from the Humanoid itself,
not the script, and there is nothing a game can do about them.

`MeshContentProvider failed to process … 'could not fetch'` appears the same way
for baked props carrying a `SpecialMesh`.

**Suggested fix:** `playtest` should separate errors raised *by the game's own
scripts* from asset-delivery failures. They are different problems with
different owners, and folding them together means one broken account makes every
game in the repository un-shippable.

---

## 3. The live suite's race does not just cause flaky failures — it points at the wrong code

**Severity: high. This is the sharpened version of a finding from the first game,
and it cost four full build cycles here.**

The scenario that exercises the core loop reported, run after run:

```
[FAIL] a crate in an open gate is taken, scored, and gone
       - a correct sort in an open gate scored nothing
       - a correct sort was not counted
```

Every word of that is about scoring, and the scoring code was correct the whole
time. What was wrong was the scenario waiting on the game's own 30Hz loop while
the live shift kept running underneath it — crates overflowing, strikes landing,
`endShift` calling `Line.clear()` and destroying the crate under test.

The diagnosis took four cycles because each fix moved the symptom without
removing it:

1. clearing the belt first → still failed
2. asserting the chute could see the crate → **that passed**, so the lookup was fine
3. asserting the pairing was correct before the gate opened → **that passed too**
4. exporting the resolution and calling it **synchronously** → 13/13

Only the fourth changed the answer, and it changed it by removing time from the
measurement rather than by fixing any game code.

**The lesson is stronger than "tests can be flaky".** A racing scenario produces
a failure message that names an innocent module, and a person reading it in good
faith goes and reads the scoring code — which is correct — and concludes the test
is lying, which it is, but not in the way they will guess.

**Suggested fix:** the harness needs a way to hold the world. Even a documented
`Testing.paused` flag that systems check at the top of their tick would make the
difference between a scenario that measures one thing and one that measures the
weather.

---

## 4. A `SpawnLocation` faces −Z, so an unrotated pad spawns players backwards

**Severity: medium — one full build cycle, and it belongs in the traps list.**

The first playable build opened on a blank wall. Measured by raycasting from the
spawned character's own eye:

```
facing        0.00, -0.00, -1.00
forward(+Z)   nothing within 200      <- the belt is this way, 13 studs off
back(-Z)      Mill.Wall1 at 31 studs  <- what the player is looking at
```

The belt, the chutes, the crates and the entire game were behind the player. The
world was built correctly and had been measured as correct — 4 chutes, a
156-stud belt, 5 crates riding it — and none of it was on screen.

A character spawns facing its pad's `LookVector`, and an unrotated part looks
down −Z. One `CFrame.Angles(0, math.pi, 0)` fixes it.

**Suggested fix:** one line in the skill's traps list. It is invisible in code,
it survives every test that checks the world exists, and the symptom — "my game
is empty" — sends you to look at the world builder.

---

## 5. `camera.focus` did not move the play session's rendering camera

**Severity: medium.**

Two `capture_viewpoint` calls with different targets (`Workspace.Mill.Belt` and
`Workspace.Chutes.Chute_grain`, different pitch and yaw) both reported success
and both returned **identically framed** images — the same view the player's own
camera had. The HUD renders in those shots, so they are the client's view; the
focus call did not reach it.

`rqe/capture.py` half-anticipates this: its own docstring records that framing a
target "made every attempt to photograph the world from a player's eye come back
as the same aerial shot". The failure here is the mirror image and equally
silent — it returns a `Shot` with `trustworthy=True`.

**Consequence:** there is no reliable way to photograph a specific object in a
running game, which is exactly what you want when a scenario says a thing is
built and you cannot see it. The workaround was to place the camera from the
client, which a game can do and a tool cannot.

---

## 6. `forge playtest` reports `buttons 0` for a game with eight of them

**Severity: medium — the touch-target check silently does not run.**

`overflow` has four purchase buttons in the workshop and two touch controls.
Every run reports:

```
buttons        0
```

because the panel holding them is `Visible = false` when the UI is measured, and
the count comes from that pass. The 44-pixel minimum is therefore checked
against nothing — on a game whose buttons are all inside panels, which is most
games.

It is a warning-level check, so it never fails a build. It also never fires.

**Suggested fix:** measure after each `--panel` is opened as well as before, or
count buttons regardless of visibility and check size only on the visible ones.

---

## 7. Smaller things

- **`{ BasePart, Vector3 }` is a parse error, not a type error.** Luau's `{T}` is
  an array of T; a two-element tuple written that way stops the module loading
  entirely. `forge doctor` **caught this** — see the fixed list below — which is
  new and good.
- **The topic classifier in `ItchAssets` is unreliable, but `pack` is not.**
  "Pizza Box Close" is filed under `ammo box`, "Conference Desk" under
  `desk lamp`, and 26 of 470 models have no topic at all. This is the
  substring-classification trap the skill's own list warns about, still live in
  the generated catalogue. Grouping by `pack` gives clean, coherent sets —
  `PSX style office pack` is 40/41 textured, `going medieval` 38/42.
- **Two thirds of the catalogue arrives grey and the split is by pack, not by
  format.** `(Legacy) KayKit - Dungeon Pack` is 37 models and **4** textured;
  Spooktober is 12 and **zero**. A game choosing a topic cannot tell; a game
  choosing a pack can.

---

# Fixed since the first game

Worth recording, because these were findings and now are not.

- **`forge new` sets `ServerScriptService.LoadStringEnabled`**, so `bridge.exec`
  works against a running server in a freshly scaffolded project. Was finding #3.
- **`forge doctor` compiles the Luau.** It caught an invalid type annotation
  that would have loaded as nothing. It previously only pattern-matched.
- **`forge playtest` exists**, and is exactly the thing whose absence was the
  loudest finding of the first game: something that looks at the screen and
  fails. Its panel mechanism — a `BindableFunction` at
  `ReplicatedStorage.<Game>UI` driven by `client.invoke_bindable` — worked first
  try and is the right shape, because it drives the game through the same
  function the keyboard calls.
- **The skill now documents `bridge.exec` running in a different Lua VM**, which
  was finding #2 and cost real time to establish.
- **`Forge.Catalog.Place` does the whole placement job** — pick, fetch, turn,
  scale, seat on the ground, tint — which is the hand-rolled `Props.lua` from the
  first game, done properly and in the engine. It could not be used here, but
  only because of finding #1.
