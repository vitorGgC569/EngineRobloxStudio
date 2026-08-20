"""GameModel -> self-contained, fail-closed release inputs.

The production blueprint describes work.  The industrial release runner consumes
another boundary: ``rqe.project.json``, a game contract, an executable visual
specification and a hash-bound ProductIntent chain.  A scaffold that only emits
the former cannot be released as its own product; tools fall back to whichever
repository-level project happens to surround it.

Everything in this module is deterministic and product-generic.  Facts that
cannot be derived from :class:`GameModel` are not invented.  In particular, a
human approval, an independent reference benchmark and its calibration receipt
are emitted as explicit blockers.  They still have stable ids and paths so the
release runner can consume the project and explain the missing authority rather
than accidentally grading it as the mining-tycoon fixture.
"""

from __future__ import annotations

import re
from typing import Any, Mapping

from .model import GameModel


TARGET_DEVICES = ("desktop", "phone")
DEVICE_VIEWPOINTS = {
    "desktop": {
        "resolution": [1920, 1080],
        "camera": {
            "mode": "look-at-landmark",
            "distance": 42,
            "height": 13,
            "fieldOfView": 70,
            "yawDegrees": 28,
        },
    },
    "phone": {
        "resolution": [390, 844],
        "camera": {
            "mode": "player-follow",
            "distance": 18,
            "height": 6,
            "fieldOfView": 75,
            "yawDegrees": 0,
        },
    },
}


def _title(model: GameModel) -> str:
    return " ".join(part.capitalize() for part in model.id.replace("_", "-").split("-"))


def _safe_id(value: str, *, fallback: str = "item") -> str:
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", str(value))
    value = re.sub(r"[^a-zA-Z0-9_-]+", "-", value).strip("-_").lower()
    if not value or not value[0].isalpha():
        value = f"{fallback}-{value}".strip("-")
    return value


def _requirement(
    identifier: str,
    probe: str,
    kind: str,
    category: str,
    level: str,
    sources: tuple[str, ...],
    *,
    severity: str = "critical",
) -> dict[str, Any]:
    return {
        "id": identifier,
        "probe": probe,
        "type": kind,
        "category": category,
        "severity": severity,
        "validation": {
            "minimum_level": level,
            "minimum_coverage": 1,
            "allowed_sources": list(sources),
        },
    }


def _primary_landmark(model: GameModel) -> str:
    if model.topology == "single_arena":
        return "objective-core"
    if model.topology == "hub_and_zones":
        return "hub-landmark"
    if model.zones:
        return f"{model.zones[0].id}-landmark"
    # ``grid_plots`` currently has no WorldGrammar production path.  Naming the
    # role is still useful: the selector will measure zero and block rather than
    # borrowing a landmark from another game's contract.
    return "primary-landmark"


def semantic_ids(model: GameModel) -> dict[str, Any]:
    return {
        "worldRole": "primary-landmark",
        "uiSurface": "initial-interface",
        "gameplayVerbs": tuple(dict.fromkeys(
            _safe_id(verb, fallback="verb") for verb in model.core_loop
        )),
        "landmarkSelector": _primary_landmark(model),
    }


