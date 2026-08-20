"""The 113 primitives, each bound to the thing that actually implements it.

This file exists because "113 primitives are implemented" was, until now, a
sentence in a document. A prose claim about a surface this size drifts the
moment anything is renamed, and it drifts silently: nothing fails, the table
just stops being true. Twice already the platform doc listed primitives as
missing that had been shipped, and listed a family as complete while pointing at
a module the server never loaded.

So the claim is made here instead, as data, with every binding naming a concrete
target:

    MCP     a tool registered on the engine's MCP server
    BRIDGE  a command in the Studio bridge registry
    NONE    honestly unavailable, with the reason recorded

`tests/test_primitives.py` resolves every binding against the live registries.
A renamed tool, a module dropped from the server assembly, or a primitive
claimed without an implementation fails there rather than in a status table
somebody reads and believes.

Two rules keep this honest:

**A binding must resolve.** Marking something implemented without a target it
can be looked up by is exactly the failure this file was written to stop.

**Unavailable is a first-class state, not an omission.** `ui.click` needs
`VirtualInputManager`, which Roblox refuses to a plugin and to a LocalScript
alike. Deleting the row would make the surface look complete; recording it with
its reason keeps the gap visible and keeps the denominator honest.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Literal


Surface = Literal["MCP", "BRIDGE", "NONE"]


@dataclass(frozen=True)
class Primitive:
    """One primitive, and what stands behind it."""

    name: str
    family: str
    surface: Surface
    target: str = ""
    #: Why it is unavailable. Required when the surface is NONE, so a gap can
    #: never be recorded as a shrug.
    reason: str = ""
    note: str = ""

    def __post_init__(self) -> None:
        if self.surface == "NONE":
            if not self.reason:
                raise ValueError(f"{self.name}: an unavailable primitive must say why")
        elif not self.target:
            raise ValueError(f"{self.name}: an implemented primitive must name its target")

    @property
    def available(self) -> bool:
        return self.surface != "NONE"


def _p(name: str, family: str, surface: Surface, target: str = "", **kwargs: str) -> Primitive:
    return Primitive(name=name, family=family, surface=surface, target=target, **kwargs)


# --------------------------------------------------------------- 1. Studio
#
# The one family an agent needs *before* a bridge exists, so most of it sits on
# the MCP surface directly rather than behind the plugin.

STUDIO = (
    _p("studio.status", "Studio", "MCP", "studio_status", note="works with no plugin attached"),
    _p("studio.play", "Studio", "BRIDGE", "run.start"),
    _p("studio.stop", "Studio", "BRIDGE", "run.stop"),
    _p("studio.close", "Studio", "MCP", "studio_stop",
       note="destructive; refuses without confirmDiscardUnsavedWork"),
    _p("studio.build", "Studio", "MCP", "studio_build",
       note="Rojo, then a Luau compile pass -- Rojo packages sources without parsing them"),
    _p("studio.sync", "Studio", "MCP", "studio_build"),
    _p("studio.open", "Studio", "MCP", "studio_open", note="refuses without confirmation"),
    _p("studio.restart", "Studio", "MCP", "studio_restart", note="refuses without confirmation"),
    _p("studio.server.start", "Studio", "BRIDGE", "run.server",
       note="a bare server has no character, no PlayerGui and no client at all"),
    _p("studio.client.start", "Studio", "BRIDGE", "run.client"),
)

# ------------------------------------------------------------ 2. DataModel
#
# Before this family existed the only way to *write* the DataModel was
# `bridge.exec` -- arbitrary Luau, which has no schema, so nothing could
# validate it before it ran or describe what it changed after.

DATAMODEL = (
    _p("instance.find", "DataModel", "BRIDGE", "dm.find"),
    _p("instance.tree", "DataModel", "BRIDGE", "dm.tree"),
    _p("instance.get", "DataModel", "BRIDGE", "dm.properties"),
    _p("instance.create", "DataModel", "BRIDGE", "instance.create", note="at-most-once"),
    _p("instance.update", "DataModel", "BRIDGE", "instance.update", note="at-most-once"),
    _p("instance.delete", "DataModel", "BRIDGE", "instance.delete",
       note="at-most-once; a subtree above 256 is refused rather than performed"),
    _p("instance.clone", "DataModel", "BRIDGE", "instance.clone", note="at-most-once"),
    _p("instance.children", "DataModel", "BRIDGE", "instance.children"),
    _p("instance.descendants", "DataModel", "BRIDGE", "instance.descendants"),
    _p("instance.tags", "DataModel", "BRIDGE", "instance.tags"),
    _p("instance.attributes", "DataModel", "BRIDGE", "instance.attributes"),
)

# ---------------------------------------------------------------- 3. World

WORLD = (
    _p("world.raycast", "World", "BRIDGE", "world.raycast"),
    _p("world.bounds", "World", "BRIDGE", "world.bounds"),
    _p("world.overlaps", "World", "BRIDGE", "world.overlaps"),
    _p("world.pathfind", "World", "BRIDGE", "world.path",
       note="with navmesh control probe and approach points"),
    _p("world.snapshot", "World", "BRIDGE", "world.summary"),
    _p("world.region", "World", "BRIDGE", "world.region",
       note="GetPartBoundsInBox rather than a descendant scan"),
    _p("world.navigation", "World", "BRIDGE", "world.navigation",
       note="separates 'unreachable' from 'pathfinding is not working here at all'"),
    _p("world.spawn_points", "World", "BRIDGE", "world.spawn_points",
       note="reports ambiguous arrival, which is how a scenario becomes flaky"),
    _p("world.terrain", "World", "BRIDGE", "world.terrain",
       note="read and write voxels, capped at 400,000, reporting the grid snap"),
)

# -------------------------------------------------------------- 4. Runtime

RUNTIME = (
    _p("runtime.state", "Runtime", "BRIDGE", "run.state"),
    _p("runtime.logs", "Runtime", "BRIDGE", "log.tail"),
    _p("runtime.errors", "Runtime", "BRIDGE", "runtime.errors",
       note="split from warnings: a gate blocks on one and reports the other"),
    _p("runtime.warnings", "Runtime", "BRIDGE", "runtime.warnings"),
    _p("runtime.metrics", "Runtime", "BRIDGE", "runtime.metrics",
       note="p50/p95/p99 over a real window -- the tail is what a player feels"),
    _p("runtime.memory", "Runtime", "BRIDGE", "runtime.memory",
       note="an absent Stats item lands in `unavailable` rather than reporting zero"),
    _p("runtime.physics", "Runtime", "BRIDGE", "runtime.physics",
       note="separates one expensive constraint from 4,000 parts that never sleep"),
    _p("runtime.network", "Runtime", "BRIDGE", "runtime.network"),
    _p("runtime.events", "Runtime", "BRIDGE", "runtime.events",
       note="a plugin cannot subscribe to a game's own signals, and this says so"),
)

# --------------------------------------------------------------- 5. Player
#
# Still named `actor.*` on the wire. An *actor* is our synthetic rig and the
# family is really "drive a player", but renaming is a breaking change that
# deserves its own decision rather than arriving as a side effect.

PLAYER = (
    _p("player.spawn", "Player", "BRIDGE", "actor.spawn"),
    _p("player.move", "Player", "BRIDGE", "actor.navigate_to"),
    _p("player.walk_to", "Player", "BRIDGE", "actor.walk_to"),
    _p("player.jump", "Player", "BRIDGE", "actor.jump"),
    _p("player.teleport", "Player", "BRIDGE", "actor.teleport",
       note="zeroes momentum, so an actor does not slide off the destination"),
    _p("player.equip", "Player", "BRIDGE", "actor.equip",
       note="searches character and backpack, and names what it could reach when it fails"),
    _p("player.activate", "Player", "BRIDGE", "actor.activate",
       note="at-most-once: twice is two uses"),
    _p("player.interact", "Player", "BRIDGE", "actor.interact"),
    _p("player.inventory", "Player", "BRIDGE", "actor.inventory",
       note="distinguishes 'carrying nothing' from 'cannot carry anything'"),
    _p("player.state", "Player", "BRIDGE", "actor.state"),
)

# ------------------------------------------------------------------- 6. UI

UI = (
    _p("ui.tree", "UI", "BRIDGE", "client.gui_tree", note="effective visibility resolved"),
    _p("ui.state", "UI", "BRIDGE", "client.player_state"),
    _p("ui.text", "UI", "BRIDGE", "client.gui_text"),
    _p("ui.input", "UI", "BRIDGE", "client.gui_text",
       note="sets Text and releases focus, and says so -- no keystroke is synthesised"),
    _p("ui.scroll", "UI", "BRIDGE", "client.gui_scroll",
       note="reports the clamp, so a caller cannot believe it reached somewhere it could not"),
    _p("ui.viewport", "UI", "BRIDGE", "client.viewport",
       note="device class derived from the viewport rather than a platform enum"),
    _p("ui.snapshot", "UI", "BRIDGE", "client.gui_snapshot",
       note="every visible element with a measured rectangle, plus the off-screen count"),
    _p("ui.click", "UI", "MCP", "ui_click", note=(
        "delegated to Roblox's own MCP server: VirtualInputManager is refused both "
        "in a LocalScript and in a plugin (lacking capability RobloxScript), so no "
        "work on our side produces a real click. Refuses with instructions when no "
        "peer is configured, because a click reported without input delivered would "
        "let a UI requirement pass with nothing ever pressed"
    )),
)

# ------------------------------------------- 7. Camera and visual evidence

CAMERA = (
    _p("camera.set", "Camera", "BRIDGE", "camera.set"),
    _p("camera.get", "Camera", "BRIDGE", "camera.get"),
    _p("camera.orbit", "Camera", "BRIDGE", "camera.orbit",
       note="same subject, distance and pitch, different angle -- what makes "
            "'the rear face is undetailed' checkable"),
    _p("camera.follow", "Camera", "BRIDGE", "camera.follow",
       note="including release: a camera left Scriptable looks like the game has hung"),
    _p("camera.viewpoint", "Camera", "BRIDGE", "camera.viewpoint",
       note="the plugin holds no camera profiles; the token set does"),
    _p("capture.frame", "Camera", "MCP", "capture_frame",
       note="an untrustworthy frame is labelled rather than returned as evidence"),
    _p("capture.compare", "Camera", "MCP", "capture_compare"),
    _p("capture.sequence", "Camera", "MCP", "capture_sequence",
       note="a partial device matrix is reported incomplete, because the missing "
            "viewpoint is exactly the one nobody looked at"),
)

# -------------------------------------------------------------- 8. Quality
#
# The split is the point: `quality.snapshot` measures inside Studio and takes
# **no thresholds**. Every rule is policy in Python. A validator carrying its
# own limits into the tool that produces the artefact grades itself.

QUALITY = (
    _p("quality.snapshot", "Quality", "BRIDGE", "quality.snapshot", note="takes no thresholds"),
    _p("quality.geometry", "Quality", "MCP", "quality_evaluate"),
    _p("quality.density", "Quality", "MCP", "quality_evaluate"),
    _p("quality.scale", "Quality", "MCP", "quality_evaluate"),
    _p("quality.visibility", "Quality", "MCP", "quality_evaluate"),
    _p("quality.ui", "Quality", "MCP", "quality_evaluate"),
    _p("quality.visual", "Quality", "MCP", "quality_evaluate"),
    _p("quality.navigation", "Quality", "MCP", "quality_navigation",
       note="asks the navmesh directly"),
    _p("quality.performance", "Quality", "MCP", "quality_performance",
       note="judges the p99 rather than the mean"),
)

# ------------------------------------------------------------- 9. Scenario

SCENARIO = (
    _p("scenario.compile", "Scenario", "MCP", "scenario_compile",
       note="reports the shape without spending a live session on a malformed step"),
    _p("scenario.run", "Scenario", "MCP", "scenario_run",
       note="refuses rather than pretending when no session is reachable"),
    _p("scenario.assert", "Scenario", "MCP", "scenario_run", note="carried by the step verdicts"),
    _p("scenario.compare", "Scenario", "MCP", "scenario_compare",
       note="refuses outright when the scenario was edited between runs"),
    _p("scenario.step", "Scenario", "MCP", "scenario_step"),
    _p("scenario.replay", "Scenario", "MCP", "scenario_replay"),
)

# --------------------------------------------------------------- 10. Assets

ASSETS = (
    _p("asset.search", "Assets", "MCP", "asset_search"),
    _p("asset.preview", "Assets", "MCP", "mesh_previews"),
    _p("asset.inspect", "Assets", "MCP", "cloud_asset",
       note="moderation state: a published asset id is not an approved one"),
    _p("asset.validate", "Assets", "MCP", "mesh_validate"),
    _p("asset.prepare", "Assets", "MCP", "asset_prepare"),
    _p("asset.publish", "Assets", "MCP", "cloud_publish"),
    _p("asset.integrate", "Assets", "MCP", "asset_integrate"),
    _p("asset.status", "Assets", "MCP", "asset_capabilities"),
    _p("asset.capabilities", "Assets", "BRIDGE", "assets.capabilities"),
    _p("asset.generate.image", "Assets", "BRIDGE", "assets.create_image",
       note="EditableImage -> CreateAssetAsync -> real asset id"),
    _p("asset.generate.mesh", "Assets", "MCP", "mesh_build",
       note="headless Blender; approval needs topology *and* the visual critic"),
    _p("asset.generate.audio", "Assets", "MCP", "asset_generate_audio",
       note="Roblox takes mp3 and ogg, so wav-to-uploadable is a named BLOCKED "
            "when no encoder is installed"),
    _p("asset.generate.animation", "Assets", "MCP", "asset_generate_animation",
       note="R15 KeyframeSequence as .rbxmx; Roblox processes animations on "
            "import, so the file is a candidate for upload rather than a certainty"),
)

# ----------------------------------------------------------- 11. Open Cloud

CLOUD = (
    _p("cloud.operation", "Open Cloud", "MCP", "cloud_inspect",
       note="Luau Execution: TIMEOUT and BLOCKED are distinct states"),
    _p("cloud.universe", "Open Cloud", "MCP", "cloud_inspect"),
    _p("cloud.place", "Open Cloud", "MCP", "cloud_inspect",
       note="place *content* is refused: it is published as a version, and "
            "conflating the two overwrites a build with a field edit"),
    _p("cloud.publish", "Open Cloud", "MCP", "cloud_publish",
       note="saves by default; releasing to live servers needs explicit confirmation"),
    _p("cloud.version", "Open Cloud", "MCP", "cloud_inspect",
       note="publishing without seeing what came before is a one-way door"),
    _p("cloud.datastore", "Open Cloud", "MCP", "cloud_datastore",
       note="a save only the game can read is a save nobody can verify"),
    _p("cloud.asset", "Open Cloud", "MCP", "cloud_asset"),
)

# -------------------------------------------------------------- 12. Factory

FACTORY = (
    _p("factory.inspect", "Factory", "MCP", "factory_inspect"),
    _p("factory.compile", "Factory", "MCP", "plan_compile", note="the fail-closed measurement plan"),
    _p("factory.create_project", "Factory", "MCP", "factory_create_project"),
    _p("factory.execute", "Factory", "MCP", "factory_execute",
       note="durable DAG execution; unsupported work fails closed"),
    _p("factory.resume", "Factory", "MCP", "factory_execute"),
    _p("factory.abort", "Factory", "MCP", "factory_execute"),
    _p("factory.campaign", "Factory", "MCP", "factory_campaign"),
    _p("capabilities.list", "Factory", "MCP", "capabilities_report",
       note="states on every response that it cannot authorise a release"),
    _p("capabilities.select", "Factory", "MCP", "capabilities_select"),
    _p("capabilities.explain", "Factory", "MCP", "capabilities_explain"),
    _p("release.blockers", "Factory", "MCP", "release_blockers",
       note="orphan requirements, token conformance, minimum visual score"),
    _p("release.evaluate", "Factory", "MCP", "release_evaluate"),
    _p("release.promote", "Factory", "MCP", "release_promote", note="refuses without confirmation"),
)


# ------------------------------------- the MetaWorldModel authoring surface
#
# A *different* list from the 113 above, and kept separate on purpose. The 113
# are the engine's control surface -- drive Studio, read the DataModel, measure
# a running game. The list below is the authoring surface the MetaWorldModel
# document specifies at its end: what an agent needs to *make* something rather
# than to inspect it.
#
# The two overlap without being the same, and merging them would have hidden
# exactly what this table is for: several of these families are real capability
# the engine has and does not expose under the name the document asks for. A
# capability that cannot be called by the name it was specified under is not the
# same as one that ships.

METAWORLDMODEL = (
    # WORLD -- WorldKit exists in Luau (Blockout, Dress, Kit, Fab) and runs
    # through `sdk_run`, but only `inspect` is reachable as a named tool.
    _p("world.plan", "MetaWorldModel", "MCP", "world_plan",
       note="validates a described layout headlessly -- no Studio, nothing built"),
    _p("world.blockout", "MetaWorldModel", "MCP", "world_blockout",
       note="plans first, and refuses to build a layout that fails planning"),
    _p("world.validate", "MetaWorldModel", "MCP", "quality_evaluate"),
    _p("world.dress", "MetaWorldModel", "MCP", "world_dress"),
    _p("world.optimize", "MetaWorldModel", "MCP", "world_optimize",
       note="reported, not applied: removing a placement changes what the world looks like"),
    _p("world.inspect", "MetaWorldModel", "BRIDGE", "world.summary"),

    # GEOMETRY -- complete. `modify` is a revision, which is a new program
    # against the same brief rather than a mutation of a built mesh.
    _p("mesh.brief", "MetaWorldModel", "MCP", "mesh_brief"),
    _p("mesh.create", "MetaWorldModel", "MCP", "mesh_build"),
    _p("mesh.modify", "MetaWorldModel", "MCP", "mesh_build", note="a revision is a new program"),
    _p("mesh.inspect", "MetaWorldModel", "MCP", "mesh_inspect"),
    _p("mesh.optimize", "MetaWorldModel", "MCP", "mesh_build",
       note="the decimate operation, inside a program"),
    _p("mesh.validate", "MetaWorldModel", "MCP", "mesh_validate"),
    _p("mesh.render", "MetaWorldModel", "MCP", "mesh_previews"),
    _p("mesh.compare", "MetaWorldModel", "MCP", "mesh_compare"),
    _p("mesh.export", "MetaWorldModel", "MCP", "mesh_build", note="glb written into the package"),

    # MATERIAL -- built because the critic scores material separation at 28%
    # and the failure is total: the surface reads as one value and the
    # modelling underneath it is wasted.
    _p("material.create", "MetaWorldModel", "MCP", "material_create"),
    _p("material.apply", "MetaWorldModel", "MCP", "material_apply"),
    _p("material.validate", "MetaWorldModel", "MCP", "material_validate",
       note="predicts the critic's luminance measure from the palette, before a build"),

    # ASSETS
    _p("asset.search", "MetaWorldModel", "MCP", "asset_search"),
    _p("asset.inspect", "MetaWorldModel", "MCP", "cloud_asset"),
    _p("asset.preview", "MetaWorldModel", "MCP", "mesh_previews"),
    _p("asset.create", "MetaWorldModel", "MCP", "mesh_build"),
    _p("asset.publish", "MetaWorldModel", "MCP", "cloud_publish"),
    _p("asset.status", "MetaWorldModel", "MCP", "asset_capabilities"),
    _p("asset.integrate", "MetaWorldModel", "MCP", "asset_integrate"),

    # COMPOSITION -- the largest genuine gap. Kit.lua has deterministic
    # placement and instance.create can write the DataModel, so the parts
    # exist; the semantic layer the document asks for does not.
    _p("scene.place", "MetaWorldModel", "MCP", "scene_place"),
    _p("scene.scatter", "MetaWorldModel", "MCP", "scene_scatter",
       note="a jittered grid keyed by cell, matching Kit.seedFor exactly in both languages"),
    _p("scene.align", "MetaWorldModel", "MCP", "scene_align"),
    _p("scene.replace", "MetaWorldModel", "MCP", "scene_replace",
       note="refuses a swap that matches nothing"),
    _p("scene.variant", "MetaWorldModel", "MCP", "scene_variant",
       note="reports the spread, because a weighted set can be repetition with extra steps"),
    _p("scene.optimize", "MetaWorldModel", "MCP", "scene_optimize"),

    # VISUAL QA -- complete.
    _p("visual.capture", "MetaWorldModel", "MCP", "capture_frame"),
    _p("visual.inspect", "MetaWorldModel", "MCP", "visual_score",
       note="the per-view measurements, alongside the score"),
    _p("visual.compare", "MetaWorldModel", "MCP", "capture_compare"),
    _p("visual.score", "MetaWorldModel", "MCP", "visual_score"),
)


PRIMITIVES: tuple[Primitive, ...] = (
    STUDIO + DATAMODEL + WORLD + RUNTIME + PLAYER + UI
    + CAMERA + QUALITY + SCENARIO + ASSETS + CLOUD + FACTORY
)

#: The denominators the platform reports against. Held as data so a family
#: cannot silently gain or lose a primitive and still report "complete".
FAMILY_SIZES = {
    "Studio": 10,
    "DataModel": 11,
    "World": 9,
    "Runtime": 9,
    "Player": 10,
    "UI": 8,
    "Camera": 8,
    "Quality": 9,
    "Scenario": 6,
    "Assets": 13,
    "Open Cloud": 7,
    "Factory": 13,
}

TOTAL = sum(FAMILY_SIZES.values())


def by_family() -> dict[str, list[Primitive]]:
    grouped: dict[str, list[Primitive]] = {family: [] for family in FAMILY_SIZES}
    for primitive in PRIMITIVES:
        grouped[primitive.family].append(primitive)
    return grouped


def unavailable() -> list[Primitive]:
    return [p for p in PRIMITIVES if not p.available]


def metaworldmodel_coverage() -> dict[str, object]:
    """The authoring surface the MetaWorldModel document specifies.

    Reported separately from the 113 because they answer different questions,
    and because averaging them would let a complete control surface hide an
    incomplete authoring one.
    """

    available = [p for p in METAWORLDMODEL if p.available]
    groups: dict[str, list[Primitive]] = {}
    for primitive in METAWORLDMODEL:
        groups.setdefault(primitive.name.split(".")[0], []).append(primitive)
    return {
        "schemaVersion": 1,
        "total": len(METAWORLDMODEL),
        "available": len(available),
        "byGroup": {
            group: {"total": len(items), "available": sum(1 for p in items if p.available)}
            for group, items in groups.items()
        },
        "gaps": [
            {"name": p.name, "reason": p.reason}
            for p in METAWORLDMODEL if not p.available
        ],
    }


def coverage() -> dict[str, object]:
    """What is actually reachable, counted rather than asserted."""

    available = [p for p in PRIMITIVES if p.available]
    grouped = by_family()
    return {
        "schemaVersion": 1,
        "total": len(PRIMITIVES),
        "available": len(available),
        "unavailable": [
            {"name": p.name, "family": p.family, "reason": p.reason} for p in unavailable()
        ],
        "bySurface": {
            surface: sum(1 for p in PRIMITIVES if p.surface == surface)
            for surface in ("MCP", "BRIDGE", "NONE")
        },
        "byFamily": {
            family: {
                "declared": FAMILY_SIZES[family],
                "listed": len(items),
                "available": sum(1 for p in items if p.available),
            }
            for family, items in grouped.items()
        },
    }


def resolve(primitives: Iterable[Primitive] | None = None) -> dict[str, list[str]]:
    """Check every binding against the live registries.

    The whole point of this module. Returns the unresolved targets by surface;
    an empty result is the only passing state.
    """

    from .hub.commands import load_default_registry
    from .mcp.tools import build_server

    items = list(primitives if primitives is not None else PRIMITIVES)
    mcp_tools = set(build_server(".", include_bridge=True).tools)
    bridge_commands = set(load_default_registry(verify_dispatcher=False).methods())

    missing: dict[str, list[str]] = {"MCP": [], "BRIDGE": []}
    for primitive in items:
        if primitive.surface == "MCP" and primitive.target not in mcp_tools:
            missing["MCP"].append(f"{primitive.name} -> {primitive.target}")
        elif primitive.surface == "BRIDGE" and primitive.target not in bridge_commands:
            missing["BRIDGE"].append(f"{primitive.name} -> {primitive.target}")
    return {surface: names for surface, names in missing.items() if names}
