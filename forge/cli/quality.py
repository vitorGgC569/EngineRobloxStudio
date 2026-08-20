"""Marry the Quality Engine to Forge.

The two halves
--------------

This repository has contained both halves of the problem for months and they
have never spoken.

`forge` is the authoring half: it builds worlds, rigs, combat, netcode and a
live suite that proves a game *works*. Nothing in it measures whether the game
is any **good** — whether the world is readable, the geometry sound, the UI
legible on a phone, the frame budget survivable. An agent using Forge alone can
ship something that passes thirty-eight scenarios and is dreadful.

`rqe` is the validation half, and it is exactly what is missing: thirty probes
across geometry, navigation, visual composition, UI, performance, security and
persistence, with a scoring model and a release gate. It was written first,
judged "too rigid, lost in determinism", and set aside — because it had nothing
worth validating. It was never useless; it was early.

This module is the seam. It derives an RQE project descriptor and contract
from a Forge game's actual shape, so `rqe audit` runs against something built
with `forge new` without anyone hand-writing thirty-five requirements.

    forge quality provingground            generate the descriptor and audit
    forge quality provingground --generate only write the descriptor

What is derived, and what is a decision
---------------------------------------

Everything structural is derived: where the source lives, which rojo project
builds it, which containers exist, what the game is called. Those are facts
about a Forge project and hand-writing them is how they drift.

What is *not* derived is the bar. Which probes must pass, and at what score, is
a decision about a specific game — a jam entry and a flagship do not owe the
same thing. So the generated contract carries a defensible default and is meant
to be edited, not regenerated forever.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]


class QualityError(RuntimeError):
    pass


def game_dir(game: str) -> Path:
    path = REPO / "games" / game
    if not path.exists():
        raise QualityError(f"no game at games/{game}")
    return path


def _config_value(game: str, key: str, default: Any = None) -> Any:
    """Read one field out of a Forge game's Config.lua.

    A parser rather than an import, because Config is Luau and this is Python.
    Deliberately narrow: it reads the literals a descriptor needs and leaves
    everything else alone rather than pretending to understand Lua.
    """
    config = game_dir(game) / "src" / "shared" / "Config.lua"
    if not config.exists():
        return default
    text = config.read_text(encoding="utf-8", errors="ignore")

    match = re.search(rf'{key}\s*=\s*"([^"]*)"', text)
    if match:
        return match.group(1)
    match = re.search(rf"{key}\s*=\s*(-?\d+(?:\.\d+)?)", text)
    if match:
        value = match.group(1)
        return float(value) if "." in value else int(value)
    match = re.search(rf"{key}\s*=\s*\{{([^}}]*)\}}", text, re.S)
    if match:
        return re.findall(r'"([^"]+)"', match.group(1))
    return default


#: The probes a Forge game can meaningfully answer, and how much each matters.
#:
#: Not every probe in the catalogue: several were written for a specific
#: tycoon and ask about plots and card galleries. Including them would produce
#: a contract that fails for reasons unrelated to quality, and a gate that
#: fails for irrelevant reasons is a gate people disable.
FORGE_REQUIREMENTS: list[dict[str, Any]] = [
    # Structure — the cheapest checks and the ones that catch a broken project.
    {"id": "project_topology", "probe": "structural_integrity",
     "type": "structural", "severity": "critical"},
    {"id": "contract_is_valid", "probe": "contract_schema",
     "type": "structural", "severity": "critical"},

    # Security — asset provenance and the wire. Forge has strong opinions here
    # and this is where they get checked rather than asserted.
    {"id": "assets_are_traceable", "probe": "asset_security",
     "type": "security", "severity": "critical"},
    {"id": "remotes_are_validated", "probe": "remote_security",
     "type": "security", "severity": "critical"},

    # Geometry — what a world built by `World.scatter` gets wrong.
    {"id": "spawn_is_supported", "probe": "spawn_support",
     "type": "geometry", "severity": "critical"},
    {"id": "nothing_floats", "probe": "floating_objects",
     "type": "geometry", "severity": "major"},
    {"id": "nothing_is_buried", "probe": "buried_objects",
     "type": "geometry", "severity": "minor"},
    {"id": "props_do_not_intersect", "probe": "collision_overlap",
     "type": "geometry", "severity": "major"},

    # Navigation — now that Forge has a navmesh layer, this is answerable.
    {"id": "spawn_reaches_objectives", "probe": "path_exists",
     "type": "navigation", "severity": "critical"},
    {"id": "objectives_are_reachable", "probe": "objective_reachable",
     "type": "navigation", "severity": "critical"},

    # Gameplay — the world is standable and its interactions are usable.
    {"id": "spawn_is_clear", "probe": "spawn_clearance",
     "type": "gameplay", "severity": "critical"},
    {"id": "interactions_are_in_reach", "probe": "interaction_distance",
     "type": "gameplay", "severity": "major"},

    # UI — the half Forge's own tests cannot see.
    {"id": "ui_fits_the_screen", "probe": "ui_overflow",
     "type": "ui", "severity": "major"},
    {"id": "ui_is_visible", "probe": "ui_visibility",
     "type": "ui", "severity": "major"},

    # Visual — the entire reason this marriage is worth making.
    {"id": "the_world_photographs_well", "probe": "visual_quality",
     "type": "visual", "severity": "minor"},
    {"id": "snapshots_exist", "probe": "visual_snapshot_bundle",
     "type": "visual", "severity": "major"},
    {"id": "camera_is_not_blocked", "probe": "camera_obstruction",
     "type": "visual", "severity": "minor"},

    # Performance — Forge measures frame cost in its own suite; this measures
    # the budgets that suite cannot see.
    {"id": "within_instance_budget", "probe": "performance_budget",
     "type": "performance", "severity": "major"},
    {"id": "no_connection_leak", "probe": "duplicate_connections",
     "type": "performance", "severity": "major"},
    {"id": "no_instance_growth", "probe": "instance_growth",
     "type": "performance", "severity": "major"},

    # Persistence and multiplayer — proven by Forge's scenarios, checked here
    # from the outside, which is a different and complementary thing.
    {"id": "progress_survives_rejoin", "probe": "persistence",
     "type": "persistence", "severity": "critical"},
    {"id": "players_are_isolated", "probe": "multiplayer_isolation",
     "type": "multiplayer", "severity": "critical"},

    # Runtime — a console error is a defect regardless of what else passed.
    {"id": "no_console_errors", "probe": "runtime_error",
     "type": "runtime", "severity": "critical"},
]


# ============================== the visual spec ==============================
#: The names the game marks its world with, and the spec looks for.
#:
#: One constant here, one in the game's Arena. They must agree, and the test
#: suite asserts they do — a mismatch is silent on both sides: the spec finds
#: nothing and the game marks something nobody asked about.
LANDMARK_ID = "arena-ring"
REGION_PROFILE = "arena"


def palette_of(game: str, wanted: int = 10) -> list[dict[str, Any]]:
    """The colours this game actually uses.

    Read out of its own source rather than invented. A palette somebody typed
    is a palette the game drifts away from within a week; a palette derived
    from every `Color3.fromRGB` in the project *is* the game, which is the
    only thing worth holding it to.

    Ordered by how often each colour appears, so the dominant role goes to the
    colour that actually dominates.
    """
    counts: Counter = Counter()
    for path in (game_dir(game) / "src").rglob("*.lua"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        for match in re.finditer(
                r"Color3\.fromRGB\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)", text):
            counts[tuple(int(value) for value in match.groups())] += 1

    swatches: list[dict[str, Any]] = []
    for index, (rgb, _count) in enumerate(counts.most_common(wanted)):
        if index == 0:
            roles = ["dominant"]
        elif index < 4:
            roles = ["supporting"]
        else:
            roles = ["accent"]
        swatches.append({"id": "swatch-%02d" % index, "rgb": list(rgb), "roles": roles})

    # The schema demands at least three. A game with fewer than three distinct
    # colours has a real problem, and it is not this file's job to hide it.
    while len(swatches) < 3:
        index = len(swatches)
        swatches.append({
            "id": "swatch-%02d" % index,
            "rgb": [128, 128, 128],
            "roles": ["supporting"],
        })
    return swatches


def measured_viewport(game: str | None = None,
                      default: tuple[int, int] = (1920, 1080)) -> list[int]:
    """The resolution this rig can actually photograph.

    The Quality Engine compares a shot's viewport against the declared one
    exactly, so that two runs a week apart are comparable and a phone shot is
    never mistaken for a desktop one. Nothing here can resize a Studio window,
    so a declared 1920x1080 against a 1096x675 window is a gate that can never
    close — the number has to come from the rig rather than from a wish.

    Measured once, at generation time, over the bridge. If the window is later
    resized the gate fails, and that is right: the evidence is no longer
    comparable to what the contract was written against. Regenerate, and the
    change is a visible edit to a committed file.
    """
    try:
        proc = subprocess.run(
            [sys.executable, str(REPO / "rqe.py"), "studio", "call", "camera.get"],
            capture_output=True, text=True, timeout=60, cwd=str(REPO))
        # `rqe studio call` prints its envelope on stderr, not stdout. Reading
        # only stdout got an empty string, fell through to the default, and the
        # spec quietly declared a resolution no window here has.
        envelope = json.loads(proc.stdout.strip() or proc.stderr.strip() or "{}")
        size = ((envelope.get("result") or {}).get("viewportSize")) or []
        if isinstance(size, list) and len(size) == 2 and int(size[0]) > 64:
            return [int(size[0]), int(size[1])]
    except Exception:  # noqa: BLE001 - a missing Studio is not an error here
        pass

    # [[
    #     Keep the last calibration rather than inventing one.
    #
    #     Measuring fails whenever Studio is mid-session: a running server
    #     answers (1, 1), which is rejected above, and the fallback then wrote
    #     a resolution no window on this machine has. Every regenerate during
    #     a run therefore quietly undid the calibration and the gate blocked on
    #     a number nobody chose.
    #
    #     So a spec that already carries a measured resolution keeps it. The
    #     bare default is for a project that has never been calibrated at all.
    # ]]
    if game:
        existing = game_dir(game) / "contracts" / "visual" / "visual-quality.json"
        if existing.exists():
            try:
                spec = json.loads(existing.read_text(encoding="utf-8"))
                previous = spec["viewpoints"]["play-desktop"]["resolution"]
                if isinstance(previous, list) and len(previous) == 2:
                    return [int(previous[0]), int(previous[1])]
            except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError):
                pass
    return [int(default[0]), int(default[1])]


def build_visual_spec(game: str) -> dict[str, Any]:
    """A visual quality spec derived from what the game marks and uses.

    Everything here is either read from the project or is a stated default a
    person is meant to argue with. The thresholds are the second kind: they
    are the bar, and the bar is a decision about a specific game.
    """
    resolution = measured_viewport(game)
    rubric = {
        # Legibility weighted highest on purpose. A scene can be beautifully
        # composed and unreadable, and an unreadable scene is a broken game
        # while an unbalanced one is only a plain game.
        "composition": 0.2,
        "hierarchy": 0.2,
        "legibility": 0.25,
        "materiality": 0.15,
        "polish": 0.2,
    }

    return {
        # Relative, and resolved inside the game directory: the Quality Engine
        # refuses a schema path that escapes the project, so that a release run
        # is self-contained and cannot be changed by editing something outside
        # it. `generate` copies the canonical schema in for exactly that reason.
        "$schema": "../../schemas/visual-quality-spec.v1.schema.json",
        "schemaVersion": 1,
        "specId": "forge.%s.visual" % game,
        "productId": game,
        "productTruth": {
            "intentId": "forge.%s.intent" % game,
            "calibrationId": "forge.%s.visual-calibration" % game,
            "semanticBindings": {
                "worldRoles": {
                    LANDMARK_ID: {
                        "landmarkIds": [LANDMARK_ID],
                        "regionSetIds": ["play-regions"],
                        "viewpointIds": ["play-desktop"],
                    },
                },
                "uiSurfaces": {
                    "hud": {
                        "landmarkIds": [],
                        "regionSetIds": [],
                        "viewpointIds": ["play-desktop"],
                    },
                },
            },
        },
        "revision": 1,
        "units": {
            "distance": "stud",
            "density": "visualRootsPer1000SquareStuds",
            "colorDifference": "CIEDE2000",
        },
        # Verbatim from `Forge.Mark.TAGS` and `Forge.Mark.ATTRIBUTES`. This is
        # the join between the two halves, and the reason a Forge world can be
        # looked at at all.
        "classification": {
            "candidateTag": "RQEVisualCandidate",
            "rootTag": "RQEVisualRoot",
            "typeAttribute": "VisualType",
            "variantAttribute": "VisualVariant",
            "assetKeyAttribute": "AssetKey",
            "regionTag": "RQEVisualRegion",
            "regionProfileAttribute": "VisualRegionProfile",
            "landmarkTag": "RQELandmark",
            "landmarkAnchorTag": "RQELandmarkAnchor",
            "excludeTag": "RQEVisualExclude",
            # Not 1.0: a live game has effects and debris that appear between
            # the tagging pass and the photograph, and demanding perfection
            # here fails a build for a particle.
            "minimumClassifiedFraction": 0.9,
        },
        "palette": {
            "swatches": palette_of(game),
            "maximumDeltaE": 12,
            "maximumOffPaletteFraction": 0.2,
        },
        "objectTypes": {
            "rock": {
                "selector": {"tag": "RQEVisualRoot",
                             "attributeEquals": {"VisualType": "rock"}},
                "minimumInstances": 12,
                "scale": {
                    "boundsMethod": "oriented-box",
                    "minimumSize": [1, 1, 1],
                    "maximumSize": [40, 40, 40],
                    # Scatter draws from a catalogue of real props whose sizes
                    # genuinely differ, so a tight deviation here would fail
                    # the variety that makes a field look natural.
                    "maximumRelativeMad": 0.9,
                },
            },
            "plant": {
                "selector": {"tag": "RQEVisualRoot",
                             "attributeEquals": {"VisualType": "plant"}},
                "minimumInstances": 12,
                "scale": {
                    "boundsMethod": "oriented-box",
                    "minimumSize": [0.5, 0.5, 0.5],
                    "maximumSize": [40, 60, 40],
                    "maximumRelativeMad": 0.9,
                },
            },
        },
        "regionProfiles": {
            REGION_PROFILE: {
                "density": {
                    # An arena floor is meant to be mostly clear. Scenery
                    # belongs at its edges, and a fighting surface packed with
                    # props is a fighting surface nobody can fight on.
                    "minimumRootsPer1000SquareStuds": 0.5,
                    "maximumRootsPer1000SquareStuds": 12,
                    "minimumFootprintCoverage": 0.01,
                },
                "heightVariation": {
                    "minimumP90MinusP10": 1,
                    "maximumP90MinusP10": 60,
                },
                "materialVariety": {
                    "minimumDistinctMaterials": 2,
                    "maximumDominantFraction": 0.9,
                },
                "repetition": {
                    "maximumIdenticalVariantRun": 6,
                    "minimumVariantEntropy": 0.5,
                },
            },
        },
        "regionSets": {
            "play-regions": {
                "selector": {"tag": "RQEVisualRegion",
                             "attributeEquals": {"VisualRegionProfile": REGION_PROFILE}},
                "profile": REGION_PROFILE,
                "minimumRegions": 1,
                "maximumRegions": 4,
                "minimumProfileCoverage": 1,
            },
        },
        "landmarks": {
            LANDMARK_ID: {
                "selector": {"tag": "RQELandmark",
                             "attributeEquals": {"LandmarkId": LANDMARK_ID}},
                "anchorSelector": {"tag": "RQELandmarkAnchor",
                                   "attributeEquals": {"LandmarkId": LANDMARK_ID}},
                "maximumDistance": 400.0,
                "sampleSpacing": 12,
                "eyeHeight": 5,
                "raysPerAnchor": 9,
                # Not all eight: the ring surrounds the player, so from inside
                # it some anchors are always behind them. Demanding every one
                # would fail a landmark that works precisely because you stand
                # inside it.
                "minimumVisibleAnchorFraction": 0.5,
                "maximumBlindSpotDegrees": 60,
                "minimumRegionsVisibleFrom": 1,
            },
        },
        "viewpoints": {
            "play-desktop": {
                "device": "desktop",
                "resolution": resolution,
                "landmark": LANDMARK_ID,
                "state": "play",
                # `look-at-landmark`, not `player-follow`.
                #
                # A follow camera depends on where a player happens to be
                # standing, so two runs frame different pictures and a visual
                # regression cannot be told from somebody walking left. The
                # capture provider refuses the mode outright for that reason —
                # it is the deterministic provider, and a follow shot is not
                # deterministic.
                "camera": {"mode": "look-at-landmark", "distance": 190,
                           "height": 72, "fieldOfView": 70, "yawDegrees": 30},
                "rubric": rubric,
            },
        },
        "evaluationStates": {
            "play": {
                # A path, not a description. The state is "the game, running,
                # with a real player attached", and the only honest way to
                # declare that is to point at the steps that produce it.
                "scenario": "scenarios/play.json",
                "requiredViewpoints": ["play-desktop"],
                "minimumRuleCoverage": 0.6,
            },
        },
    }


def build_scenario(game: str) -> dict[str, Any]:
    """The runtime state every visual measurement is taken from.

    Deliberately minimal, and deliberately makes no claim about the game. It
    resets to a clean session and attaches to a real player, which is the only
    precondition a photograph of a Forge game needs: a running place with
    somebody standing in it.

    Anything more would be this file deciding what the game is, which is the
    one thing Forge does not do.
    """
    return {
        "id": f"forge-{game}-play",
        "description": (
            "Start a fresh session of the exact build and attach to a real "
            "player before any capture. Proves the place runs and can be "
            "stood in; makes no claim about the core loop."),
        "requires": {"playSession": True, "clientBridge": True},
        # [[
        #     One step, and it is the one that matters.
        #
        #     A `reset` step was declared first, on the reasoning that visual
        #     evidence must come from a fresh session. It failed with "this
        #     scenario needs a fresh session, but no reset was configured", and
        #     the honest fix is to remove it rather than to wire it: the
        #     release run builds an immutable place, opens a Studio on that
        #     exact file and starts a new Play Solo before any of this — the
        #     session is fresh by construction, and asking for it again would
        #     be ceremony that costs a minute and proves nothing.
        #
        #     `attach` is the real precondition. It is fatal because a capture
        #     taken before the bridge controls a player is a picture of
        #     whatever the camera happened to be pointed at.
        # ]]
        "steps": [
            # The timeout belongs *inside* the step's payload; at the top
            # level it reads as another step kind and is silently ignored.
            #
            # Four minutes because a Forge game writes terrain and scatters a
            # world before it accepts anybody, and the server log shows it
            # still working long after the client has said it is ready. The
            # default twenty-five seconds gave up on a game that was fine.
            {"attach": {"timeout": 240}, "fatal": True,
             "comment": "capture only once the bridge controls a real player"},
        ],
        "releaseEvidence": [],
    }


def build_quality_focus(game: str, viewpoints: list[str]) -> dict[str, Any]:
    """The domain targets, with a snapshot list this game can actually satisfy.

    The canonical focus asks for snapshots named `shop`, `mine`, `plot` and
    `mobile-store`, because it was written for one tycoon. An arena has none
    of those, and copying it wholesale produces a gate that fails for reasons
    unrelated to quality — which is how gates get switched off.

    So the domain scores are taken as they are, being genuinely general, and
    the snapshot list is replaced with the viewpoints the spec declares.
    """
    canonical = REPO / "quality" / "quality-focus.json"
    focus: dict[str, Any] = {}
    if canonical.exists():
        focus = json.loads(canonical.read_text(encoding="utf-8"))

    focus.setdefault("schemaVersion", 1)
    review = focus.setdefault("visualReview", {})
    review["requiredSnapshots"] = viewpoints
    # 95 is the canonical bar and it is a decision, not a fact. Left where it
    # was found so that lowering it is a visible edit rather than a default.
    review.setdefault("minimumRawVisualScore", 95)
    return focus


def build_asset_manifest(game: str) -> dict[str, Any]:
    """The asset manifest, derived from what Forge already proved.

    `forge assets verify` loads every id this project references inside a real
    Studio and records whether it came back. That is a stronger claim than a
    manifest usually carries — most are a list somebody typed — so the manifest
    is generated from the verification rather than maintained beside it.

    An id that failed to load is not omitted. It is carried as `unavailable`,
    because an asset the project references and cannot load is precisely the
    thing a release gate exists to catch, and dropping it would turn a broken
    reference into a clean report.
    """
    verified: dict[str, Any] = {}
    catalogue = REPO / "forge" / "catalog" / "assets-verified.json"
    if catalogue.exists():
        try:
            verified = json.loads(catalogue.read_text(encoding="utf-8")).get("assets", {})
        except (OSError, json.JSONDecodeError):
            verified = {}

    kinds = {"sound": "audio", "audio": "audio", "mesh": "mesh",
             "image": "icon", "decal": "icon", "texture": "icon",
             "font": "icon", "animation": "animation"}

    assets: list[dict[str, Any]] = []
    for index, (reference, result) in enumerate(sorted(verified.items())):
        if not isinstance(result, dict):
            continue
        loaded = bool(result.get("ok"))
        assets.append({
            "id": "asset-%03d" % index,
            "kind": kinds.get(str(result.get("kind")), "icon"),
            "displayName": reference.rsplit("/", 1)[-1] or reference,
            "description": "Verified by `forge assets verify` inside Roblox Studio.",
            # `validated` means loaded; `unavailable` means it did not, and
            # saying so is the whole value of generating this from a check.
            "state": "validated" if loaded else "unavailable",
            "provider": "roblox" if reference.startswith("rbxasset://") else "creator-store",
            "requirement": "production-required",
            "previews": [],
            "remoteAssetId": reference,
            "metadata": {
                "reference": reference,
                "loaded": loaded,
                "seconds": result.get("seconds"),
            },
        })

    return {
        "schemaVersion": 1,
        "manifestId": "forge.%s.assets" % game,
        "assets": assets,
        # Forge resolves assets at runtime through its own registry rather than
        # binding an id to a property in the place file, so there is nothing
        # honest to declare here. An invented integration would be a claim the
        # gate then "verifies".
        "integrations": [],
    }


def build_contract(game: str) -> dict[str, Any]:
    """A contract derived from what this Forge game actually is."""
    name = _config_value(game, "name", game) or game
    containers = _config_value(game, "containers", []) or []
    categories = sorted({requirement["type"] for requirement in FORGE_REQUIREMENTS})

    requirements = []
    for entry in FORGE_REQUIREMENTS:
        requirements.append({
            **entry,
            "validation": {
                # Anything a probe can answer from the filesystem is allowed to;
                # everything else has to come from a live session. That
                # distinction is the RQE's whole discipline and worth keeping.
                "minimum_level": "STATICALLY_VALIDATED",
                "allowed_sources": ["filesystem", "studio-runtime"],
            },
        })

    return {
        "schemaVersion": 1,
        "contractId": f"forge.{game}.contract",
        "game": {
            "name": str(name),
            # Forge refuses to ship a genre and the contract says so rather
            # than inventing one. A quality gate does not need to know.
            "genre": "unspecified",
            "max_players": 12,
            # [[
            #     Only what this rig can photograph.
            #
            #     The Quality Engine requires a visual viewpoint per declared
            #     target device, and it has no device-emulator control: a phone
            #     viewpoint answers "Studio device-emulator identity is
            #     unavailable" and can never be satisfied. Declaring phone and
            #     tablet here bought nothing but a permanently blocked gate —
            #     "works on mobile" with no mobile picture is exactly the claim
            #     nobody checked. `Platform.audit` still measures phone layout
            #     from inside the running game; this is about what the camera
            #     can prove.
            # ]]
            "target_devices": ["desktop"],
        },
        "performance_budget": {
            "client": {"target_fps": 60, "max_frame_ms": 16.67},
            # Matches what `Platform.budgets` calls a desktop, so the two
            # halves of this repository agree on one number instead of two.
            "instances": {"max_workspace": 40000},
            "mobile": {"mandatory": True},
        },
        "visualQuality": {
            "specId": f"forge.{game}.visual",
            "spec": "contracts/visual/visual-quality.json",
            "schemaMajor": 1,
            "required": False,
            "release": {"minimumScore": 80, "minimumRuleCoverage": 0.6},
        },
        "release_gate": {
            "required_categories": categories,
            # Both refused, and for the same reason. A fixture is a JSON file
            # somebody wrote and a headless runtime is a Python reimplementation
            # of a game; neither has ever seen the place being released. This
            # is the discipline that makes the Quality Engine worth marrying to
            # — every other check in this repository can be satisfied by a file.
            "forbidden_sources": ["headless-runtime", "fixture"],
            "minimum_requirement_coverage": 1,
            "minimum_category_coverage": {name: 1 for name in categories},
            # [[
            #    How hard a thing has to have been looked at before it counts.
            #
            #    Structure and security can be established by reading source, so
            #    static evidence is enough. Geometry, navigation and performance
            #    are claims about a running world and need a runtime. Anything
            #    about what a player experiences — the UI, the gameplay, whether
            #    a save survives — needs the whole thing end to end, because
            #    those are exactly the properties that hold in every component
            #    and fail in the assembly.
            #]]
            "minimum_validation_by_type": {
                "structural": "STATICALLY_VALIDATED",
                "security": "STATICALLY_VALIDATED",
                "geometry": "RUNTIME_VALIDATED",
                "navigation": "RUNTIME_VALIDATED",
                "runtime": "RUNTIME_VALIDATED",
                "performance": "RUNTIME_VALIDATED",
                "visual": "VISUALLY_VALIDATED",
                "ui": "E2E_VALIDATED",
                "gameplay": "E2E_VALIDATED",
                "persistence": "E2E_VALIDATED",
                "multiplayer": "E2E_VALIDATED",
            },
            # Evidence goes stale. An hour for something read out of source,
            # half an hour for anything measured in a session, because a
            # measurement of a build that is no longer the build is not
            # evidence about anything.
            "maximum_evidence_age_seconds_by_level": {
                "STATICALLY_VALIDATED": 3600,
                "RUNTIME_VALIDATED": 1800,
                "VISUALLY_VALIDATED": 1800,
                "E2E_VALIDATED": 1800,
            },
            # 100 is the canonical bar for a flagship. A Forge game asks for 80
            # here and the contract is meant to be argued with: a jam entry and
            # a flagship do not owe the same thing.
            "minimum_visual_score": 80,
            # A capture of a minimised window is a black rectangle, and a
            # validator that accepts one has learned the game is black. This
            # project spent an afternoon on exactly that misreading.
            "require_trustworthy_captures": True,
        },
        "requirements": requirements,
        "forge": {
            "generated": True,
            "containers": containers,
            "note": "Generated by `forge quality`. Edit the bar, not the paths.",
        },
    }


def build_descriptor(game: str) -> dict[str, Any]:
    """The RQE project descriptor for a Forge game."""
    return {
        "name": game,
        "contract": "contract.robloxqa.json",
        "rojoProject": "default.project.json",
        # Local copies, not repository paths. The Quality Engine refuses any
        # file outside the project so a release run cannot be altered by an
        # edit somewhere else; `generate` copies the canonical ones in.
        "qualityFocus": "quality/quality-focus.json",
        "probeRegistry": "quality/probe-registry.v1.json",
        "agentScenario": "scenarios/play.json",
        "assetManifest": "assets/asset-manifest.json",
        "scripts": "src",
        "scanPaths": ["src"],
        "reports": "reports",
        "release": {"seed": _config_value(game, "seed", 1) or 1},
        # Forge projects have a known shape, so this is derived rather than
        # declared. A path list written by hand is a path list that drifts.
        "expectedPaths": [
            "default.project.json",
            "src/shared/Config.lua",
            "src/server/init.server.lua",
            "src/client/init.client.lua",
        ],
    }


def generate(game: str) -> tuple[Path, Path]:
    """Write both files next to the game."""
    directory = game_dir(game)
    contract_path = directory / "contract.robloxqa.json"
    descriptor_path = directory / "rqe.project.json"

    contract_path.write_text(
        json.dumps(build_contract(game), indent=2, ensure_ascii=False), encoding="utf-8")
    descriptor_path.write_text(
        json.dumps(build_descriptor(game), indent=2, ensure_ascii=False), encoding="utf-8")

    # The visual spec: the half of the Quality Engine that was unreachable
    # until the engine grew a way to mark a world.
    #
    # Its schema is copied in rather than referenced across the repository,
    # because the Quality Engine refuses any path that escapes the project. A
    # release run has to be able to stand on its own.
    #: Everything a release run has to be able to reach without leaving the
    #: project. The Quality Engine refuses any path that escapes the project
    #: root, so a run cannot be altered by editing a file somewhere else — and
    #: each of these is referenced by one of the others, which is why the
    #: schemas travel with the documents that name them.
    for relative in (
        "schemas/visual-quality-spec.v1.schema.json",
        "schemas/probe-registry.v1.schema.json",
        "schemas/game-contract.schema.json",
        "schemas/quality-snapshot.v1.schema.json",
        "quality/probe-registry.v1.json",
    ):
        source = REPO / relative
        if source.exists():
            destination = directory / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")

    spec = build_visual_spec(game)
    visual_path = directory / "contracts" / "visual" / "visual-quality.json"
    visual_path.parent.mkdir(parents=True, exist_ok=True)
    visual_path.write_text(json.dumps(spec, indent=2, ensure_ascii=False), encoding="utf-8")

    manifest_path = directory / "assets" / "asset-manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(
        json.dumps(build_asset_manifest(game), indent=2, ensure_ascii=False),
        encoding="utf-8")

    scenario_path = directory / "scenarios" / "play.json"
    scenario_path.parent.mkdir(parents=True, exist_ok=True)
    scenario_path.write_text(
        json.dumps(build_scenario(game), indent=2, ensure_ascii=False), encoding="utf-8")

    # Generated rather than copied: see `build_quality_focus`.
    focus_path = directory / "quality" / "quality-focus.json"
    focus_path.parent.mkdir(parents=True, exist_ok=True)
    focus_path.write_text(
        json.dumps(build_quality_focus(game, sorted(spec["viewpoints"])),
                   indent=2, ensure_ascii=False), encoding="utf-8")

    (directory / "reports").mkdir(exist_ok=True)
    return descriptor_path, contract_path


def audit(game: str, static_only: bool = False, timeout: int = 1800) -> dict[str, Any]:
    """Run the Quality Engine against a Forge game and return what it found.

    `rqe release`, not `rqe audit`. The audit path is the Quality Engine's own
    legacy diagnostic: it scores a fixture somebody wrote and a Python
    reimplementation of one specific tycoon, and its own source says in as many
    words that its evidence cannot release a build. Pointing Forge at it would
    have produced a number that measures the validator's simulator rather than
    the game.

    The release path measures the actual place through the Studio bridge, which
    is the thing Forge games have and the reason this marriage is worth making
    at all.
    """
    directory = game_dir(game)
    if not (directory / "rqe.project.json").exists():
        generate(game)

    command = [sys.executable, str(REPO / "rqe.py"), "release", str(directory)]
    if static_only:
        command.append("--static-only")

    proc = subprocess.run(command, capture_output=True, text=True,
                          timeout=timeout, cwd=str(REPO))
    output = (proc.stdout or "") + (proc.stderr or "")

    #: The newest release run's own record, which is richer than its stdout.
    report = None
    artifacts = directory / "artifacts"
    if artifacts.exists():
        runs = sorted((path for path in artifacts.iterdir() if path.is_dir()),
                      key=lambda path: path.name, reverse=True)
        for run in runs:
            for name in ("release.json", "report.json", "evidence.json"):
                candidate = run / name
                if candidate.exists():
                    try:
                        report = json.loads(candidate.read_text(encoding="utf-8"))
                    except (json.JSONDecodeError, OSError):
                        continue
                    break
            if report is not None:
                break

    return {"exit": proc.returncode, "output": output.strip(), "report": report}


def render(result: dict[str, Any]) -> str:
    """The Quality Engine's verdict, in its own words where it has them.

    Its stdout is already a scores table and a list of blockers, each naming
    the category, the number and the bar. Reformatting that would lose the
    thing that makes it actionable, so this passes it through and only adds
    what the stdout leaves out.
    """
    lines = [result.get("output") or "the release run produced no output"]

    report = result.get("report")
    if isinstance(report, dict):
        run_id = report.get("runId") or report.get("id")
        if run_id:
            lines.append("")
            lines.append(f"  run: {run_id}")

    if result["exit"] != 0:
        lines.append("")
        lines.append("  Blocked is the expected first answer. Every category at zero "
                     "coverage means nobody measured it, not that it failed —")
        lines.append("  runtime evidence needs Studio open on the place, with the "
                     "bridge up and a play session the run can attach to.")
    return "\n".join(lines)