def game_contract(model: GameModel) -> dict[str, Any]:
    semantics = semantic_ids(model)
    requirements = [
        _requirement(
            "structural_integrity", "structural_integrity", "structural", "structural",
            "STATICALLY_VALIDATED", ("filesystem",),
        ),
        _requirement(
            "contract_schema", "contract_schema", "structural", "structural",
            "STATICALLY_VALIDATED", ("contract-validator",),
        ),
        _requirement(
            "fixture_excluded", "fixture_excluded", "structural", "structural",
            "STATICALLY_VALIDATED", ("release-orchestrator",),
        ),
        _requirement(
            "visual_spec_schema", "visual_spec_schema", "structural", "structural",
            "STATICALLY_VALIDATED", ("visual-spec-validator",),
        ),
        _requirement(
            "product_truth_alignment", "product_truth_alignment", "runtime", "structural",
            "RUNTIME_VALIDATED", ("product-truth-validator",),
        ),
        _requirement(
            "asset_security", "asset_security", "security", "security",
            "STATICALLY_VALIDATED", ("release-static-validator",),
        ),
        _requirement(
            "visual_asset_quality", "visual_asset_quality", "structural", "assets",
            "STATICALLY_VALIDATED", ("visual-asset-validator",), severity="major",
        ),
        _requirement(
            "ground_support", "ground_support", "geometry", "geometry",
            "RUNTIME_VALIDATED", ("studio-bridge",),
        ),
        _requirement(
            "world_primary_landmark", "objective_reachable", "navigation", "navigation",
            "RUNTIME_VALIDATED", ("studio-bridge",),
        ),
        _requirement(
            "performance_budget", "performance_budget", "performance", "performance",
            "RUNTIME_VALIDATED", ("studio-bridge",),
        ),
        _requirement(
            "runtime_error", "runtime_error", "runtime", "runtime",
            "RUNTIME_VALIDATED", ("studio-bridge",),
        ),
        # No generic scenario can prove a product-specific UI.  This probe is
        # intentionally orphaned until implementation emits a scenario binding.
        _requirement(
            "ui_initial_surface", "ui_initial_surface", "ui", "ui",
            "E2E_VALIDATED", ("studio-scenario",),
        ),
    ]

    gameplay_bindings: dict[str, list[str]] = {}
    for verb in semantics["gameplayVerbs"]:
        requirement_id = f"gameplay_{verb.replace('-', '_')}"
        requirements.append(_requirement(
            requirement_id,
            f"core_loop_{verb.replace('-', '_')}",
            "gameplay",
            "gameplay",
            "E2E_VALIDATED",
            ("studio-scenario",),
        ))
        gameplay_bindings[verb] = [requirement_id]

    required_categories = [
        "structural", "assets", "security", "geometry", "navigation",
        "performance", "runtime", "ui", "gameplay", "visual",
    ]
    if "save" in model.systems:
        requirements.append(_requirement(
            "persistence_rejoin", "persistence_rejoin", "persistence", "persistence",
            "E2E_VALIDATED", ("studio-scenario",),
        ))
        required_categories.append("persistence")
    if model.concurrent_players > 1:
        requirements.append(_requirement(
            "multiplayer_isolation", "multiplayer_isolation", "multiplayer", "multiplayer",
            "E2E_VALIDATED", ("studio-scenario",),
        ))
        required_categories.append("multiplayer")

    return {
        "$schema": "../schemas/game-contract.schema.json",
        "schemaVersion": 1,
        "contractId": f"{model.id}.release",
        "productId": model.id,
        "productTruth": {
            "intentId": f"{model.id}.intent",
            "semanticBindings": {
                "worldRoles": {
                    semantics["worldRole"]: ["world_primary_landmark"],
                },
                "uiSurfaces": {
                    semantics["uiSurface"]: ["ui_initial_surface"],
                },
                "gameplayVerbs": gameplay_bindings,
            },
        },
        "game": {
            "name": _title(model),
            "genre": model.genre,
            "max_players": model.concurrent_players,
            "target_devices": list(TARGET_DEVICES),
        },
        "performance_budget": {
            # Platform ceilings, not measurements of the candidate.  Product
            # truth still requires them to be frozen from independent references.
            "client": {"target_fps": 60, "max_frame_ms": 16.667},
            "instances": {"max_workspace": 25000},
            "mobile": {"mandatory": True},
        },
        "visualQuality": {
            "spec": "visual/visual-quality.json",
            "specId": f"{model.id}.visual",
            "schemaMajor": 1,
            "required": True,
            "release": {
                "minimumScore": 100,
                "minimumRuleCoverage": 1,
                "minimumValidationLevel": "VISUALLY_VALIDATED",
                "missingEvidence": "FAIL",
            },
        },
        "release_gate": {
            "required_categories": required_categories,
            "forbidden_sources": ["headless-runtime", "fixture"],
            "minimum_requirement_coverage": 1,
            "minimum_category_coverage": {
                category: 1 for category in required_categories
            },
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
            "maximum_evidence_age_seconds_by_level": {
                "STATICALLY_VALIDATED": 3600,
                "RUNTIME_VALIDATED": 1800,
                "VISUALLY_VALIDATED": 1800,
                "E2E_VALIDATED": 1800,
            },
            "minimum_visual_score": 100,
            "require_trustworthy_captures": True,
        },
        "requirements": requirements,
    }


