"""Terrain, motion and the look — the three that separate amateur from finished.

The tool surface could build a world, light it, give it rules and put creatures
in it, and a person looking at the result would still have said "someone's first
Roblox game". Three reasons, and none of them was a missing idea:

    terrain_*    the ground was a green box. Voxel terrain existed as one
                 function, `Fab.terrainBox`, and nothing used it.
    motion_*     there was no animation in the engine at all -- no Animator, no
                 Motor6D, no clips. Creatures slid.
    lighting_*   Atmosphere, Bloom, ColorCorrection, SunRays and DepthOfField
                 were all written in `Mood.lua` and no caller could touch one.

None of these needs an upload, an asset id or moderation, which is why they are
reachable at all: terrain is voxels, motion is arithmetic on part offsets, and
post-processing is five instances under Lighting.
"""

from __future__ import annotations

import json
from typing import Any

from .server import Tool
from .staging_tools import _PRELUDE, _exec


def _num(arguments: dict[str, Any], key: str, default: float) -> float:
    """A numeric argument, where zero means zero.

    `float(arguments.get("upper") or 90)` reads naturally and is wrong: zero is
    falsy in Python, so a caller asking for `upper: 0` -- a door that closes
    flush -- silently got 90 degrees. Lua would have done the right thing here,
    which is exactly why the bug survived reading.

    Measured: `interact_attach` with `upper: 0` reported `upper: 90`.
    """

    value = arguments.get(key)
    if value is None:
        return float(default)
    return float(value)


def _int(arguments: dict[str, Any], key: str, default: int) -> int:
    """The same, for counts and seeds. Seed 0 is a seed."""

    value = arguments.get(key)
    if value is None:
        return int(default)
    return int(value)


#: Terrain materials worth naming. Not the whole enum -- the whole enum includes
#: things like `Air` and `CrackedLava` that a caller reaching for "ground"
#: never wants, and a 30-item list is not a choice, it is a search.
GROUND_MATERIALS = [
    "Grass", "Ground", "Sand", "Rock", "Slate", "Snow", "Mud", "Basalt",
    "Sandstone", "LeafyGrass", "Asphalt", "Cobblestone", "Limestone", "Ice",
    "Salt", "Pavement", "Water",
]


