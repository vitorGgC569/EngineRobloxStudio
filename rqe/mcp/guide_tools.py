"""The map. One tool that explains the other hundred and twenty.

A surface this size is not usable by reading it. An agent handed 123 tool
descriptions has to infer the order from the names, and the names do not carry
it: nothing in `world_blockout` or `material_apply` says which comes first, that
one needs a game to exist and the other needs Studio open, or that `producer_run`
does both and skips the choice entirely.

So this is a map, not a list. It answers the two questions an agent actually has
-- *where do I start* and *what do I call next* -- and it is built from the live
registry, so a family added tomorrow appears here without anyone remembering to
write it down. The routes are hand-written because ordering is knowledge; the
inventory is generated because inventories rot.
"""

from __future__ import annotations

from typing import Any

from .server import Tool


#: What each family is for, in one line, in the order an agent meets them.
#:
#: Families not listed here still appear in the inventory -- they are reported as
#: undescribed rather than hidden, because a tool nobody can explain is a tool
#: nobody should reach for first.
FAMILIES: dict[str, str] = {
    "recipe": "genres the engine knows, and whether a design delivers the one it claims",
    "producer": "brief in, whole game out -- the shortcut past every other family",
    "game": "create, list and inspect games in this workspace",
    "world": "blockout: the shape of the place, before it looks like anything",
    "scene": "place, scatter and arrange things in a world that already exists",
    "nature": "plant trees and rocks deterministically inside a footprint",
    "setpiece": "whole authored arrangements, not single props",
    "material": "PBR materials and surface treatment",
    "tokens": "the design tokens every other family reads its colours and sizes from",
    "design": "art direction: mood, palette, the key a game is built in",
    "mesh": "real geometry -- runtime MeshParts built from vertex data, no upload",
    "camera": "framing, which is half the language of a scene",
    "vfx": "bursts, highlights, trails and lights, coloured from tokens",
    "guidance": "mark where the player should look next",
    "ui": "screens: generate one from a template, or compose one element by element",
    "economy": "currencies, prices, and whether the numbers close",
    "gameplay": "behaviour as data -- when this happens, if that holds, do this",
    "pursuit": "creatures that chase, flee or patrol, with real pathfinding",
    "audio": "cues and the sound graph -- read the events before naming one",
    "sourcing": "find, adopt and publish external assets -- reuse before generate",
    "asset": "assets already in this workspace",
    "content": "text, names and copy",
    "studio": "the live Studio session: serve, restart, exec, play",
    "bridge": "raw JSON-RPC into the open place; anything the SDK can do",
    "capture": "screenshots -- the only way to find out what it looks like",
    "scenario": "drive a real player through the running game",
    "visual": "judge a frame: what a person would say about the picture",
    "quality": "gates, evidence and whether a claim is proven",
    "plan": "compile a contract into what must be measured",
    "release": "immutable fail-closed releases",
    "place": "ship a built game into a real Roblox experience",
    "cloud": "Open Cloud: assets, data stores, luau execution",
    "capabilities": "what this engine can and cannot do, and where the gaps are",
    "knowledge": "what previous games landed on -- ratios, layouts, what verified",
    "instance": "create, clone, update, reparent, destroy, list -- directly",
    "spatial": "raycast, overlap, line of sight, ground, path",
    "pattern": "code shapes worth copying, with the source",
    "federated": "what Roblox own MCP server can do and this bridge cannot",
    "sdk": "what exists in the library: signatures, search by intent, source, skeletons",
    "reuse": "does it already exist? all four shelves -- engine, library, games, kits",
    "code": "write scripts into the place and reload without a restart",
    "run": "raw Luau, in any context -- the escape hatch",
    "compile": "does this parse, without spending a run",
    "test": "assertions inside the engine",
    "dm": "what is in the DataModel right now",
    "logs": "the print and warn of the running game",
    "watch": "what an attribute did while you were not looking",
    "place": "put things where you want, by coordinate or by relation",
    "luau": "check Luau without running it",
    "factory": "the whole pipeline, end to end",
    "system": "processes, ports and health",
    "engine": "what is installed and reachable right now",
    "staging": "what the staging modules can do, read from the open place",
    "conveyor": "working belts that carry what lands on them",
    "fab": "solid modelling: cut doors and windows into real geometry",
    "policy": "what a player may legally be shown -- enforced, not taste",
    "reach": "servers talking to each other, and state that outlives one",
    "physics": "ropes, springs, joints, forces and ragdoll -- a world that moves",
    "interact": "clicks, prompts, signs, labels, welds and hinges -- a world you can touch",
    "chat": "slash commands, bubbles, and the filtering that is not optional",
    "team": "teams, whose colours must not collide",
    "badge": "achievements; ids come from the website",
    "text": "localisation, and the phrases nobody has translated",
    "acoustics": "rooms that sound like rooms -- reverb zones with hysteresis",
    "ship": "streaming and the settings that decide whether a big place runs",
    "monetize": "game passes and developer products -- real money, not game currency",
    "corpus": "open built games and look at them, rather than trusting the build",
    "terrain": "voxel ground: heightfields, caves, water, material painting",
    "motion": "procedural animation -- creatures that walk rather than slide",
    "lighting": "post-processing: haze, bloom, grade, sun rays, depth of field",
    "pacing": "the rhythm of a session",
    "rqe": "this map",
}