def _palette(token_set: Any | None) -> list[dict[str, Any]]:
    if token_set is None:
        return [
            {"id": "pending-dark", "rgb": [32, 36, 44], "roles": ["supporting"]},
            {"id": "pending-light", "rgb": [224, 228, 232], "roles": ["dominant"]},
            {"id": "pending-accent", "rgb": [224, 168, 64], "roles": ["accent"]},
        ]
    swatches: list[dict[str, Any]] = []
    used: set[str] = set()
    for role in sorted(token_set.roles.values(), key=lambda item: item.id):
        identifier = _safe_id(role.id, fallback="palette")
        base = identifier
        suffix = 2
        while identifier in used:
            identifier = f"{base}-{suffix}"
            suffix += 1
        used.add(identifier)
        swatches.append({
            "id": identifier,
            "rgb": list(role.srgb),
            "roles": [_safe_id(role.tier, fallback="role")],
        })
    return swatches


def _object_types(token_set: Any | None) -> dict[str, Any]:
    if token_set is None:
        projected = {
            "building": {
                "scale": {
                    "boundsMethod": "oriented-box",
                    "minimumSize": [4, 5, 4],
                    "maximumSize": [120, 100, 120],
                }
            }
        }
    else:
        from ..token_conformance import projected_spec_fragment

        projected = projected_spec_fragment(token_set)["objectTypes"]
    result: dict[str, Any] = {}
    for type_id, definition in projected.items():
        result[type_id] = {
            "selector": {
                "tag": "RQEVisualRoot",
                "attributeEquals": {"VisualType": type_id},
            },
            "minimumInstances": 1,
            "maximumInstances": 25000,
            "scale": {
                **definition["scale"],
                "maximumRelativeMad": 1,
                "groupByAttribute": "VisualVariant",
            },
        }
    return result


def visual_quality_spec(model: GameModel, token_set: Any | None) -> dict[str, Any]:
    semantics = semantic_ids(model)
    viewpoint_ids = [f"initial-{device}" for device in TARGET_DEVICES]
    maximum_distance = 900
    maximum_delta_e = 12
    if token_set is not None:
        from ..token_conformance import projected_spec_fragment

        fragment = projected_spec_fragment(token_set)
        maximum_distance = fragment["landmarkMaximumDistance"]
        maximum_delta_e = float(token_set.harmony["maxDeltaEToNearestRole"])

    viewpoints = {
        f"initial-{device}": {
            "device": device,
            "resolution": DEVICE_VIEWPOINTS[device]["resolution"],
            "landmark": "primary-landmark",
            "state": "initial",
            "camera": DEVICE_VIEWPOINTS[device]["camera"],
            "rubric": {
                "composition": 0.2,
                "hierarchy": 0.2,
                "legibility": 0.25,
                "materiality": 0.15,
                "polish": 0.2,
            },
        }
        for device in TARGET_DEVICES
    }
    visual_binding = {
        "landmarkIds": ["primary-landmark"],
        "regionSetIds": ["primary-regions"],
        "viewpointIds": viewpoint_ids,
    }
    return {
        "$schema": "../../schemas/visual-quality-spec.v1.schema.json",
        "schemaVersion": 1,
        "specId": f"{model.id}.visual",
        "productId": model.id,
        "productTruth": {
            "intentId": f"{model.id}.intent",
            "calibrationId": f"{model.id}.visual-calibration",
            "semanticBindings": {
                "worldRoles": {semantics["worldRole"]: visual_binding},
                "uiSurfaces": {
                    semantics["uiSurface"]: {
                        "landmarkIds": [],
                        "regionSetIds": [],
                        "viewpointIds": viewpoint_ids,
                    }
                },
            },
        },
        "revision": 1,
        "units": {
            "distance": "stud",
            "density": "visualRootsPer1000SquareStuds",
            "colorDifference": "CIEDE2000",
        },
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
            "minimumClassifiedFraction": 1,
        },
        "palette": {
            "swatches": _palette(token_set),
            "maximumDeltaE": maximum_delta_e,
            "maximumOffPaletteFraction": 0,
        },
        "objectTypes": _object_types(token_set),
        "regionProfiles": {
            "primary": {
                "density": {
                    "minimumRootsPer1000SquareStuds": 0,
                    "maximumRootsPer1000SquareStuds": 100,
                    "minimumFootprintCoverage": 0,
                },
                "heightVariation": {
                    "minimumP90MinusP10": 0,
                    "maximumP90MinusP10": 1000,
                },
                "materialVariety": {
                    "minimumDistinctMaterials": 1,
                    "maximumDominantFraction": 1,
                },
                "repetition": {
                    "maximumIdenticalVariantRun": 25000,
                    "minimumVariantEntropy": 0,
                },
            }
        },
        "regionSets": {
            "primary-regions": {
                "selector": {
                    "tag": "RQEVisualRegion",
                    "attributeEquals": {"VisualRegionProfile": "plaza"},
                },
                "profile": "primary",
                "minimumRegions": 1,
                "maximumRegions": max(2, len(model.zones) + 1),
                "minimumProfileCoverage": 1,
            }
        },
        "landmarks": {
            "primary-landmark": {
                "selector": {
                    "tag": "RQELandmark",
                    "attributeEquals": {"LandmarkId": semantics["landmarkSelector"]},
                },
                "anchorSelector": {
                    "tag": "RQELandmarkAnchor",
                    "attributeEquals": {"LandmarkId": semantics["landmarkSelector"]},
                },
                "maximumDistance": maximum_distance,
                "sampleSpacing": 10,
                "eyeHeight": 5,
                "raysPerAnchor": 9,
                "minimumVisibleAnchorFraction": 1,
                "maximumBlindSpotDegrees": 0,
                "minimumRegionsVisibleFrom": 1,
            }
        },
        "viewpoints": viewpoints,
        "evaluationStates": {
            "initial": {
                "scenario": "scenarios/initial-runtime.json",
                "requiredViewpoints": viewpoint_ids,
                "minimumRuleCoverage": 1,
            }
        },
    }


