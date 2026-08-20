"""Game model -> production blueprint.

The blueprint stops being a second description of the game. Before this, an
agent wrote `product-intent.json` and a blueprint project entry side by side and
nothing checked they agreed: the intent could promise a shop the blueprint never
built, and both files would be individually valid.

Here the blueprint is *derived*. Subsystems come from the systems the model
implies, asset needs from the genre and the zones, scenario classes from the
core loop. Nothing in the output is authored, so nothing in the output can
disagree with the model -- and a change to the game is a change in one place.

Deliberately mechanical. Every derivation below is a lookup or a loop, not a
judgement: what a tycoon *should* have is the design compiler's job one layer
up, and a compiler that quietly improved on its input would make the model stop
being the description of the game.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .model import GameModel, GameModelError, required_systems


#: Which subsystem owns each system. The blueprint's unit of ownership is the
#: subsystem, and two agents writing into one tree is how a merge conflict
#: becomes a corrupted place file.
SUBSYSTEM_OF = {
    "economy": "gameplay", "progression": "gameplay", "save": "gameplay",
    "inventory": "gameplay", "crafting": "gameplay", "quests": "gameplay",
    "trading": "gameplay", "pets": "gameplay", "gacha": "gameplay",
    "tower": "gameplay", "offline_income": "gameplay",
    "shop": "interface", "tutorial": "interface", "leaderboard": "interface",
    "analytics": "telemetry",
}

#: What each topology needs built, as world capability. Drives both the
#: subsystem description and the asset plan.
TOPOLOGY_CAPABILITY = {
    "hub_and_zones": "a hub with portals, and one traversable zone per declared zone",
    "grid_plots": "a plot grid around a shared hub",
    "single_arena": "one bounded arena with spawn and cover",
    "open_world": "a continuous landmass with regions and landmarks",
    "linear_levels": "a sequence of gated level volumes",
}

#: Scenario classes implied by a loop verb. A scenario nobody derived is a
#: behaviour nobody measures, and the loop is exactly the list of behaviours the
#: game promised.
#: The class values are the schema's, not ours. An invented class validates
#: nowhere and is caught at compile time, which is the right place -- but only
#: because these are looked up rather than composed from the verb name.
VERB_SCENARIOS = {
    "collect": ("core-loop", "CORE_LOOP"),
    "process": ("core-loop", "CORE_LOOP"),
    "sell": ("core-loop", "CORE_LOOP"),
    "build": ("core-loop", "CORE_LOOP"),
    "explore": ("traversal", "CORE_LOOP"),
    "fight": ("combat", "CORE_LOOP"),
    "defend": ("combat", "CORE_LOOP"),
    "race": ("race", "CORE_LOOP"),
    "survive": ("survival", "FAILURE"),
    "craft": ("crafting", "CORE_LOOP"),
    "upgrade": ("progression", "PROGRESSION"),
    "unlock": ("progression", "PROGRESSION"),
    "prestige": ("prestige", "PROGRESSION"),
    "quest": ("quest", "PROGRESSION"),
    "buy": ("purchase", "MONETIZATION"),
    "trade": ("trade", "MULTIPLAYER"),
    "pull": ("gacha", "MONETIZATION"),
}

DEVICE_MATRIX = {
    "devices": [
        {"id": "desktop", "viewportWidth": 1920, "viewportHeight": 1080,
         "inputModes": ["KEYBOARD_MOUSE"]},
        {"id": "phone", "viewportWidth": 390, "viewportHeight": 844,
         "inputModes": ["TOUCH"]},
    ],
    "viewpoints": [
        {"id": "overview", "purpose": "world readability", "cameraMode": "FIXED"},
        {"id": "player", "purpose": "core interaction", "cameraMode": "PLAYER"},
    ],
    # Every device against every viewpoint. A partial matrix is how the one
    # combination nobody captured turns out to be the broken one.
    "combinations": [
        {"deviceId": device, "viewpointId": viewpoint}
        for device in ("desktop", "phone")
        for viewpoint in ("overview", "player")
    ],
}


class MissingDefinition(GameModelError):
    """The project's definition files do not exist yet.

    Its own type because the fix is a different action: not "correct the model"
    but "scaffold the project first". Without it this surfaced as a schema
    error three layers down complaining about a missing sha256, which says
    nothing about what to do.
    """


def _artifact_ref(product: str, kind: str, path: Path, root: Path) -> dict[str, Any]:
    absolute = root / path
    if not absolute.is_file():
        # The blueprint schema requires a content hash on every reference, and
        # rightly: a plan naming a file it never read is a plan that cannot
        # detect the file changing underneath it.
        raise MissingDefinition(
            f"{path} does not exist, so the plan would reference a file it never read. "
            f"Scaffold the project first (game_new), then compile"
        )
    return {
        "productId": product,
        "artifactId": f"{product}.{kind.lower()}",
        "kind": kind,
        "path": str(path).replace("\\", "/"),
        "sha256": hashlib.sha256(absolute.read_bytes()).hexdigest(),
    }


def to_product_intent(model: GameModel) -> dict[str, Any]:
    """The intent file, derived rather than authored beside the model."""

    return {
        "schemaVersion": 1,
        "productId": model.id,
        "pitch": model.pitch,
        "topology": model.topology.replace("_", "-"),
        "progression": f"{model.progression.kind}-ladder"
                       if model.progression.tiers else model.progression.kind,
        "privateSpace": model.private_space,
        "concurrentPlayers": model.concurrent_players,
        "tokenSet": model.token_set,
        "coreLoop": list(model.core_loop),
    }


def to_blueprint_project(
    model: GameModel,
    *,
    root: Path,
    revision: str = "1.0.0",
    seed: int | None = None,
) -> dict[str, Any]:
    """One blueprint project, entirely derived from the model."""

    if not model.coherent:
        # Refused rather than compiled. A blueprint from an incoherent model is
        # a task graph that builds a game the model already says will not work,
        # and every hour spent executing it is spent on a known defect.
        raise GameModelError(
            f"{model.id} is not coherent, so it cannot be compiled:\n  - "
            + "\n  - ".join(model.problems())
        )

    systems = required_systems(model)
    source_root = f"games/{model.id}"

    # `world` and `interface` always exist. Every shipped experience has a
    # world to stand in and a store presence -- icon, thumbnail, a loading
    # screen -- regardless of which systems the model declares, and deriving
    # `interface` only from a shop would leave the icon with no subsystem to
    # consume it.
    subsystem_ids: list[str] = ["world", "interface"]
    for system in systems:
        subsystem = SUBSYSTEM_OF.get(system, "gameplay")
        if subsystem not in subsystem_ids:
            subsystem_ids.append(subsystem)

    subsystems = []
    for subsystem in subsystem_ids:
        owned = [s for s in systems if SUBSYSTEM_OF.get(s, "gameplay") == subsystem]
        if subsystem == "world":
            capability = TOPOLOGY_CAPABILITY[model.topology]
            dependencies: list[str] = []
        elif subsystem == "interface":
            capability = ", ".join(owned) if owned else "store presence and player-facing screens"
            dependencies = ["world"]
        else:
            capability = ", ".join(owned)
            dependencies = ["world"]
        subsystems.append({
            "id": subsystem, "capability": capability, "dependencies": dependencies,
        })

    # -- asset needs ---------------------------------------------------
    #
    # Every game needs an icon and a thumbnail to ship; the rest follows from
    # what the model says the world contains.
    asset_needs: list[dict[str, Any]] = [
        {"id": "experience-icon", "type": "ICON", "strategy": "EITHER",
         "requiredForRelease": True, "consumers": ["interface"],
         "acceptanceProfileId": "release-quality"},
        {"id": "experience-thumbnail", "type": "IMAGE", "strategy": "EITHER",
         "requiredForRelease": True, "consumers": ["interface"],
         "acceptanceProfileId": "release-quality"},
    ]
    for zone in model.zones:
        asset_needs.append({
            # CREATE rather than EITHER: a zone kit is the game's own visual
            # language, and a discovered one would be somebody else's.
            "id": f"zone-{zone.id}-kit", "type": "MODEL", "strategy": "CREATE",
            "requiredForRelease": True, "consumers": ["world"],
            "acceptanceProfileId": "release-quality",
        })
    if "shop" in systems or model.monetization:
        asset_needs.append({
            "id": "storefront-art", "type": "IMAGE", "strategy": "EITHER",
            "requiredForRelease": bool(model.monetization), "consumers": ["interface"],
            "acceptanceProfileId": "release-quality",
        })

    # -- scenarios -----------------------------------------------------
    #
    # Onboarding always: a game whose first session is never measured is a game
    # whose first session nobody has seen.
    scenario_classes: list[dict[str, Any]] = [
        {"id": "first-session", "class": "ONBOARDING",
         "requiredForRelease": True, "actorProfile": "new-player"},
    ]
    seen_scenarios = {"first-session"}
    for verb in model.core_loop:
        name, klass = VERB_SCENARIOS.get(verb, ("core-loop", "ECONOMY"))
        if name in seen_scenarios:
            continue
        seen_scenarios.add(name)
        scenario_classes.append({
            "id": name, "class": klass, "requiredForRelease": True,
            "actorProfile": "returning-player",
        })
    if model.progression.tiers > 0 and "progression" not in seen_scenarios:
        scenario_classes.append({
            "id": "progression", "class": "PROGRESSION", "requiredForRelease": True,
            "actorProfile": "returning-player",
        })

    ownership = [
        {"subsystemId": subsystem["id"], "ownerRole": f"{subsystem['id']}-agent",
         "writeRoots": [f"{source_root}/src/{subsystem['id']}"]}
        for subsystem in subsystems
    ]

    definition_dir = Path(source_root) / "definition"
    project: dict[str, Any] = {
        "schemaVersion": 1,
        "projectId": f"project-{model.id}",
        "productId": model.id,
        "revision": revision,
        "seed": seed if seed is not None else int(model.sha256[:8], 16) % 100_000_000,
        "genre": model.genre,
        "templateId": f"template-{model.genre.replace('_', '-')}-v1",
        "sourceRoot": source_root,
        "artifactRoot": f"artifacts/products/{model.id}",
        "productIntentRef": _artifact_ref(
            model.id, "PRODUCT_INTENT", definition_dir / "product-intent.json", root),
        "referenceBundleRef": _artifact_ref(
            model.id, "REFERENCE_BUNDLE", definition_dir / "reference-bundle.json", root),
        "subsystems": subsystems,
        "ownership": ownership,
        "deviceViewpointMatrix": DEVICE_MATRIX,
        "scenarioClasses": scenario_classes,
        "assetNeeds": asset_needs,
        "qualityProfiles": [{
            "id": "release-quality",
            "requiredForRelease": True,
            "appliesTo": ["GAMEPLAY", "VISUAL", "ASSETS", "RELEASE"],
            "inputRef": _artifact_ref(
                model.id, "QUALITY_PROFILE", definition_dir / "release-quality.json", root),
        }],
        "outputArtifactRefs": [
            {"productId": model.id, "artifactId": f"{model.id}.{kind.lower()}",
             "kind": kind, "path": f"artifacts/products/{model.id}/{kind.lower()}"}
            # The full set the pipeline produces, so a plan declares every
            # artefact a gate will later look for. A missing declaration reads
            # downstream as a stage that produced nothing.
            for kind in (
                "PRODUCTION_PLAN", "SOURCE_BUNDLE", "ASSET_MANIFEST", "BUILD_PLACE",
                "INTEGRATION_MANIFEST", "MEASUREMENT_RUN", "SCENARIO_RESULTS",
                "CAPTURE_BUNDLE", "QUALITY_REVIEW", "REPAIR_PLAN", "REGRESSION_RUN",
                "RELEASE_CANDIDATE",
            )
        ],
    }
    return project


def to_blueprint(
    models: list[GameModel],
    *,
    root: Path,
    blueprint_id: str = "portfolio",
    revision: str = "1.0.0",
    engine: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """A whole portfolio blueprint, from one model per game."""

    if not models:
        raise GameModelError("a blueprint needs at least one game")
    return {
        "schemaVersion": 1,
        "blueprintId": blueprint_id,
        "revision": revision,
        # Matches the engine block the existing portfolio declares. The
        # blueprint records which engine sources produced a plan, so a rebuild
        # from a changed engine is distinguishable from a rebuild from a
        # changed game.
        "engine": engine or {
            "engineId": "rqe",
            "version": "2.0.0",
            "sourceRoots": ["rqe", "schemas", "apps/studio-plugin", "roblox/lib"],
        },
        "projects": [to_blueprint_project(model, root=root, revision=revision)
                     for model in models],
    }


def compile_model(model: GameModel, *, root: Path) -> dict[str, Any]:
    """Model -> blueprint -> the real production plan.

    Goes through `compile_production_blueprint` rather than reimplementing it.
    A second planner would be a second answer to "what would build this game",
    and the two would drift.
    """

    from ..orchestrator.blueprint import compile_production_blueprint

    blueprint = to_blueprint([model], root=root, blueprint_id=model.id)
    plan = compile_production_blueprint(blueprint)
    payload = plan.to_dict() if hasattr(plan, "to_dict") else {}
    return {
        "modelSha256": model.sha256,
        "blueprint": blueprint,
        "plan": payload,
        "systems": required_systems(model),
        "note": (
            "derived from the model: nothing here was authored beside it, so nothing "
            "here can disagree with it"
        ),
    }