def register_world_craft_tools(server: Any) -> Any:
    """Attach terrain, motion and post-processing tools."""

    # -- terrain -----------------------------------------------------------

    def terrain_sculpt(arguments: dict[str, Any]) -> dict[str, Any]:
        centre = list(arguments.get("centre") or [0, 0, 0])
        size = list(arguments.get("size") or [512, 512])
        material = str(arguments.get("material") or "Grass")
        if material not in GROUND_MATERIALS:
            return {"ok": False, "error": f"no ground material {material!r}",
                    "have": GROUND_MATERIALS}

        base = _num(arguments, "baseHeight", 0)
        amplitude = _num(arguments, "amplitude", 24)
        wavelength = _num(arguments, "wavelength", 90)
        octaves = _int(arguments, "octaves", 3)
        seed = _int(arguments, "seed", 1)
        water = arguments.get("waterLevel")

        # Flattened plots are what let terrain and architecture coexist. Without
        # them a heightfield puts a hill through the building the blockout
        # already placed.
        flatten = "{" + ",".join(
            "{centre=Vector3.new(%s,%s,%s),size=Vector2.new(%s,%s)}" % (
                z["centre"][0], z["centre"][1], z["centre"][2],
                z["size"][0], z["size"][1])
            for z in (arguments.get("flatten") or [])) + "}"

        water_lua = "nil" if water is None else str(float(water))

        return _exec(server, _PRELUDE + f"""
return WorldKit.Land.heightfield({{
    centre = Vector3.new({centre[0]}, {centre[1]}, {centre[2]}),
    size = Vector2.new({size[0]}, {size[1]}),
    baseHeight = {base}, amplitude = {amplitude},
    wavelength = {wavelength}, octaves = {octaves}, seed = {seed},
    material = Enum.Material.{material},
    waterLevel = {water_lua},
    flatten = {flatten},
}})
""", timeout=180.0)

    def terrain_fill(arguments: dict[str, Any]) -> dict[str, Any]:
        shape = str(arguments.get("shape") or "box")
        centre = list(arguments.get("centre") or [0, 0, 0])
        size = list(arguments.get("size") or [32, 32, 32])
        material = str(arguments.get("material") or "Rock")
        carve = bool(arguments.get("carve"))
        if not carve and material not in GROUND_MATERIALS:
            return {"ok": False, "error": f"no ground material {material!r}",
                    "have": GROUND_MATERIALS}
        call = (f'WorldKit.Land.carve("{shape}", bounds)' if carve else
                f'WorldKit.Land.fill("{shape}", bounds, Enum.Material.{material})')
        return _exec(server, _PRELUDE + f"""
local bounds = {{
    centre = Vector3.new({centre[0]}, {centre[1]}, {centre[2]}),
    size = Vector3.new({size[0]}, {size[1]}, {size[2]}),
}}
return {call}
""", timeout=120.0)

    def terrain_paint(arguments: dict[str, Any]) -> dict[str, Any]:
        centre = list(arguments.get("centre") or [0, 0, 0])
        size = list(arguments.get("size") or [256, 128, 256])
        source = str(arguments["from"])
        target = str(arguments["to"])
        for name in (source, target):
            if name not in GROUND_MATERIALS:
                return {"ok": False, "error": f"no ground material {name!r}",
                        "have": GROUND_MATERIALS}
        return _exec(server, _PRELUDE + f"""
return WorldKit.Land.paint({{
    centre = Vector3.new({centre[0]}, {centre[1]}, {centre[2]}),
    size = Vector3.new({size[0]}, {size[1]}, {size[2]}),
}}, Enum.Material.{source}, Enum.Material.{target})
""", timeout=120.0)

    def terrain_tint(arguments: dict[str, Any]) -> dict[str, Any]:
        material = str(arguments["material"])
        if material not in GROUND_MATERIALS:
            return {"ok": False, "error": f"no ground material {material!r}",
                    "have": GROUND_MATERIALS}
        colour = list(arguments.get("colour") or [120, 140, 100])
        return _exec(server, _PRELUDE + f"""
local ok = WorldKit.Land.tint(Enum.Material.{material},
    Color3.fromRGB({colour[0]}, {colour[1]}, {colour[2]}))
return {{ tinted = ok, material = "{material}" }}
""")

    def terrain_report(arguments: dict[str, Any]) -> dict[str, Any]:
        if arguments.get("clear"):
            return _exec(server, _PRELUDE + """
local cleared = WorldKit.Land.clear()
return { cleared = cleared, after = WorldKit.Land.report() }
""", timeout=120.0)
        reach = _num(arguments, "reach", 512)
        step = _num(arguments, "step", 32)
        return _exec(server, _PRELUDE + f"""
return WorldKit.Land.report({{ reach = {reach}, step = {step} }})
""", timeout=120.0)

    # -- motion ------------------------------------------------------------

    def motion_play(arguments: dict[str, Any]) -> dict[str, Any]:
        who = json.dumps(str(arguments["who"]))
        gait = str(arguments.get("gait") or "idle")
        rate = _num(arguments, "rate", 1.2)
        intensity = _num(arguments, "intensity", 1.0)
        lift = _num(arguments, "lift", 0.0)
        return _exec(server, _PRELUDE + f"""
local Motion = require(game:GetService("ReplicatedStorage"):WaitForChild("GameKit")).Motion
local wanted = {who}
local started, refused = 0, {{}}
for _, item in ipairs(workspace:GetDescendants()) do
    if item:IsA("Model") and item.Name == wanted then
        local performer, why = Motion.play(item, {{
            gait = "{gait}", rate = {rate},
            intensity = {intensity}, lift = {lift},
        }})
        if performer ~= nil then started += 1 else table.insert(refused, why) end
    end
end
if started == 0 and #refused == 0 then
    error("no Model named " .. wanted .. " in the workspace", 0)
end
return {{ started = started, refused = refused, report = Motion.report() }}
""")

    def motion_stop(arguments: dict[str, Any]) -> dict[str, Any]:
        who = arguments.get("who")
        if not who:
            return _exec(server, _PRELUDE + """
local Motion = require(game:GetService("ReplicatedStorage"):WaitForChild("GameKit")).Motion
Motion.stopAll()
return { stopped = "all", report = Motion.report() }
""")
        return _exec(server, _PRELUDE + f"""
local Motion = require(game:GetService("ReplicatedStorage"):WaitForChild("GameKit")).Motion
local stopped = 0
for _, item in ipairs(workspace:GetDescendants()) do
    if item:IsA("Model") and item.Name == {json.dumps(str(who))} then
        Motion.stop(item)
        stopped += 1
    end
end
return {{ stopped = stopped, report = Motion.report() }}
""")

    def motion_report(_arguments: dict[str, Any]) -> dict[str, Any]:
        return _exec(server, _PRELUDE + """
local Motion = require(game:GetService("ReplicatedStorage"):WaitForChild("GameKit")).Motion
return { gaits = Motion.gaits(), live = Motion.report() }
""")

    # -- the look ----------------------------------------------------------

    def lighting_grade(arguments: dict[str, Any]) -> dict[str, Any]:
        """Post-processing, which is most of what "looks expensive" means."""

        settings: list[str] = []

        def number(key: str, default: float | None = None) -> float | None:
            value = arguments.get(key, default)
            return None if value is None else float(value)

        haze = number("haze")
        if haze is not None:
            # Capped for the same reason the art direction caps it: haze past a
            # third of the frame stops reading as air and starts reading as a
            # rendering fault.
            settings.append(f'atmosphere.Density = {min(max(haze, 0.0), 0.35)}')
        glare = number("glare")
        if glare is not None:
            settings.append(f'atmosphere.Glare = {glare}')
        bloom = number("bloom")
        if bloom is not None:
            settings.append(f'bloom.Intensity = {bloom}')
        contrast = number("contrast")
        if contrast is not None:
            settings.append(f'correction.Contrast = {contrast}')
        saturation = number("saturation")
        if saturation is not None:
            settings.append(f'correction.Saturation = {saturation}')
        brightness = number("brightness")
        if brightness is not None:
            settings.append(f'correction.Brightness = {brightness}')
        tint = arguments.get("tint")
        if tint:
            settings.append(
                f'correction.TintColor = Color3.fromRGB({tint[0]},{tint[1]},{tint[2]})')
        rays = number("sunRays")
        if rays is not None:
            settings.append(f'rays.Intensity = {rays}')
        focus = number("focusDistance")
        if focus is not None:
            settings.append(f'dof.FocusDistance = {focus}')
            settings.append('dof.Enabled = true')
        blur = number("farBlur")
        if blur is not None:
            settings.append(f'dof.FarIntensity = {blur}')
            settings.append('dof.Enabled = true')

        if not settings:
            return {"ok": False,
                    "error": "nothing to set; pass at least one of "
                             "haze, glare, bloom, contrast, saturation, "
                             "brightness, tint, sunRays, focusDistance, farBlur"}

        body = "\n".join(f"pcall(function() {line} end)" for line in settings)
        return _exec(server, _PRELUDE + f"""
local Lighting = game:GetService("Lighting")

-- Reused, never stacked. Two ColorCorrections multiply and the second one is
-- invisible in the explorer until the frame is already wrong.
local function only(class, name)
    local found = Lighting:FindFirstChildOfClass(class)
    if found == nil then
        found = Instance.new(class)
        found.Name = name
        found.Parent = Lighting
    end
    return found
end

local atmosphere = only("Atmosphere", "Atmosphere")
local bloom = only("BloomEffect", "Bloom")
local correction = only("ColorCorrectionEffect", "Grade")
local rays = only("SunRaysEffect", "SunRays")
local dof = only("DepthOfFieldEffect", "DepthOfField")

{body}

return {{
    haze = atmosphere.Density, glare = atmosphere.Glare,
    bloom = bloom.Intensity,
    contrast = correction.Contrast, saturation = correction.Saturation,
    brightness = correction.Brightness,
    sunRays = rays.Intensity,
    depthOfField = dof.Enabled, focusDistance = dof.FocusDistance,
}}
""")

    # -- money -------------------------------------------------------------

    def monetize_check(arguments: dict[str, Any]) -> dict[str, Any]:
        """Validate a catalogue without wiring anything to real money."""

        passes = arguments.get("passes") or []
        products = arguments.get("products") or []
        if not passes and not products:
            return {"ok": False, "error": "declare at least one pass or product"}

        problems: list[str] = []
        seen: dict[int, str] = {}
        for kind, items in (("pass", passes), ("product", products)):
            for item in items:
                name = str(item.get("name") or "")
                raw = item.get("id")
                if not isinstance(raw, int) or isinstance(raw, bool) or raw <= 0:
                    problems.append(
                        f"{kind} {name!r} needs a positive integer id -- "
                        f"ids come from the website, nothing can create them")
                    continue
                if raw in seen:
                    problems.append(
                        f"id {raw} is used by both {seen[raw]} and {name}")
                seen[raw] = name
                if not name:
                    problems.append(f"{kind} {raw} has no name")
                # A product that grants nothing charges the player and delivers
                # nothing. There is no acceptable reading of that.
                if kind == "product" and not item.get("grants"):
                    problems.append(
                        f"product {name!r} says nothing about what it grants")

        return {
            "ok": not problems,
            "problems": problems,
            "passes": len(passes),
            "products": len(products),
            "note": (
                "shape only. Whether the ids exist on the account can be "
                "answered by Roblox, not by this tool"
            ),
        }

    def monetize_report(_arguments: dict[str, Any]) -> dict[str, Any]:
        return _exec(server, _PRELUDE + """
local Commerce = require(game:GetService("ReplicatedStorage")
    :WaitForChild("GameKit")).Commerce
return Commerce.report()
""")

    # -- acoustics and shipping --------------------------------------------

    def acoustics_spaces(_arguments: dict[str, Any]) -> dict[str, Any]:
        return _exec(server, _PRELUDE + """
return { spaces = WorldKit.Acoustics.spaces(), live = WorldKit.Acoustics.report() }
""")

    def acoustics_install(arguments: dict[str, Any]) -> dict[str, Any]:
        zones = arguments.get("zones") or []
        if not zones:
            return {"ok": False,
                    "error": "install at least one zone, or the whole place is "
                             "one space -- which is what it already was"}
        default = str(arguments.get("default") or "outdoors")
        lua = "{" + ",".join(
            '{name=%s,space=%s,centre=Vector3.new(%s,%s,%s),'
            'size=Vector3.new(%s,%s,%s),priority=%s}' % (
                json.dumps(str(z["name"])), json.dumps(str(z["space"])),
                z["centre"][0], z["centre"][1], z["centre"][2],
                z["size"][0], z["size"][1], z["size"][2],
                # Explicit, not `or 0`: the same falsy-zero trap, and the
                # guard in the tests is right to refuse the shape even where
                # the default happens to make it harmless.
                float(z["priority"] if z.get("priority") is not None else 0))
            for z in zones) + "}"
        return _exec(server, _PRELUDE + f"""
local ok, problems = WorldKit.Acoustics.install({lua}, {json.dumps(default)})
return {{ installed = ok, problems = problems, report = WorldKit.Acoustics.report() }}
""")

    def ship_settings(arguments: dict[str, Any]) -> dict[str, Any]:
        """Streaming, discovered rather than assumed.

        The first version hardcoded `StreamingTargetRadius` and
        `StreamingMinRadius` and the place answered `not a valid member of
        Workspace` -- they have been removed from current Roblox, and the
        replacements did not resolve either. Worse, the writes were wrapped in
        pcall and the *reads* were not, so a tool that should have degraded
        gracefully raised instead.

        So nothing is assumed. Every property is probed before it is touched,
        and the result says which ones this engine version actually has.
        """

        wanted: dict[str, Any] = {}
        if arguments.get("streaming") is not None:
            # The one property that decides whether a large place is playable:
            # off, the client loads the entire world before the player can move.
            wanted["StreamingEnabled"] = bool(arguments["streaming"])
        for key, prop in (("streamRadius", "StreamingTargetRadius"),
                          ("streamMinRadius", "StreamingMinRadius")):
            if arguments.get(key) is not None:
                wanted[prop] = int(arguments[key])

        assignments = ",".join(
            f'{{name="{name}",value={json.dumps(value) if not isinstance(value, bool) else str(value).lower()}}}'
            for name, value in wanted.items())

        return _exec(server, _PRELUDE + f"""
local candidates = {{
    "StreamingEnabled", "StreamingMinRadius", "StreamingTargetRadius",
    "StreamingIntegrityMode", "StreamOutBehavior", "ClientAnimatorThrottling",
}}

local available, current = {{}}, {{}}
for _, name in ipairs(candidates) do
    local ok, value = pcall(function() return (workspace :: any)[name] end)
    if ok then
        table.insert(available, name)
        current[name] = tostring(value)
    end
end

local applied, unavailable = {{}}, {{}}
for _, entry in ipairs({{{assignments}}}) do
    local ok = pcall(function() (workspace :: any)[entry.name] = entry.value end)
    if ok then
        applied[entry.name] = tostring((workspace :: any)[entry.name])
    else
        table.insert(unavailable, entry.name)
    end
end

for _, name in ipairs(available) do
    current[name] = tostring((workspace :: any)[name])
end

return {{
    available = available,
    settings = current,
    applied = applied,
    unavailable = unavailable,
    instances = #workspace:GetDescendants(),
}}
""", timeout=90.0)

    # -- looking at what was built -----------------------------------------

    def corpus_look(arguments: dict[str, Any]) -> dict[str, Any]:
        """Open built games, photograph them, and score the pictures.

        The corpus evaluates stages, and a stage is a claim about a pipeline
        rather than about a game. Twenty green builds proved the factory did not
        error; nobody had looked at one.
        """

        from ..corpus_visual import sweep

        wanted = arguments.get("games")
        if wanted:
            games = [(str(name), "") for name in wanted]
        else:
            folder = server.root / "games"
            games = sorted(
                (path.name, "")
                for path in folder.iterdir()
                if path.is_dir() and any(path.glob("*.rbx*"))
            )
        if not games:
            return {"ok": False,
                    "error": "no built games; nothing in games/ has a place file"}

        return {"ok": True, "result": sweep(
            server.root, games,
            sample=_int(arguments, "sample", 4),
            seed=_int(arguments, "seed", 1),
            run=arguments.get("run", True) is not False)}

    # -- registration ------------------------------------------------------

    server.register(Tool(
        name="acoustics_spaces",
        description=(
            "The named acoustic spaces -- cave, cathedral, hall, forest and the "
            "rest -- and what is currently installed. Named architecturally "
            "rather than technically: a caller knows they are writing a cave, "
            "not that they want a 0.55 wet mix."
        ),
        input_schema={"type": "object", "properties": {}},
        handler=acoustics_spaces,
    ))

    server.register(Tool(
        name="acoustics_install",
        description=(
            "Give rooms their own sound. Walking into a cave and hearing the "
            "tail lengthen tells a player they are inside before they have "
            "looked at anything. Zone changes are held for several samples "
            "before they are believed -- without that, a player standing in a "
            "doorway makes the reverb stutter, which is worse than no zones."
        ),
        input_schema={
            "type": "object",
            "required": ["zones"],
            "properties": {
                "default": {"type": "string",
                            "description": "the space outside every zone"},
                "zones": {
                    "type": "array",
                    "minItems": 1,
                    "items": {
                        "type": "object",
                        "required": ["name", "space", "centre", "size"],
                        "properties": {
                            "name": {"type": "string"},
                            "space": {"type": "string"},
                            "centre": {"type": "array", "items": {"type": "number"},
                                       "minItems": 3, "maxItems": 3},
                            "size": {"type": "array", "items": {"type": "number"},
                                     "minItems": 3, "maxItems": 3},
                            "priority": {"type": "number",
                                         "description": "higher wins where zones overlap"},
                        },
                    },
                },
            },
        },
        handler=acoustics_install,
    ))

    server.register(Tool(
        name="ship_settings",
        description=(
            "Streaming: whether a client loads the whole world before the "
            "player can move, or only what is near them. The single most "
            "consequential property in a large place, and it stops being "
            "optional the moment there is real terrain. Call with no arguments "
            "to read the current settings."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "streaming": {"type": "boolean"},
                "streamRadius": {"type": "integer", "minimum": 64},
                "streamMinRadius": {"type": "integer", "minimum": 0},
            },
        },
        handler=ship_settings,
    ))

    server.register(Tool(
        name="corpus_look",
        description=(
            "Open built games in Studio, photograph them and score the picture. "
            "The corpus only ever checked that the pipeline did not error -- "
            "which is why twenty green builds could sit beside a screenshot of "
            "a green box. It starts Play Solo before the shutter, because these "
            "games assemble their worlds at runtime and an editor frame is empty "
            "sky. Slow: each game costs a restart and a play session, so it "
            "samples deterministically by default. sample:0 opens all of them."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "games": {"type": "array", "items": {"type": "string"},
                          "description": "specific game ids; omit for everything built"},
                "sample": {"type": "integer", "minimum": 0,
                           "description": "how many to open; 0 means all"},
                "seed": {"type": "integer",
                         "description": "same seed opens the same games, so runs compare"},
                "run": {"type": "boolean",
                        "description": "start Play Solo before capturing (default true). "
                                       "False photographs the editor, which for a "
                                       "runtime-assembled world is a photograph of nothing"},
            },
        },
        handler=corpus_look,
    ))

    server.register(Tool(
        name="monetize_check",
        description=(
            "Validate a game pass and developer product catalogue before any of "
            "it touches real money. Nothing -- not Open Cloud, not Studio -- can "
            "create a pass or a product; their ids are made on the website and "
            "arrive here. What this checks is that no id is duplicated and that "
            "no product charges a player without granting anything."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "passes": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["id", "name"],
                        "properties": {
                            "id": {"type": "integer", "minimum": 1},
                            "name": {"type": "string"},
                            "grants": {"type": "string"},
                        },
                    },
                },
                "products": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["id", "name", "grants"],
                        "properties": {
                            "id": {"type": "integer", "minimum": 1},
                            "name": {"type": "string"},
                            "grants": {"type": "string",
                                       "description": "what one purchase delivers"},
                        },
                    },
                },
            },
        },
        handler=monetize_check,
    ))

    server.register(Tool(
        name="monetize_report",
        description=(
            "Whether the running game has a receipt handler, whether receipts "
            "survive a server restart, and what the purchase path has done. "
            "`ProcessReceipt` is the one function in a Roblox game that can lose "
            "a player's money, and this is how you look at it without spending "
            "any."
        ),
        input_schema={"type": "object", "properties": {}},
        handler=monetize_report,
    ))

    server.register(Tool(
        name="terrain_sculpt",
        description=(
            "Sculpt a heightfield: rolling ground with real slopes, optional "
            "water, and flattened plots so architecture still fits. Same seed, "
            "same landscape. This is the tool that stops a place standing on a "
            "green box."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "centre": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "size": {"type": "array", "items": {"type": "number"},
                         "minItems": 2, "maxItems": 2,
                         "description": "footprint on X and Z, in studs"},
                "baseHeight": {"type": "number"},
                "amplitude": {"type": "number",
                              "description": "peak-to-trough displacement"},
                "wavelength": {"type": "number",
                               "description": "studs per period; larger is smoother"},
                "octaves": {"type": "integer", "minimum": 1, "maximum": 6},
                "seed": {"type": "integer"},
                "material": {"type": "string", "enum": GROUND_MATERIALS},
                "waterLevel": {"type": "number",
                               "description": "fill below this height with water"},
                "flatten": {
                    "type": "array",
                    "description": "footprints held level, so builds still fit",
                    "items": {
                        "type": "object",
                        "required": ["centre", "size"],
                        "properties": {
                            "centre": {"type": "array", "items": {"type": "number"},
                                       "minItems": 3, "maxItems": 3},
                            "size": {"type": "array", "items": {"type": "number"},
                                     "minItems": 2, "maxItems": 2},
                        },
                    },
                },
            },
        },
        handler=terrain_sculpt,
    ))

    server.register(Tool(
        name="terrain_fill",
        description=(
            "Fill or carve a box, ball, cylinder or wedge of terrain. Carving "
            "is how caves, trenches and quarries are made -- it is filling with "
            "Air, which the raw API does not make obvious."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "shape": {"type": "string",
                          "enum": ["box", "ball", "cylinder", "wedge"]},
                "centre": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "size": {"type": "array", "items": {"type": "number"},
                         "minItems": 3, "maxItems": 3},
                "material": {"type": "string", "enum": GROUND_MATERIALS},
                "carve": {"type": "boolean",
                          "description": "remove terrain instead of adding it"},
            },
        },
        handler=terrain_fill,
    ))

    server.register(Tool(
        name="terrain_paint",
        description=(
            "Repaint one terrain material as another inside a region, leaving "
            "the shape alone. The cheapest way to make ground read as two "
            "places: same hills, grass one side of the ridge and sand the other."
        ),
        input_schema={
            "type": "object",
            "required": ["from", "to"],
            "properties": {
                "from": {"type": "string", "enum": GROUND_MATERIALS},
                "to": {"type": "string", "enum": GROUND_MATERIALS},
                "centre": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "size": {"type": "array", "items": {"type": "number"},
                         "minItems": 3, "maxItems": 3},
            },
        },
        handler=terrain_paint,
    ))

    server.register(Tool(
        name="terrain_tint",
        description=(
            "Recolour a terrain material for the whole place, so the ground "
            "agrees with the token palette instead of shipping Roblox's default "
            "green."
        ),
        input_schema={
            "type": "object",
            "required": ["material"],
            "properties": {
                "material": {"type": "string", "enum": GROUND_MATERIALS},
                "colour": {"type": "array", "items": {"type": "integer"},
                           "minItems": 3, "maxItems": 3},
            },
        },
        handler=terrain_tint,
    ))

    server.register(Tool(
        name="terrain_report",
        description=(
            "What is actually on the ground: the real footprint, height range "
            "and material census, sampled by raycast. Roblox has no query for "
            "this -- `MaxExtents` is the volume terrain is *allowed* to fill, a "
            "constant, and framing a camera on it photographs a speck. Pass "
            "clear:true to wipe first."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "clear": {"type": "boolean"},
                "reach": {"type": "number", "description": "half-width to sample, studs"},
                "step": {"type": "number", "description": "sample spacing, studs"},
            },
        },
        handler=terrain_report,
    ))

    server.register(Tool(
        name="motion_play",
        description=(
            "Animate every Model with this name: idle, walk, menace, hover or "
            "stagger. Procedural, so it needs no uploaded animation and no rig "
            "-- it works on the loose-part models this engine actually builds. "
            "A creature that slides is the loudest amateur tell a Roblox game "
            "has."
        ),
        input_schema={
            "type": "object",
            "required": ["who"],
            "properties": {
                "who": {"type": "string", "description": "Model name"},
                "gait": {"type": "string",
                         "enum": ["idle", "walk", "menace", "hover", "stagger"]},
                "rate": {"type": "number", "exclusiveMinimum": 0,
                         "description": "cycles per second; a walk reads right near 1.6"},
                "intensity": {"type": "number", "minimum": 0,
                              "description": "1 is calibrated, 2 is comic"},
                "lift": {"type": "number", "description": "hover: studs above rest"},
            },
        },
        handler=motion_play,
    ))

    server.register(Tool(
        name="motion_stop",
        description=(
            "Stop one named Model animating, or all of them. Parts go back "
            "exactly where they were placed."
        ),
        input_schema={
            "type": "object",
            "properties": {"who": {"type": "string"}},
        },
        handler=motion_stop,
    ))

    server.register(Tool(
        name="motion_report",
        description="The gaits available and what is currently animating.",
        input_schema={"type": "object", "properties": {}},
        handler=motion_report,
    ))

    server.register(Tool(
        name="lighting_grade",
        description=(
            "Post-processing: haze, glare, bloom, contrast, saturation, tint, "
            "sun rays and depth of field. All five effects existed inside "
            "Mood.lua and no caller could reach one. This is most of what "
            "'looks expensive' actually means, and none of it needs an upload."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "haze": {"type": "number", "minimum": 0, "maximum": 1,
                         "description": "atmosphere density; capped at 0.35"},
                "glare": {"type": "number", "minimum": 0},
                "bloom": {"type": "number", "minimum": 0},
                "contrast": {"type": "number", "minimum": -1, "maximum": 1},
                "saturation": {"type": "number", "minimum": -1, "maximum": 1},
                "brightness": {"type": "number", "minimum": -1, "maximum": 1},
                "tint": {"type": "array", "items": {"type": "integer"},
                         "minItems": 3, "maxItems": 3},
                "sunRays": {"type": "number", "minimum": 0, "maximum": 1},
                "focusDistance": {"type": "number", "minimum": 0},
                "farBlur": {"type": "number", "minimum": 0, "maximum": 1},
            },
        },
        handler=lighting_grade,
    ))

    return server
