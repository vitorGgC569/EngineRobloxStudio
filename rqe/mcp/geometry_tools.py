"""The modelling runtime, exposed to an agent.

These are the tools an LLM should see. Not `bpy.ops.mesh.foo(...)` -- `bpy` stays
behind the worker, and an agent that could call it directly would be writing
scripts nothing can validate before they run.

    mesh_vocabulary   the operation surface, before writing a program
    mesh_brief        state the intent, and find out which backend suits it
    mesh_build        execute a program and get an asset package back
    mesh_inspect      topology, dimensions, materials of a built asset
    mesh_validate     Roblox's rules against a mesh file
    mesh_previews     the render paths, for the visual critic
    mesh_compare      what changed between two revisions

The loop the architecture is built around runs entirely through these: brief,
program, build, look at the renders, revise the program, build again, compare.
Nothing here publishes -- publishing is irreversible and does not belong inside
a loop.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .server import EngineMcpServer, Tool, ToolError


DEFAULT_WORKSPACE = ".tmp/geometry"


def _workspace(root: Path, arguments: dict[str, Any]) -> Path:
    relative = arguments.get("workspace") or DEFAULT_WORKSPACE
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as exc:
        raise ToolError("workspace must stay inside the project root") from exc
    return path


def _load_brief(arguments: dict[str, Any]):
    from ..geometry import BriefError, load_brief

    try:
        return load_brief(arguments["brief"])
    except BriefError as exc:
        raise ToolError(str(exc)) from exc


def register_geometry_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    BRIEF_SCHEMA = {
        "type": "object",
        "required": ["id", "dimensions", "style", "silhouette", "materials", "gameplayRole"],
        "properties": {
            "id": {"type": "string", "minLength": 1},
            "dimensions": {
                "type": "array", "minItems": 3, "maxItems": 3,
                "items": {"type": "number", "exclusiveMinimum": 0},
                "description": "width, height, depth in studs, Y-up like Roblox",
            },
            "style": {"type": "string", "minLength": 1},
            "silhouette": {
                "type": "string", "minLength": 1,
                "description": "what the shape reads as; this is what a visual critique scores",
            },
            "materials": {"type": "array", "minItems": 1, "items": {"type": "string", "minLength": 1}},
            "triangleBudget": {"type": "integer", "minimum": 4, "maximum": 20000},
            "gameplayRole": {"type": "string", "minLength": 1},
            "collision": {"type": "string"},
            "requireWatertight": {"type": "boolean"},
            "notes": {"type": "string"},
            "references": {"type": "array", "items": {"type": "object"}},
        },
        "additionalProperties": False,
    }

    # ------------------------------------------------------------ vocabulary

    def mesh_vocabulary(_: dict[str, Any]) -> dict[str, Any]:
        from ..geometry import capabilities, vocabulary

        from ..geometry.programs import BY_ROLE
        from ..geometry.structural import MODULE, SILHOUETTES

        return {
            "worker": capabilities(),
            **vocabulary(),
            # A caller who does not know these exist writes a program by hand
            # for a piece the engine already has a grammar for.
            "rolesWithAProgram": sorted(BY_ROLE),
            "structuralSilhouettes": {
                shape: family for shape, family in sorted(SILHOUETTES.items())
            },
            "gridModule": MODULE,
            "note": (
                "`structure` covers the whole built world -- walls, floors, "
                "members and roofs -- and the silhouette picks the piece. "
                "Structural dimensions snap to gridModule so two pieces meet "
                "with no gap; that is the entire point of a kit. Note that the "
                "router sends `structure` to worldkit by default, so pass "
                "backend:'blender' to use these programs."
            ),
        }

    server.register(Tool(
        name="mesh_vocabulary",
        description=(
            "The modelling operations a program may use, which roles already "
            "have a grammar, and the structural silhouettes that grammar can "
            "build. Read this before writing a program by hand."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=mesh_vocabulary,
    ))

    # ----------------------------------------------------------------- brief

    def mesh_brief(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry import choose_backend

        brief = _load_brief(arguments)
        selection = choose_backend(brief, override=arguments.get("backend"))
        return {
            "brief": brief.to_dict(),
            "sha256": brief.sha256,
            "backend": selection,
            "budget": {
                "triangles": brief.budget.triangles,
                "materialSlots": brief.budget.material_slots,
                "requireUv": brief.budget.require_uv,
                "requireWatertight": brief.budget.require_watertight,
            },
        }

    server.register(Tool(
        name="mesh_brief",
        description=(
            "Validate an asset brief and report which modelling backend suits it. A crate "
            "is a procedural model, a modular building is WorldKit, a rock is an editable "
            "mesh, a stylised machine is Blender -- this says which and why."
        ),
        input_schema={
            "type": "object",
            "required": ["brief"],
            "additionalProperties": False,
            "properties": {"brief": BRIEF_SCHEMA, "backend": {"type": "string"}},
        },
        handler=mesh_brief,
    ))

    # ----------------------------------------------------------------- build

    def mesh_build(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry import GeometryPipeline

        brief = _load_brief(arguments)
        pipeline = GeometryPipeline(_workspace(root, arguments))
        outcome = pipeline.build(
            brief,
            arguments["program"],
            revision=int(arguments.get("revision", 1)),
            backend_override=arguments.get("backend"),
        )
        payload = outcome.to_dict()
        payload["summary"] = outcome.summary()
        return payload

    server.register(Tool(
        name="mesh_build",
        description=(
            "Execute a modelling program against a brief and return an asset package: the "
            "mesh, five preview renders, a topology analysis and a verdict. Does not "
            "publish anything."
        ),
        input_schema={
            "type": "object",
            "required": ["brief", "program"],
            "additionalProperties": False,
            "properties": {
                "brief": BRIEF_SCHEMA,
                "program": {"type": "object", "description": "a modelling program; see mesh_vocabulary"},
                "revision": {"type": "integer", "minimum": 1},
                "backend": {"type": "string"},
                "workspace": {"type": "string"},
            },
        },
        handler=mesh_build,
    ))

    # --------------------------------------------------------------- inspect

    def _open_package(arguments: dict[str, Any]):
        from ..geometry import AssetPackage, PackageError

        path = (root / arguments["package"]).resolve()
        try:
            path.relative_to(root.resolve())
        except ValueError as exc:
            raise ToolError("package must be inside the project root") from exc
        try:
            return AssetPackage.open(path)
        except PackageError as exc:
            raise ToolError(str(exc)) from exc

    def mesh_inspect(arguments: dict[str, Any]) -> dict[str, Any]:
        package = _open_package(arguments)
        manifest = package.manifest()
        analyses: dict[str, Any] = {}
        for name in ("topology", "validation", "dimensions", "materials", "brief"):
            try:
                analyses[name] = package.analysis(name)
            except Exception:  # noqa: BLE001 - an absent analysis is reported by omission
                continue
        return {
            "assetId": package.asset_id,
            "status": manifest.get("status"),
            "approved": manifest.get("approved"),
            "triangles": manifest.get("triangles"),
            "contentHash": manifest.get("contentHash"),
            "mesh": str(package.mesh()) if package.mesh() else None,
            "previews": [str(path) for path in package.previews()],
            "integrity": package.verify(),
            "analyses": analyses,
        }

    server.register(Tool(
        name="mesh_inspect",
        description=(
            "Everything known about a built asset: topology, validation findings, "
            "dimensions against the brief, materials, and whether the package is intact."
        ),
        input_schema={
            "type": "object",
            "required": ["package"],
            "additionalProperties": False,
            "properties": {"package": {"type": "string", "minLength": 1}},
        },
        handler=mesh_inspect,
    ))

    def mesh_previews(arguments: dict[str, Any]) -> dict[str, Any]:
        package = _open_package(arguments)
        previews = package.previews()
        if not previews:
            raise ToolError(
                f"package {package.asset_id} has no renders, so nothing can review it"
            )
        return {
            "assetId": package.asset_id,
            "views": {path.stem: str(path) for path in previews},
            "count": len(previews),
        }

    server.register(Tool(
        name="mesh_previews",
        description=(
            "The render paths for an asset, for a visual critique. Five fixed angles with "
            "fixed lighting, so two revisions are comparable."
        ),
        input_schema={
            "type": "object",
            "required": ["package"],
            "additionalProperties": False,
            "properties": {"package": {"type": "string", "minLength": 1}},
        },
        handler=mesh_previews,
    ))

    # -------------------------------------------------------------- validate

    def mesh_validate(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry import Budget, GeometryWorker, BlenderUnavailable, validate_analysis

        path = (root / arguments["mesh"]).resolve()
        if not path.is_file():
            raise ToolError(f"mesh not found: {path}")
        try:
            worker = GeometryWorker()
        except BlenderUnavailable as exc:
            raise ToolError(str(exc)) from exc

        result = worker.analyse(path)
        if not result.ok:
            raise ToolError(result.error or "topology analysis failed")

        budget = Budget(
            triangles=int(arguments.get("triangleBudget", 20000)),
            require_uv=bool(arguments.get("requireUv", True)),
            require_watertight=bool(arguments.get("requireWatertight", False)),
        )
        validation = validate_analysis(result.data, budget)
        return {
            "mesh": str(path),
            "verdict": "APPROVED_FOR_IMPORT" if validation.approved else "BLOCKED",
            **validation.to_dict(),
            "summary": validation.summary(),
        }

    server.register(Tool(
        name="mesh_validate",
        description=(
            "Apply Roblox's mesh rules to a file: triangle budget, degenerate faces, "
            "manifold integrity, normals, UVs, materials, dimensions, origin. Run this "
            "before any upload."
        ),
        input_schema={
            "type": "object",
            "required": ["mesh"],
            "additionalProperties": False,
            "properties": {
                "mesh": {"type": "string", "minLength": 1},
                "triangleBudget": {"type": "integer", "minimum": 4, "maximum": 20000},
                "requireUv": {"type": "boolean"},
                "requireWatertight": {"type": "boolean"},
            },
        },
        handler=mesh_validate,
    ))

    # --------------------------------------------------------------- compare

    def mesh_compare(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry import GeometryPipeline

        before = _open_package({"package": arguments["before"]})
        after = _open_package({"package": arguments["after"]})
        pipeline = GeometryPipeline(_workspace(root, arguments))
        comparison = pipeline.compare(before, after)
        if comparison["identical"]:
            # The failure mode this exists to catch: an agent revises a program
            # and the change had no effect on the geometry at all.
            comparison["warning"] = (
                "the two revisions are byte-identical; the revision changed nothing"
            )
        return comparison

    server.register(Tool(
        name="mesh_compare",
        description=(
            "What changed between two asset revisions, by content hash rather than "
            "timestamp. Detects a revision that changed nothing."
        ),
        input_schema={
            "type": "object",
            "required": ["before", "after"],
            "additionalProperties": False,
            "properties": {
                "before": {"type": "string", "minLength": 1},
                "after": {"type": "string", "minLength": 1},
                "workspace": {"type": "string"},
            },
        },
        handler=mesh_compare,
    ))

    def visual_score(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry.critic import CALIBRATION, CriticError, critique, critique_package

        if "package" in arguments:
            package = _open_package(arguments)
            source: Any = package
            label = package.asset_id
        else:
            directory = Path(arguments["previews"])
            if not directory.is_dir():
                raise ToolError(f"{directory} is not a directory of renders")
            source = sorted(directory.glob("*.png"))
            # Renders live in a directory called "previews", so its own name
            # identifies nothing -- every asset would report the same subject.
            label = (directory.parent.name if directory.name == "previews" else directory.name)

        try:
            result = (critique_package(source) if not isinstance(source, list)
                      else critique(source))
        except CriticError as exc:
            # Surfaced as an error rather than a zero. "Unreadable" and "bad"
            # are different findings and only one of them is about the asset.
            raise ToolError(str(exc)) from exc

        payload = result.to_dict()
        payload["subject"] = label
        payload["calibration"] = {
            "ladder": list(CALIBRATION["ladder"]),
            "unscored": list(CALIBRATION["unscored"]),
            "note": (
                "thresholds come from a reference ladder built before any candidate "
                "was measured, never from the asset being judged"
            ),
        }
        return payload

    server.register(Tool(
        name="visual_score",
        description=(
            "Score an asset's renders on silhouette, material separation and detail "
            "distribution, and return concrete revisions for what is wrong. Measures "
            "composition defects only: a high score means nothing measurably wrong, "
            "not good. Refuses to score renders it cannot read rather than returning "
            "a zero that looks like a verdict."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "package": {"type": "string", "minLength": 1},
                "previews": {
                    "type": "string",
                    "description": "a directory of renders, as an alternative to a package",
                },
                "workspace": {"type": "string"},
            },
        },
        handler=visual_score,
    ))

    def visual_thresholds(_arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry import critic

        return {
            "approvalScore": critic.APPROVAL_SCORE,
            "weights": dict(critic.AXIS_WEIGHTS),
            "bands": {
                "silhouetteShape": list(critic.SILHOUETTE_SHAPE_BAND),
                "massBalance": list(critic.MASS_BALANCE_BAND),
                "luminanceSpread": list(critic.LUMINANCE_SPREAD_BAND),
                "edgeDensity": list(critic.EDGE_DENSITY_BAND),
                "focalContrastFloor": critic.FOCAL_CONTRAST_FLOOR,
                "viewBalanceFloor": critic.VIEW_BALANCE_FLOOR,
                "crossViewIouCeiling": critic.CROSS_VIEW_IOU_CEILING,
            },
            "calibration": {key: list(value) if isinstance(value, tuple) else value
                            for key, value in critic.CALIBRATION.items()},
        }

    server.register(Tool(
        name="visual_thresholds",
        description=(
            "The bar an asset is scored against, and the reference ladder it was "
            "calibrated on. Readable so a low score can be argued with rather than "
            "merely obeyed."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=visual_thresholds,
    ))

    # -- the material family ---------------------------------------------
    #
    # A family rather than a parameter because material separation is 28% of an
    # asset's visual score, and the way it fails is total: the whole surface
    # reads as one value and every hour of modelling underneath it is wasted.

    def _tokens(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..tokens import TokenError, load_token_set

        relative = arguments.get("tokens", "tokens/brickfarm.json")
        if not (root / relative).is_file():
            raise ToolError(f"no token set at {relative}")
        try:
            # Loaded through the validator rather than read as JSON: a token set
            # that fails its own schema must not silently supply colours.
            return load_token_set(root, relative).data
        except TokenError as exc:
            raise ToolError(f"{relative}: {exc}") from exc

    def material_create(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry.materials import MaterialError, create, palette_roles, validate

        tokens = _tokens(arguments)
        requested = arguments.get("slots")
        if not requested:
            # Nothing to build is not an error worth guessing past: return the
            # palette so the caller can choose, rather than inventing a set.
            return {"roles": palette_roles(tokens), "slots": []}

        try:
            slots = [
                create(
                    item["role"], tokens=tokens,
                    name=item.get("name"),
                    roughness=item.get("roughness"),
                    metallic=item.get("metallic", 0.0),
                    emissive=bool(item.get("emissive", False)),
                    darken=float(item.get("darken", 0.0)),
                )
                for item in requested
            ]
        except (MaterialError, KeyError) as exc:
            raise ToolError(str(exc)) from exc

        return {
            "slots": [slot.to_dict() for slot in slots],
            "validation": validate(slots),
            "note": (
                "colours come from the token set; a program naming its own RGB is a "
                "second palette that drifts from the game's"
            ),
        }

    server.register(Tool(
        name="material_create",
        description=(
            "Build material slots from the game's palette roles, with optional darkening "
            "for recesses and emission for a focal point. Called with no slots, returns "
            "the available roles rather than guessing a set."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "tokens": {"type": "string"},
                "slots": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["role"],
                        "additionalProperties": False,
                        "properties": {
                            "role": {"type": "string"},
                            "name": {"type": "string"},
                            "roughness": {"type": "number", "minimum": 0, "maximum": 1},
                            "metallic": {"type": "number", "minimum": 0, "maximum": 1},
                            "emissive": {"type": "boolean"},
                            "darken": {"type": "number", "minimum": 0, "maximum": 0.95},
                        },
                    },
                },
            },
        },
        handler=material_create,
    ))

    def material_apply(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry.materials import MaterialError, apply, create, validate

        tokens = _tokens(arguments)
        program = arguments["program"]
        try:
            assignments = {
                part: create(
                    spec["role"], tokens=tokens, name=spec.get("name"),
                    roughness=spec.get("roughness"), metallic=spec.get("metallic", 0.0),
                    emissive=bool(spec.get("emissive", False)),
                    darken=float(spec.get("darken", 0.0)),
                )
                for part, spec in arguments["assign"].items()
            }
            updated = apply(program, assignments)
        except (MaterialError, KeyError) as exc:
            raise ToolError(str(exc)) from exc

        return {
            "program": updated,
            "painted": sorted(assignments),
            "validation": validate(assignments.values()),
            "note": (
                "materials are assigned per part before the join, because slots "
                "appended to a joined object reach no faces at all"
            ),
        }

    server.register(Tool(
        name="material_apply",
        description=(
            "Put materials on the parts of a modelling program and return the updated "
            "program. Places every assignment before the join, which is the only "
            "ordering that survives: slots appended to a joined mesh render nowhere "
            "while the manifest still reports them."
        ),
        input_schema={
            "type": "object",
            "required": ["program", "assign"],
            "additionalProperties": False,
            "properties": {
                "program": {"type": "object"},
                "assign": {
                    "type": "object",
                    "description": "part name -> {role, name?, darken?, emissive?, ...}",
                    "additionalProperties": {"type": "object"},
                },
                "tokens": {"type": "string"},
            },
        },
        handler=material_apply,
    ))

    def material_validate(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..geometry.materials import MaterialSlot, validate

        slots = [
            MaterialSlot(
                name=item.get("name", f"slot{index}"),
                base_color=tuple(item["baseColor"]),
                roughness=float(item.get("roughness", 0.6)),
                metallic=float(item.get("metallic", 0.0)),
                emissive=tuple(item["emissive"]) if item.get("emissive") else None,
                emissive_strength=float(item.get("emissiveStrength", 0.0)),
            )
            for index, item in enumerate(arguments.get("slots", []))
        ]
        return validate(slots)

    server.register(Tool(
        name="material_validate",
        description=(
            "Predict what the visual critic will measure, from the palette alone and "
            "before anything is built. A build plus five renders costs a minute; a flat "
            "palette is knowable in milliseconds. Reported as a prediction, because "
            "lighting and geometry both move the value measured from the render."
        ),
        input_schema={
            "type": "object",
            "required": ["slots"],
            "additionalProperties": False,
            "properties": {
                "slots": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["baseColor"],
                        "properties": {
                            "name": {"type": "string"},
                            "baseColor": {
                                "type": "array", "minItems": 3, "maxItems": 3,
                                "items": {"type": "integer", "minimum": 0, "maximum": 255},
                            },
                            "roughness": {"type": "number"},
                            "metallic": {"type": "number"},
                            "emissive": {"type": "array", "minItems": 3, "maxItems": 3},
                            "emissiveStrength": {"type": "number"},
                        },
                    },
                },
            },
        },
        handler=material_validate,
    ))

    return server