def initial_runtime_scenario(model: GameModel) -> dict[str, Any]:
    return {
        "id": f"{model.id}-initial-runtime",
        "description": (
            "Start a fresh running place and attach to a real player before initial-state "
            "captures. This proves session availability only; it intentionally makes no "
            "claim about the product-specific core loop."
        ),
        "requires": {"playSession": True, "clientBridge": True},
        "steps": [
            {
                "reset": {},
                "comment": "initial-state evidence requires a fresh, exact-build session",
            },
            {
                "attach": {},
                "fatal": True,
                "comment": "capture only after the bridge proves it controls a real player",
            },
        ],
        # A wire/session check is not gameplay evidence.  Product-specific
        # scenarios add bindings only after they can observe a named effect.
        "releaseEvidence": [],
    }


def quality_focus(model: GameModel) -> dict[str, Any]:
    categories = [
        "structural", "assets", "security", "geometry", "navigation",
        "performance", "runtime", "ui", "gameplay", "visual",
    ]
    if "save" in model.systems:
        categories.append("persistence")
    if model.concurrent_players > 1:
        categories.append("multiplayer")
    focuses = {
        "structural": "project topology and product identity",
        "assets": "approved, licensed, integrated production assets",
        "security": "source, asset and remote safety",
        "geometry": "support, overlap and play-volume integrity",
        "navigation": "player-reachable objectives",
        "performance": "runtime budgets on target devices",
        "runtime": "stable server and client sessions with zero errors",
        "ui": "legible and operable player-facing surfaces",
        "gameplay": "the declared core loop completed by a player-equivalent actor",
        "visual": "deterministic captures and calibrated review",
        "persistence": "rejoin-safe progress",
        "multiplayer": "concurrent-player isolation and shared behavior",
    }
    return {
        "schemaVersion": 1,
        "continuous": True,
        "status": "PROVISIONAL_UNCALIBRATED",
        "domains": {
            category: {"targetScore": 100, "focus": focuses[category]}
            for category in categories
        },
        "visualReview": {
            "requiredSnapshots": [f"initial-{device}" for device in TARGET_DEVICES],
            "minimumRawVisualScore": 100,
        },
    }


def reference_bundle(model: GameModel) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "productId": model.id,
        "status": "BLOCKED",
        "blockers": [
            "INDEPENDENT_REFERENCE_BENCHMARK_REQUIRED",
            "VISUAL_CALIBRATION_REQUIRED",
        ],
        "references": [],
    }