#: The orders that actually work, learned by doing them wrong first.
#:
#: **Every family must appear in at least one route**, and a test enforces it.
#: The inventory below is generated and cannot drift, but routes are written by
#: hand -- and after one long session of adding families, 31 of 55 had no route
#: at all. An agent reading the routes never learned that the world could be made
#: touchable, or that Blender was reachable. A map that stops covering the
#: territory is worse than no map, because it is still believed.
ROUTES: list[dict[str, Any]] = [
    {
        "goal": "Before you write a system, find out whether it exists",
        "when": "always, and especially when you are sure it does not",
        "steps": [
            "reuse_search -- ask with a sentence: 'hold a weapon in the hand'",
            "sdk_search -- narrower: library signatures only, by intent",
            "sdk_source -- read what you found before deciding it does not fit",
            "sdk_signature -- what it takes, parsed from the source",
        ],
        "note": (
            "`reuse_search` searches the Forge engine, roblox/lib, every game's "
            "source and the kits at once. A kit is a *finished game*: an agent "
            "began writing a zombie system with a complete, running zombie "
            "survival game one directory away, and hand-wrote `Rig.grip`, a "
            "viewmodel and a joint poser that all already existed. That was not "
            "missing information. It was not having asked."
        ),
    },
    {
        "goal": "Find your way around",
        "when": "first contact, or you cannot remember what exists",
        "steps": [
            "rqe_guide -- this map; pass a family name for its tools",
            "reuse_search -- does the thing you are about to build already exist",
            "engine_capabilities -- what is installed and reachable right now",
            "capabilities_report -- what the engine can and cannot do, with gaps",
            "system_catalogue -- processes, ports and health",
            "knowledge_coverage -- what previous games taught, and what they could not",
        ],
        "note": (
            "The inventory here is read from the live registry, so a family "
            "added tomorrow appears without anyone remembering to write it down."
        ),
    },
    {
        "goal": "Make a whole game from a one-line brief",
        "when": "you want a playable thing and do not want to make every choice",
        "steps": [
            "recipe_catalogue -- which genres have a production path",
            "recipe_apply -- a genre, theme and pitch into a whole model",
            "producer_run -- brief in, game out; it decides everything",
            "producer_stages -- what it did, stage by stage",
            "studio_restart -- open the built place",
            "capture_frame -- look at it before believing it",
        ],
        "note": (
            "This is the shortcut. It is also the reason a horror brief once came "
            "out as a tower defense in a horror palette: the recipe chooses the "
            "game. When the judgement is yours, compose instead."
        ),
    },
    {
        "goal": "Compose a game yourself, a piece at a time",
        "when": "you know what you want and the recipe does not have it",
        "steps": [
            "game_new -- somewhere to put it",
            "game_vocabulary -- what a game model may contain",
            "design_compile and tokens_inspect -- pick the key before building",
            "world_grammar then world_plan then world_blockout -- the shape",
            "scene_place / scene_scatter -- fill it",
            "world_dress -- the pass that makes a blockout a place",
            "material_apply -- surfaces",
            "game_compile and game_validate -- does the model hold together",
        ],
        "note": (
            "Order matters in one place only: tokens before anything that draws. "
            "Everything else can be revisited."
        ),
    },
    {
        "goal": "Build the ground itself",
        "when": "the place is standing on a flat plate and it shows",
        "steps": [
            "terrain_report -- what is actually there, sampled not assumed",
            "terrain_sculpt -- hills, water, and flattened plots for buildings",
            "terrain_paint and terrain_tint -- two materials, agreeing with the palette",
            "terrain_fill with carve -- caves, trenches, quarries",
            "nature_scatter -- plant it, with keepClear over the roads",
        ],
        "note": (
            "Terrain is on a 4-stud grid and so is the structural kit, so a wall "
            "meets sculpted ground. Sculpt before you build, or pass flatten "
            "zones for whatever is already there."
        ),
    },
    {
        "goal": "Make the world touchable",
        "when": "a player can walk through it and cannot do anything to it",
        "steps": [
            "interact_report -- how much of this world can be touched at all",
            "interact_touchable -- prompts and clickables",
            "interact_sign and interact_label -- text they can read",
            "interact_attach -- welds and hinges: doors, levers, lids",
            "physics_join -- ropes, springs, sliders and pushes: things that move",
            "physics_ragdoll and physics_report -- bodies that fall, and what is inert",
            "conveyor_build -- belts that carry what lands on them",
            "guidance_focus -- mark where to look next",
        ],
        "note": (
            "A place with zero interactive parts is scenery. Roblox fails "
            "silently at all of this -- a weld between two anchored parts does "
            "nothing and says nothing -- so read the refusals."
        ),
    },
    {
        "goal": "Give a creature intent",
        "when": "something in the world should follow, avoid, or walk a beat",
        "steps": [
            "pursuit_start -- try it live; it animates while it moves",
            "pursuit_report -- what state each one is in",
            "motion_play -- only for a gait it is not moving with, such as idle",
            "motion_report -- the gaits available and what is running",
            "gameplay_install -- a chase rule, so it survives a restart",
        ],
        "note": (
            "Works on models with no Humanoid, which is what most stylised "
            "creatures are. `unreachable` in the report means pathfinding failed "
            "repeatedly -- usually walled in, which looks identical to a bug."
        ),
    },
    {
        "goal": "Write the behaviour",
        "when": "the world exists and nothing happens in it",
        "steps": [
            "gameplay_vocabulary -- what a rule may say",
            "gameplay_check -- validate against what this game declares",
            "gameplay_compile -- what the runtime would install",
            "economy_design and economy_from_model -- currencies, and whether they close",
            "content_generate and content_drop_table -- what the loop hands out",
            "pacing_simulate -- the rhythm of a session",
        ],
        "note": (
            "Behaviour is data: triggers, conditions and effects against a fixed "
            "vocabulary. A rule naming a currency the economy never declared is "
            "refused at authoring time rather than failing silently in a live game."
        ),
    },
    {
        "goal": "Build the interface",
        "when": "there is a game and no way to read its state",
        "steps": [
            "ui_catalogue -- the design system parts",
            "ui_compose -- a screen as data, bound live to attributes",
            "ui_screen -- a whole screen from a template instead",
            "ui_screens_for_model -- what this game needs",
            "ui_click -- drive it like a player",
        ],
        "note": (
            "Every composed panel gets a layout, so children cannot pile at the "
            "origin -- which every generated game did, invisibly, because nobody "
            "opened a screen."
        ),
    },
    {
        "goal": "Make it look finished rather than built",
        "when": "the world is right and it still reads as somebody first game",
        "steps": [
            "design_analyse -- what the art direction says it should be",
            "lighting_grade -- haze, bloom, grade; most of looks-expensive",
            "camera_frame and camera_sweep -- framing is half the language",
            "vfx_apply -- bursts, highlights and lights from token roles",
            "setpiece_build -- whole authored arrangements, not single props",
            "acoustics_install -- rooms that sound like rooms",
            "audio_events then audio_play -- the cues this game declares",
            "capture_frame -- judge it as a picture",
        ],
        "note": (
            "None of this needs an upload. Terrain is voxels, motion is "
            "arithmetic on part offsets, and the grade is five instances under "
            "Lighting."
        ),
    },
    {
        "goal": "Make real geometry",
        "when": "the place is built from boxes and reads as boxes",
        "steps": [
            "mesh_vocabulary -- the operations, and which roles have a grammar",
            "mesh_brief -- what to model, at what size and budget",
            "mesh_build -- run it through Blender and get a package",
            "mesh_inspect and mesh_validate -- topology, and whether it passes",
            "mesh_previews and mesh_compare -- look at it, and at the last one",
            "fab_aperture -- or cut openings at runtime with real CSG",
            "fab_budget -- what solid modelling and particles have left",
        ],
        "note": (
            "`structure` covers the whole built world and the silhouette picks "
            "the piece: wall, floor, column, arch, roof. The router sends "
            "`structure` to worldkit, so pass backend blender for these."
        ),
    },
    {
        "goal": "Use something that already exists instead of building it",
        "when": "always, before generating an asset",
        "steps": [
            "asset_find -- Roblox own Creator Store, already in the right format",
            "federated_catalogue -- what Roblox server can do that this one cannot",
            "sourcing_decide -- buy, adopt or build this role",
            "sourcing_search -- what the catalogues have, with licences",
            "sourcing_adopt -- bring a pack in under a stated licence",
            "sourcing_inspect -- what came in",
            "sourcing_publish then sourcing_operation -- onto the account, through moderation",
            "asset_search and asset_plan -- what this game needs and what it has",
            "asset_prepare and asset_integrate -- get it into the place",
        ],
        "note": (
            "REUSE > ADAPT > GENERATE. Hero, objective, landmark, boss and brand "
            "roles are never bought -- they are what makes a game itself."
        ),
    },
    {
        "goal": "Charge for it",
        "when": "the game is worth money and needs a way to take it",
        "steps": [
            "monetize_check -- validate the catalogue before it touches money",
            "monetize_report -- is a receipt handler installed, and do receipts persist",
            "badge_check -- achievements, and whether anything can award them",
        ],
        "note": (
            "Nothing creates a pass, a product or a badge -- not Open Cloud, not "
            "Studio. They are made on the website and their ids arrive here. "
            "`ProcessReceipt` is the one function that can lose a player money."
        ),
    },
    {
        "goal": "Make it a service, not a demo",
        "when": "more than one person will play it",
        "steps": [
            "team_declare -- teams, whose colours must not collide",
            "chat_commands -- slash commands, and the filtering that is not optional",
            "text_declare -- every phrase, and which nobody has translated",
            "ship_settings -- streaming, which decides whether a big place runs",
            "cloud_datastore -- what persists between sessions",
            "policy_check -- paid random items, links and trading are gated by law",
            "reach_publish -- tell the other servers",
        ],
        "note": (
            "Player text shown to another player must be filtered -- pet names "
            "and signs included, not just the chat window. Games are taken down "
            "for this."
        ),
    },
    {
        "goal": "Change the place that is already open",
        "when": "Studio is running and you want to see the effect now",
        "steps": [
            "studio_status -- is anything connected, and in what context",
            "staging_catalogue -- what the live modules can do",
            "bridge_commands and bridge_status -- the raw surface",
            "bridge_call -- anything the SDK can do, directly",
            "studio_play and studio_stop -- get a real player, or stop",
            "capture_frame -- the loop is change, look, change",
        ],
        "note": (
            "Staging acts immediately and needs edit context. Stop Play Solo "
            "first; the error says so if you forget."
        ),
    },
    {
        "goal": "Find out whether it is any good",
        "when": "before saying it is done",
        "steps": [
            "capture_frame and capture_sequence -- pictures of the actual place",
            "corpus_look -- open built games and score what they actually look like",
            "visual_score and visual_thresholds -- what a person would say",
            "capture_compare -- did this build change the picture",
            "scenario_compile then scenario_run -- drive a real player through it",
            "scenario_step and scenario_replay -- one beat at a time, again",
            "quality_evaluate, quality_navigation, quality_performance -- the gates",
            "plan_compile -- what must be proven before any of it counts",
        ],
        "note": (
            "COMMAND_SUCCESS is not BEHAVIOR_SUCCESS is not E2E_SUCCESS. A tool "
            "returning ok means the tool ran."
        ),
    },
    {
        "goal": "Ship it",
        "when": "it is good and someone should be able to play it",
        "steps": [
            "release_blockers -- what stands in the way",
            "release_evaluate -- does it clear the gates",
            "release_promote -- an immutable, fail-closed release",
            "studio_build -- the place file",
            "place_versions then place_publish -- into a real experience",
            "cloud_publish -- assets, if any are outstanding",
        ],
        "note": (
            "Open Cloud cannot create an experience. The universe and place must "
            "exist first, made once in Studio or on create.roblox.com. "
            "`place_publish` saves a version; release true pushes it live."
        ),
    },
    {
        "goal": "Program the game yourself",
        "when": "always -- this is the path, the rest are shortcuts",
        "steps": [
            "sdk_surface -- the map of the library",
            "sdk_search -- find something by describing the job",
            "sdk_signature -- what it takes, before you call it",
            "sdk_skeleton -- a whole genre as starting code to rewrite",
            "pattern -- the shape everybody uses, to copy and change",
            "instance -- make and move things without writing Luau for it",
            "spatial -- ask the world where things are",
            "code_write -- your module, into the place, compiled first",
            "code_reload -- change it and see, in seconds, without a restart",
            "run -- raw Luau for anything the library does not cover",
            "compile -- does it parse, before spending a run",
            "test_run -- assert it inside the engine",
            "logs -- the print and warn of the running game",
            "watch -- what an attribute did while you were not looking",
            "dm_inspect -- everything about one instance, in one call",
        ],
        "note": (
            "Nothing in the library is required. Every function is Luau you "
            "could have written, `sdk_source` hands you the code to copy, and "
            "`run` reaches anything the tools do not."
        ),
    },
    {
        "goal": "Put things exactly where you want them",
        "when": "placing by coordinate is not how you think about it",
        "steps": [
            "place with action bounds -- where is it, how big",
            "place with action align -- against a face of something else",
            "place with action snap -- onto the grid the kit uses",
            "place with action settle -- drop it onto what is underneath",
            "place_query -- does it overlap, what is nearest",
        ],
        "note": (
            "Every action reads back where the thing ended up and what it now "
            "overlaps, so a placement can be checked without a screenshot."
        ),
    },
    {
        "goal": "Work on the engine itself",
        "when": "you are changing RQE rather than a game",
        "steps": [
            "sdk_run -- execute Luau against the SDK with no Studio at all",
            "luau_compile -- check Luau without running it",
            "system_compose -- wire the pieces up",
            "factory_create_project and factory_execute -- the whole pipeline",
            "factory_inspect and factory_campaign -- what it did, across many runs",
            "knowledge_record and knowledge_advise -- remember what verified",
            "knowledge_query -- one category of what it learned",
            "capabilities_explain and capabilities_select -- the surface, by phase",
            "cloud_capabilities, cloud_asset and cloud_inspect -- Open Cloud directly",
            "scene_align, scene_variant, scene_replace and scene_optimize -- scene surgery",
            "world_from_zones and world_optimize -- world surgery",
            "asset_capabilities, asset_generate_audio and asset_generate_animation",
            "material_create and material_validate -- new materials",
            "tokens_conformance -- does everything still read from the tokens",
            "content_from_model and recipe_check -- the rest",
        ],
        "note": (
            "A grab-bag on purpose: these are the tools you reach for when the "
            "problem is the factory rather than the game, and grouping them by "
            "task would be pretending they have one."
        ),
    },
]

