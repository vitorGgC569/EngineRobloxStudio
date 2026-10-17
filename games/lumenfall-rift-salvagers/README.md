# lumenfall-rift-salvagers

# DOGFOOD GAME BRIEF — Lumenfall: Rift Salvagers

## Product intent
Build an original Roblox vertical slice that is fun before it is large. The player is a Rift Salvager diving from a floating hub into fractured sky-islands to recover volatile Lumen cores, survive corrupted constructs, power an extraction beacon, and escape before a dimensional storm collapses the route home.

This project exists both as a game and as an adversarial dogfood of the RobloxGamesMCP/RQE/Forge stack. Prefer engine primitives and typed production surfaces over one-off implementation. Any engine limitation encountered must be recorded rather than silently worked around.

## Core fantasy
Fast expedition + extraction + permanent forge-station progression.

A run should create the loop:
1. choose a loadout in the hub;
2. enter a generated island route;
3. traverse with sprint, dash and grapple points;
4. fight corrupted constructs;
5. harvest Lumen from dangerous nodes;
6. decide whether to push deeper for better rewards;
7. activate an extractor and survive a defense phase;
8. escape;
9. spend recovered Lumen on permanent upgrades;
10. repeat with new route pressure and build choices.

## Vertical-slice target
One polished 8–12 minute expedition containing:
- a hub/forge station;
- three connected island biomes;
- one traversal challenge;
- three enemy archetypes;
- one elite;
- one extraction defense;
- one boss encounter;
- permanent progression;
- death/failed-extraction recovery;
- first-run onboarding;
- settings/accessibility;
- desktop + mobile controls.

## Combat
Readable third-person action combat.
- light melee combo;
- charged attack;
- dash with invulnerability window;
- ranged utility tool with cooldown;
- hit stun / knockback where appropriate;
- enemy telegraphs;
- health/shield;
- deterministic server-authoritative damage;
- no client-authoritative rewards.

Enemy archetypes:
- Skitter: fast melee flanker;
- Sentinel: ranged line attack with visible telegraph;
- Bulwark: slow armored unit, vulnerable after slam;
- Rift Warden elite: combines area denial and summons.

Boss: The Hollow Engine.
Three readable phases, no instant kills, arena hazards, exposed weak point after telegraphed attacks.

## Traversal
- grounded movement;
- sprint;
- dash;
- authored grapple anchors;
- jump route across floating islands;
- kill planes / recovery volumes;
- navigation must remain valid for AI;
- traversal cannot rely on pixel-perfect jumps.

## World
Art direction: luminous ruined industrial fantasy suspended in a violet-blue storm.
Strong silhouettes, dark stone/metal, warm Lumen emissive accents, fog depth, moving environmental machinery.

Biomes:
1. Lantern Reach — readable onboarding ruins;
2. Shattered Foundry — machinery, verticality and combat;
3. Storm Crown — exposed final approach and boss arena.

World must be readable from gameplay camera and not only from staged screenshots.

## Economy/progression
Run resource: unstable Lumen Essence, lost partially on failure.
Permanent modeled currency: refined Lumen Essence, banked only after extraction.

Upgrade categories:
- health capacity;
- dash recharge;
- melee power;
- utility cooldown;
- extractor efficiency.

A run also offers temporary choice nodes with mutually exclusive upgrades so repeated runs can feel different.

No paid products are required for this dogfood build.

## Persistence
Persist:
- permanent currency;
- unlocked upgrades;
- settings;
- best expedition depth;
- onboarding completion.

Must tolerate reconnect and duplicate save attempts. No reward may be granted twice from one extraction receipt.

## UI/UX
Minimal, game-first HUD:
- health/shield;
- Lumen carried;
- current objective;
- utility cooldown;
- extraction timer when active.

Hub UI:
- upgrade forge station;
- loadout;
- expedition start;
- settings.

Mobile:
- touch controls must remain usable without covering combat information;
- buttons need safe spacing and sensible thumb reach.

Accessibility:
- reduced camera shake option;
- damage flash intensity option;
- readable contrast;
- no essential information by color alone.

## Audio/VFX
- responsive hit feedback;
- distinct enemy warning sounds;
- Lumen pickup feedback;
- extraction escalation;
- boss phase cues;
- ambient storm + machinery layers.

Never invent Roblox asset IDs. If verified assets are unavailable, prefer procedural/engine-generated placeholders that are visually coherent and record the sourcing gap.

## Quality targets
- 60 FPS desktop target in vertical slice;
- stable frame pacing;
- no runtime errors;
- no unanchored world debris unless intentional;
- no inaccessible objectives;
- no overlapping exclusive gameplay regions;
- gameplay scenario must be executable by an agent;
- screenshots from required viewpoints must be trustworthy;
- release remains fail-closed if evidence is missing.

## Required scenarios
1. Fresh player completes onboarding and starts expedition.
2. Player defeats each enemy archetype.
3. Player harvests Lumen and sees currency increase once.
4. Player activates extraction, survives defense and returns to hub.
5. Permanent upgrade purchase reduces currency and persists.
6. Repeating the same purchase/extraction receipt cannot duplicate reward.
7. Failure before extraction loses the intended run currency and does not corrupt permanent state.
8. Boss can be reached and defeated.
9. Navigation/pathing does not strand the player or AI.
10. Mobile HUD/layout remains usable at phone aspect ratio.

## Dogfood rules
- Use producer/full profile first.
- Scaffold a real project.
- Prefer Forge/RQE capabilities over bespoke code.
- Run doctor, Luau compile, tests, build, Studio runtime, gameplay scenarios, captures and full quality/release evaluation.
- Every refusal, missing producer, manual intervention, broken abstraction, duplicated implementation or misleading green verdict becomes a gap report.
- Do not lower quality gates merely to make the run green.
- Do not replace real runtime evidence with fixtures.

**roguelite** / luminous ruined industrial fantasy in a violet-blue dimensional storm

    loop:        explore -> fight -> collect -> unlock
    topology:    linear_levels
    progression: checkpoint, 8 tiers
    currencies:  essence
    systems:     progression, save, inventory, analytics

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/lumenfall-rift-salvagers/game.json
    rqe game compile   games/lumenfall-rift-salvagers/game.json
    python rqe.py release games/lumenfall-rift-salvagers --static-only

The release command is expected to remain blocked until a human-approved
ProductIntent, an independent reference benchmark, its complete calibration,
approved production assets and product-specific E2E scenarios replace the
typed placeholders. A scaffold is an operational release project, not release
evidence.