def reference_benchmark_placeholder(model: GameModel) -> dict[str, Any]:
    return {
        "$schema": "../schemas/reference-benchmark.v1.schema.json",
        "schemaVersion": 1,
        "benchmarkId": f"{model.id}.reference-benchmark",
        "revision": 1,
        "productId": model.id,
        "status": "BLOCKED",
        "createdAt": None,
        "frozenAt": None,
        "candidateDerived": False,
        "independenceReceipt": {
            "decision": "PENDING",
            "basis": None,
            "verifiedBy": None,
            "verifiedAt": None,
            "excludedCandidateProductId": model.id,
            "candidateArtifactsUsed": False,
        },
        "sources": [],
        "observations": [],
    }


def visual_calibration_placeholder(
    model: GameModel,
    *,
    benchmark_sha256: str,
) -> dict[str, Any]:
    return {
        "$schema": "../schemas/visual-calibration-receipt.v1.schema.json",
        "schemaVersion": 1,
        "calibrationId": f"{model.id}.visual-calibration",
        "revision": 1,
        "productId": model.id,
        "status": "BLOCKED",
        "benchmark": {
            "benchmarkId": f"{model.id}.reference-benchmark",
            "sha256": benchmark_sha256,
        },
        "methodology": {
            "calibratedAt": None,
            "calibratedBy": None,
            "freezeBeforeCandidateEvaluation": True,
            "candidateInputsUsed": False,
            "method": "PENDING_INDEPENDENT_REFERENCE_MEASUREMENT",
        },
        "thresholds": [],
    }


def release_quality_profile(model: GameModel, *, token_path: str | None) -> dict[str, Any]:
    blockers = [
        "HUMAN_PRODUCT_APPROVAL_REQUIRED",
        "TARGET_DEVICE_APPROVAL_REQUIRED",
        "PERFORMANCE_BUDGET_CALIBRATION_REQUIRED",
        "INDEPENDENT_REFERENCE_BENCHMARK_REQUIRED",
        "VISUAL_CALIBRATION_REQUIRED",
        "PRODUCTION_ASSET_MANIFEST_REQUIRED",
        "CORE_LOOP_E2E_EVIDENCE_REQUIRED",
        "EXACT_BUILD_RUNTIME_EVIDENCE_REQUIRED",
    ]
    if token_path is None:
        blockers.append("TOKEN_SET_REQUIRED")
    return {
        "schemaVersion": 1,
        "profileId": "release-quality",
        "productId": model.id,
        "status": "BLOCKED",
        "appliesTo": ["GAMEPLAY", "VISUAL", "ASSETS", "RELEASE"],
        "tokenSet": token_path,
        "minimumVisualScore": None,
        "blockers": blockers,
        "notes": (
            "This profile is derived from GameModel. Values requiring human or external "
            "authority remain absent and block the industrial release gate."
        ),
    }


def pending_asset_manifest(model: GameModel) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "productId": model.id,
        "status": "BLOCKED",
        "policy": {
            "externalToolboxAssets": "blocked_until_review",
            "requireScriptScan": True,
            "requireAllocation": True,
            "generatedRasterRuntime": "require-roblox-upload-before-live-use",
            "maxWorkspaceInstances": 25000,
        },
        # The scanner requires at least one approved and allocated asset.  Empty
        # is therefore a visible release failure, not an invented approved set.
        "assets": [],
    }


