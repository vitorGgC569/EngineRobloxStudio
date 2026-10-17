"""Screen templates, exposed to an agent.

    ui_catalogue  every screen template, every device, and the thresholds
    ui_screen     compose one screen across the device matrix and check it
    ui_screens_for_model  which screens a game's systems imply

`ui.tree` and `ui.snapshot` read a UI that exists. These decide what one should
be before it does -- and the checking is the point. A shop laid out at 1920 wide
ships and puts its buy button under the status bar at 390 wide, and the only way
anybody finds out is a screenshot somebody happened to take.

Nothing here builds Instances. The output is a layout to argue with; `Ui.lua`
constructs it afterwards.
"""

from __future__ import annotations

from typing import Any

from .ir_tools import GAME_MODEL_SCHEMA
from .server import EngineMcpServer, Tool, ToolError


def register_ui_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def _tokens(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..tokens import TokenError, load_token_set

        relative = arguments.get("tokens", "tokens/brickfarm.json")
        try:
            return load_token_set(root, relative).data
        except TokenError as exc:
            raise ToolError(f"{relative}: {exc}") from exc

    def ui_catalogue(_: dict[str, Any]) -> dict[str, Any]:
        from ..ui import catalogue

        return catalogue()

    server.register(Tool(
        name="ui_catalogue",
        description=(
            "Every screen template the engine ships, the devices each has to survive "
            "with their safe-area insets, and the touch-target and legibility floors. "
            "Read this before designing a screen by hand."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=ui_catalogue,
    ))

    def ui_screen(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..ui import ScreenError, compose_matrix

        try:
            return compose_matrix(
                str(arguments["screen"]),
                tokens=_tokens(arguments),
                devices=arguments.get("devices", ()),
            )
        except ScreenError as exc:
            raise ToolError(str(exc)) from exc

    server.register(Tool(
        name="ui_screen",
        description=(
            "Lay out a named screen across every device it has to survive -- desktop, "
            "tablet, phone in both orientations, console -- and report what breaks on "
            "each: content under a notch or in television overscan, buttons too small "
            "for a finger, text below legibility, elements squeezed to no area at all. "
            "Builds nothing; the layout is there to be argued with first."
        ),
        input_schema={
            "type": "object",
            "required": ["screen"],
            "additionalProperties": False,
            "properties": {
                "screen": {"type": "string", "minLength": 1},
                "devices": {"type": "array", "items": {"type": "string"}},
                "tokens": {"type": "string"},
            },
        },
        handler=ui_screen,
    ))

    def ui_screens_for_model(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..ir import GameModelError, load_model
        from ..ui import ScreenError, compose_matrix, screens_for

        try:
            model = load_model(arguments["model"])
        except GameModelError as exc:
            raise ToolError(str(exc)) from exc

        tokens = _tokens(arguments)
        needed = screens_for(model)
        reports: dict[str, Any] = {}
        failing: list[str] = []
        for name in needed:
            try:
                report = compose_matrix(name, tokens=tokens)
            except ScreenError as exc:
                raise ToolError(f"{name}: {exc}") from exc
            reports[name] = {
                "ok": report["ok"],
                "failingDevices": report["failingDevices"],
                "requiresSystems": report["requiresSystems"],
                "emptyMessage": report["emptyMessage"],
            }
            if not report["ok"]:
                failing.append(name)

        return {
            "schemaVersion": 1,
            "gameId": model.id,
            "ok": not failing,
            "screens": needed,
            "failing": failing,
            "reports": reports,
            "note": (
                "a screen for a system the game does not have is a button that opens an "
                "empty panel; a system with no screen is one nobody can reach"
            ),
        }

    server.register(Tool(
        name="ui_screens_for_model",
        description=(
            "Which screens a game's declared systems imply, laid out and checked across "
            "the device matrix. A shop screen in a game with no shop opens an empty "
            "panel; a shop with no screen is a system nobody can reach."
        ),
        input_schema={
            "type": "object",
            "required": ["model"],
            "additionalProperties": False,
            "properties": {
                "model": GAME_MODEL_SCHEMA,
                "tokens": {"type": "string"},
            },
        },
        handler=ui_screens_for_model,
    ))

    def ui_spec_check(arguments: dict[str, Any]) -> dict[str, Any]:
        """Fail-closed conformance for a declarative UiSpec.

        Mirrors forge/luau/Forge/UI/VisualSpec.lua so the same rules run at
        build time (Luau) and at plan time (here). Raw hex is forbidden --
        styling comes from tokens; unknown kinds and missing required props
        are named, never guessed.
        """

        spec = arguments["spec"]
        node_kinds: dict[str, list[str]] = {
            "frame": [],
            "button": ["text", "variant"],
            "label": ["text"],
            "image": ["assetToken"],
            "scroll": ["canvasSize"],
        }
        max_nodes = int(arguments.get("maxNodes", 512))
        problems: list[str] = []
        count = 0

        def walk(node: dict[str, Any], path: str) -> None:
            nonlocal count
            count += 1
            if count > max_nodes:
                problems.append(f"tree_exceeds_{max_nodes}_nodes")
                return
            kind = str(node.get("kind", ""))
            if kind not in node_kinds:
                problems.append(f"{path}:unknown_kind:{kind}")
                return
            props = node.get("props") or {}
            for required in node_kinds[kind]:
                if props.get(required) is None:
                    problems.append(f"{path}.{kind}:missing_prop:{required}")
            for prop_name, value in props.items():
                if isinstance(value, str) and value.startswith("#") and len(value) >= 3:
                    problems.append(f"{path}.{prop_name}:raw_hex_forbidden")
            for index, child in enumerate(node.get("children") or []):
                walk(child, f"{path}/{child.get('name') or kind + str(index)}")

        walk(spec, str(spec.get("name") or "root"))
        return {
            "ok": not problems,
            "problems": problems,
            "nodes": count,
            "source": "rqe-engine",
            "note": (
                "mirror of Forge/UI/VisualSpec.validate; the Luau side is authoritative "
                "at runtime, this runs the same rules before anything is built"
            ),
        }

    server.register(Tool(
        name="ui_spec_check",
        description=(
            "Validate a declarative UiSpec against the VisualKit contract before it is "
            "built: known node kinds only, required props present, raw hex colors "
            "forbidden (styling comes from design tokens), subtree size capped. The same "
            "rules run in Luau at mount time; failing here is cheap."
        ),
        input_schema={
            "type": "object",
            "required": ["spec"],
            "additionalProperties": False,
            "properties": {
                "spec": {"type": "object"},
                "maxNodes": {"type": "integer", "minimum": 1},
            },
        },
        handler=ui_spec_check,
    ))

    return server