#: The things that cost hours to learn and one line to say.
TRAPS: list[str] = [
    "`bridge.exec` and every staging tool need edit context. Play Solo refuses "
    "them -- stop the session, act, then play.",
    "Adding a new SDK module needs a place rebuild: Rojo packages roblox/lib at "
    "build time, so a fresh module is nil until then. Editing an existing one is "
    "live.",
    "Lua is not JSON. Interpolating json.dumps into a Script is a parse error: "
    "`then` and `require` are keywords and arrays open with `{`.",
    "The world is often built at runtime, so the place in edit context can be "
    "legitimately empty. Look after Play Solo starts, not before.",
    "Models are usually named by displayName, not by their class or role. "
    "Searching for the type name finds nothing and reads as an empty world.",
    "`dm.tree` truncates at 399 children. Use `dm.find` for counts, or you will "
    "conclude a finished world is half-built.",
]


def register_guide_tools(server: Any) -> Any:
    """Attach the orientation tool."""

    def rqe_guide(arguments: dict[str, Any]) -> dict[str, Any]:
        registry = server.tools
        by_family: dict[str, list[str]] = {}
        for name in sorted(registry):
            by_family.setdefault(name.split("_")[0], []).append(name)

        goal = str(arguments.get("goal") or "").strip().lower()
        family = str(arguments.get("family") or "").strip().lower()

        if family:
            names = by_family.get(family)
            if not names:
                return {
                    "error": f"no tool family named {family!r}",
                    "families": sorted(by_family),
                }
            return {
                "family": family,
                "does": FAMILIES.get(family, "(undescribed)"),
                "tools": {
                    name: registry[name].description for name in names
                },
            }

        routes = ROUTES
        if goal:
            matched = [
                route for route in ROUTES
                if goal in route["goal"].lower() or goal in route["when"].lower()
                or any(goal in step.lower() for step in route["steps"])
            ]
            routes = matched or ROUTES

        return {
            "what": (
                "RQE builds Roblox games. It is a toolbox an agent drives, not a "
                "factory that decides for you -- producer_run is the shortcut, "
                "and everything else is there so you can do it yourself."
            ),
            "totalTools": len(registry),
            "families": {
                name: {
                    "does": FAMILIES.get(name, "(undescribed)"),
                    "tools": len(names),
                }
                for name, names in sorted(by_family.items())
            },
            "routes": routes,
            "traps": TRAPS,
            "next": (
                "Call rqe_guide with a family name for that family's tools, or "
                "with a goal to narrow the routes."
            ),
        }

    server.register(Tool(
        name="rqe_guide",
        description=(
            "START HERE. What this platform is, which tool families exist and "
            "what each is for, the orders that actually work for common goals, "
            "and the traps that cost hours. Pass a family name to list its tools, "
            "or a goal to narrow the routes."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "family": {
                    "type": "string",
                    "description": "e.g. gameplay, sourcing, pursuit -- lists that family's tools",
                },
                "goal": {
                    "type": "string",
                    "description": "e.g. 'make a game', 'ship it', 'creature'",
                },
            },
        },
        handler=rqe_guide,
    ))

    return server