def pending_product_intent(
    model: GameModel,
    *,
    bindings: Mapping[str, Mapping[str, str]],
) -> dict[str, Any]:
    semantics = semantic_ids(model)
    return {
        "$schema": "../schemas/product-intent.v1.schema.json",
        "schemaVersion": 1,
        "intentId": f"{model.id}.intent",
        "revision": 1,
        "productId": model.id,
        "title": _title(model),
        "productClass": {
            "genre": model.genre,
            "templateFamily": _safe_id(model.genre, fallback="genre"),
        },
        "pillars": [
            {
                "id": f"verb-{verb}",
                "description": f"The product loop explicitly includes {verb}.",
            }
            for verb in semantics["gameplayVerbs"]
        ],
        "audience": {
            "description": (
                "Provisional platform baseline for desktop and phone, pending human "
                f"audience approval; up to {model.concurrent_players} concurrent player(s)."
            ),
            "targetDevices": list(TARGET_DEVICES),
        },
        "coreLoop": list(model.core_loop),
        "semantics": {
            "worldRoles": [{
                "id": semantics["worldRole"],
                "description": (
                    f"The primary navigational landmark selected by the {model.topology} world."
                ),
            }],
            "uiSurfaces": [{
                "id": semantics["uiSurface"],
                "description": "The player-facing interface visible in the initial session.",
            }],
            "gameplayVerbs": [
                {
                    "id": verb,
                    "description": f"Player-observable behavior for the {verb} loop verb.",
                }
                for verb in semantics["gameplayVerbs"]
            ],
        },
        # No caller supplied human authority.  Deliberately outside the owned
        # schema's accepted enum/nullability, so product truth reports BLOCKED
        # until a real approval replaces these values.
        "authorship": {
            "authorityKind": "pending-human-approval",
            "authorityId": None,
            "approvedAt": None,
            "candidateDerived": False,
        },
        "calibrationPolicy": {
            "requireIndependentReferences": True,
            "forbidCandidateDerivedThresholds": True,
            "requireCompleteThresholdCoverage": True,
        },
        "bindings": {name: dict(binding) for name, binding in bindings.items()},
    }


def rojo_project(model: GameModel) -> dict[str, Any]:
    return {
        "name": model.id,
        "tree": {
            "$className": "DataModel",
            "ReplicatedStorage": {
                "$className": "ReplicatedStorage",
                "WorldKit": {"$path": "../../roblox/lib/WorldKit"},
                "GameKit": {"$path": "../../roblox/lib/GameKit"},
                "Shared": {"$path": "src/shared"},
            },
            "ServerScriptService": {
                "$className": "ServerScriptService",
                "Gameplay": {"$path": "src/gameplay"},
                "Telemetry": {"$path": "src/telemetry"},
                "World": {"$path": "src/world"},
            },
            "StarterPlayer": {
                "$className": "StarterPlayer",
                "StarterPlayerScripts": {
                    "$className": "StarterPlayerScripts",
                    "Interface": {"$path": "src/interface"},
                },
            },
            "Workspace": {
                "$className": "Workspace",
                "$properties": {"Gravity": 196.2},
            },
            "Lighting": {"$className": "Lighting"},
        },
    }


def project_configuration(
    model: GameModel,
    *,
    token_path: str | None,
    schema_paths: list[str],
) -> dict[str, Any]:
    expected = [
        "rqe.project.json",
        "game.json",
        "blueprint.json",
        "default.project.json",
        "definition/product-intent.json",
        "definition/reference-bundle.json",
        "definition/reference-benchmark.json",
        "definition/visual-calibration.json",
        "definition/release-quality.json",
        "contracts/game-contract.json",
        "contracts/visual/visual-quality.json",
        "quality/quality-focus.json",
        "quality/probe-registry.v1.json",
        "scenarios/initial-runtime.json",
        "assets/asset-manifest.json",
        "src/world",
        "src/gameplay",
        "src/interface",
        "src/telemetry",
        "src/shared",
        *schema_paths,
    ]
    config: dict[str, Any] = {
        "name": model.id,
        "contract": "contracts/game-contract.json",
        "productIntent": "definition/product-intent.json",
        "rojoProject": "default.project.json",
        "assetManifest": "assets/asset-manifest.json",
        "qualityFocus": "quality/quality-focus.json",
        "probeRegistry": "quality/probe-registry.v1.json",
        "scripts": "src",
        "scanPaths": ["src"],
        "agentScenario": "scenarios/initial-runtime.json",
        "reports": "reports",
        "release": {"seed": int(model.sha256[:8], 16)},
        "expectedPaths": expected,
    }
    if token_path is not None:
        config["tokenSet"] = token_path
        config["expectedPaths"].append(token_path)
    return config


__all__ = [
    "game_contract",
    "initial_runtime_scenario",
    "pending_asset_manifest",
    "pending_product_intent",
    "project_configuration",
    "quality_focus",
    "reference_benchmark_placeholder",
    "reference_bundle",
    "release_quality_profile",
    "rojo_project",
    "semantic_ids",
    "visual_calibration_placeholder",
    "visual_quality_spec",
]
