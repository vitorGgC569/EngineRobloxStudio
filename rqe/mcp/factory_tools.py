"""Studio lifecycle, capture, scenarios and the factory, exposed over MCP.

Everything here already worked. None of it was *offered* -- it lived in Python
and a CLI, so an agent driving the engine had to shell out to reach the layer
that is supposed to be driving it. That is the difference between a library and
a platform, and closing it is plumbing rather than invention.

One family genuinely does not belong behind the bridge. Studio lifecycle --
open, close, restart, build, sync -- is what an agent needs *before* a bridge
exists, so it sits here, above the plugin, rather than as a command the plugin
would have to be running to answer.

Every lifecycle tool that can destroy work says so in its description and
reports what it did. Killing Studio discards unsaved changes, and a tool that
does that quietly is a tool nobody should run.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from .server import EngineMcpServer, Tool, ToolError


def _inside(root: Path, relative: str, label: str) -> Path:
    path = (root / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as exc:
        raise ToolError(f"{label} must stay inside the project root") from exc
    return path


def _summarise_plan(payload: dict[str, Any]) -> dict[str, Any]:
    """Fold a compiled plan into what a caller actually needs to see.

    Tasks live under each project rather than at the top level, and they carry a
    `stage` rather than a `phase`. Reading either wrongly returns a plan with
    zero tasks in it -- which looks like a blueprint that compiled to nothing
    rather than a reader looking in the wrong place.
    """

    from collections import Counter

    projects = payload.get("projects") or []
    products: list[dict[str, Any]] = []
    total = 0
    for project in projects:
        if not isinstance(project, dict):
            continue
        tasks = [item for item in (project.get("tasks") or []) if isinstance(item, dict)]
        total += len(tasks)
        products.append({
            "productId": project.get("productId"),
            "projectId": project.get("projectId"),
            "tasks": len(tasks),
            "stages": dict(Counter(str(item.get("stage", "?")) for item in tasks)),
            "roles": sorted({str(item.get("role")) for item in tasks if item.get("role")}),
        })

    return {
        "planId": payload.get("planId"),
        "blueprintId": payload.get("blueprintId"),
        "planSha256": payload.get("planSha256"),
        "validationLevel": payload.get("validationLevel"),
        "products": products,
        "productCount": len(products),
        "tasks": total,
    }


def register_factory_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    # ------------------------------------------------------- studio lifecycle

    def studio_status(_: dict[str, Any]) -> dict[str, Any]:
        from ..hub import lifecycle

        try:
            executable = str(lifecycle.studio_executable())
        except Exception:  # noqa: BLE001 - "not installed" is an answer, not a crash
            executable = ""
        windows: list[dict[str, Any]] = []
        try:
            windows = [
                {"hwnd": hwnd, "title": title} for hwnd, title in lifecycle.studio_windows()
            ]
        except Exception:  # noqa: BLE001 - non-Windows, or nothing open
            pass
        return {
            "running": lifecycle.studio_running(),
            "windows": windows,
            "windowCount": len(windows),
            "executable": executable,
        }

    server.register(Tool(
        name="studio_status",
        description=(
            "Which Roblox Studio processes are running, with their PIDs. The one family "
            "an agent needs before a bridge exists, so it lives above the plugin."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=studio_status,
    ))

    def studio_stop(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..hub import lifecycle

        if arguments.get("confirmDiscardUnsavedWork") is not True:
            # Refused rather than warned. Killing Studio discards unsaved edits,
            # and a tool that does that on a default argument is a tool that
            # will eventually do it by accident.
            raise ToolError(
                "stopping Studio discards unsaved work; pass "
                "confirmDiscardUnsavedWork=true to proceed"
            )
        return {"stopped": True, "detail": lifecycle.stop_studio()}

    server.register(Tool(
        name="studio_stop",
        description=(
            "Terminate every running Studio. DESTRUCTIVE: unsaved work is lost, so it "
            "requires explicit confirmation."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {"confirmDiscardUnsavedWork": {"type": "boolean"}},
        },
        handler=studio_stop,
    ))

    def studio_build(arguments: dict[str, Any]) -> dict[str, Any]:
        import subprocess

        project = arguments.get("project", "roblox/mvp/default.project.json")
        output = arguments.get("output", ".tmp/build.rbxlx")
        project_path = _inside(root, project, "project")
        output_path = _inside(root, output, "output")
        output_path.parent.mkdir(parents=True, exist_ok=True)

        process = subprocess.run(
            ["rojo", "build", str(project_path), "-o", str(output_path)],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            cwd=str(root), timeout=float(arguments.get("timeoutSeconds", 120)),
        )
        if process.returncode != 0:
            raise ToolError(f"rojo build failed: {process.stderr.strip() or process.stdout.strip()}")

        # Rojo packages sources without parsing them, so a clean build proves
        # nothing about whether the Luau in it runs.
        from ..luau_check import ToolchainUnavailable, check_all

        try:
            failures = check_all(root, allow_download=False)
        except ToolchainUnavailable:
            failures = []
            compiled = None
        else:
            compiled = not failures

        return {
            "project": str(project_path.relative_to(root)),
            "output": str(output_path.relative_to(root)),
            "bytes": output_path.stat().st_size if output_path.is_file() else 0,
            "luauCompiles": compiled,
            "luauFailures": [str(item) for item in failures],
        }

    server.register(Tool(
        name="studio_build",
        description=(
            "Build the place from source with Rojo, then compile every Luau file. Rojo "
            "packages sources without parsing them, so the second half is not optional."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "project": {"type": "string"},
                "output": {"type": "string"},
                "timeoutSeconds": {"type": "number", "exclusiveMinimum": 0, "maximum": 600},
            },
        },
        handler=studio_build,
    ))

    # ---------------------------------------------------------------- capture

    def capture_frame(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..capture import capture_viewpoint
        from ..hub.client import StudioBridge

        output_dir = _inside(root, arguments.get("outputDir", ".tmp/captures"), "outputDir")
        output_dir.mkdir(parents=True, exist_ok=True)
        bridge = StudioBridge(
            arguments.get("hub") or os.environ.get("RQE_HUB_URL", "http://127.0.0.1:8790"),
            token=os.environ.get("RQE_BRIDGE_TOKEN"),
        )
        # Pinned to the session running the game. Without it the camera command
        # can land on the edit session while the screenshot grabs the play
        # window -- two DataModels in one receipt, which is exactly the frame
        # that looks like evidence and is not.
        # Two kinds of evidence, and conflating them was costing more than it
        # protected. A frame of the editor is not evidence about *gameplay* --
        # nothing is running, no player exists, no system has ticked. It is
        # perfectly good evidence about the *world*: the geometry is the geometry
        # the place ships, the lighting is the lighting the mood applied, and
        # those are exactly what a scene critique measures.
        #
        # Refusing both blocked every iteration on world composition behind a
        # play session, which on this machine needs a foreground grab Windows
        # refuses to a background process. So the edit frame is allowed when
        # asked for, and labelled `worldOnly` so nothing downstream can mistake
        # it for a gameplay capture.
        world_only = bool(arguments.get("worldOnly", False))
        pinned = None
        try:
            pinned = bridge.pin_to_running()
        except Exception as exc:  # noqa: BLE001
            if world_only:
                # Still pinned, just not to a running session: two calls landing
                # on different Studio windows would photograph one place and
                # frame another.
                pinned = bridge.pin_to_any()
            else:
                raise ToolError(
                    f"no running session to capture: {exc}. Start the game before "
                    "capturing, or pass worldOnly to photograph the built world in "
                    "the editor -- which is evidence about geometry and lighting, "
                    "and not about gameplay."
                ) from exc

        try:
            # `viewpoint` is the label on the receipt; `target` is what the
            # camera frames. Passing the label as the framing target -- which
            # this did -- produces a TypeError on the first real call, and both
            # capture tools carried it because neither had ever been run against
            # a live Studio.
            shot = capture_viewpoint(
                bridge,
                world_only=world_only,
                # No default. "Workspace" as a fallback silently reframed every
                # capture that meant to photograph a pose the caller had set.
                target=arguments.get("target", ""),
                output=output_dir / f"{arguments['viewpoint']}.png",
                viewpoint=arguments["viewpoint"],
                expected_place=arguments.get("expectedPlace", ""),
                # Named explicitly: the integrity check treats an empty expected
                # session as "unverifiable" and refuses, which is the right
                # default and the reason this must be passed rather than assumed.
                expected_session=pinned,
            )
        except Exception as exc:  # noqa: BLE001 - every failure is a named refusal
            raise ToolError(f"capture failed: {type(exc).__name__}: {exc}") from exc

        payload = shot.to_dict() if hasattr(shot, "to_dict") else {"shot": str(shot)}
        # Stamped on the receipt, not just in the request. A frame that ends up
        # in a report has to carry what it is evidence of.
        payload["worldOnly"] = world_only
        if world_only:
            payload["evidenceScope"] = (
                "geometry and lighting of the built world; nothing was running, so this says nothing about gameplay, UI or systems")
        if not payload.get("trustworthy", False):
            # A screenshot of the wrong window is worse than no screenshot,
            # because it looks like evidence.
            payload["warning"] = (
                "this frame is not trustworthy and must not be used as visual evidence"
            )
        return payload

    server.register(Tool(
        name="capture_frame",
        description=(
            "Capture one Studio frame with the full integrity chain: window, PID, "
            "session, place, build, camera pose and occlusion. An untrustworthy frame is "
            "labelled rather than returned as evidence."
        ),
        input_schema={
            "type": "object",
            "required": ["viewpoint"],
            "additionalProperties": False,
            "properties": {
                "viewpoint": {"type": "string", "minLength": 1},
                "target": {"type": "string", "description": "instance path to frame"},
                "expectedPlace": {"type": "string"},
                "outputDir": {"type": "string"},
                "worldOnly": {
                    "type": "boolean",
                    "description": "photograph the built world in the editor; labelled as evidence about geometry and lighting, not gameplay",
                },
                "hub": {"type": "string"},
            },
        },
        handler=capture_frame,
    ))

    def capture_compare(arguments: dict[str, Any]) -> dict[str, Any]:
        """Pixel comparison between two captures of the same viewpoint.

        The missing piece for visual regression: without a diff, two screenshots
        of the same viewpoint across two builds cannot be told apart.
        """

        from ..visual_compare import compare_images

        before = _inside(root, arguments["before"], "before")
        after = _inside(root, arguments["after"], "after")
        for path in (before, after):
            if not path.is_file():
                raise ToolError(f"image not found: {path}")
        return compare_images(before, after, threshold=float(arguments.get("threshold", 0.02)))

    server.register(Tool(
        name="capture_compare",
        description=(
            "Compare two captures of the same viewpoint and report what fraction of "
            "pixels changed, where, and whether the change is above the threshold."
        ),
        input_schema={
            "type": "object",
            "required": ["before", "after"],
            "additionalProperties": False,
            "properties": {
                "before": {"type": "string", "minLength": 1},
                "after": {"type": "string", "minLength": 1},
                "threshold": {"type": "number", "minimum": 0, "maximum": 1},
            },
        },
        handler=capture_compare,
    ))

    def scenario_compare(arguments: dict[str, Any]) -> dict[str, Any]:
        """Which step changed verdict between two runs.

        The difference between "something broke" and "step 4 stopped finding the
        prompt". Refuses outright when the scenario was edited between runs,
        because comparing across an edit produces a regression report about a
        step that no longer exists.
        """

        from ..scenario_compare import ScenarioCompareError, compare_files

        before = _inside(root, arguments["before"], "before")
        after = _inside(root, arguments["after"], "after")
        try:
            return compare_files(before, after)
        except ScenarioCompareError as exc:
            raise ToolError(str(exc)) from exc

    server.register(Tool(
        name="scenario_compare",
        description=(
            "Compare two stored scenario results and report which steps regressed and "
            "which were fixed. Incomparable when the scenario was edited between runs."
        ),
        input_schema={
            "type": "object",
            "required": ["before", "after"],
            "additionalProperties": False,
            "properties": {
                "before": {"type": "string", "minLength": 1},
                "after": {"type": "string", "minLength": 1},
            },
        },
        handler=scenario_compare,
    ))

    def capture_sequence(arguments: dict[str, Any]) -> dict[str, Any]:
        """Capture several viewpoints in one pass.

        A device matrix or a before/after sweep is a set, not a frame, and
        taking them one call at a time lets the world change between shots --
        which makes the set incomparable without anyone noticing.
        """

        from ..capture import capture_viewpoint
        from ..hub.client import StudioBridge

        viewpoints = arguments["viewpoints"]
        output_dir = _inside(root, arguments.get("outputDir", ".tmp/captures"), "outputDir")
        output_dir.mkdir(parents=True, exist_ok=True)
        bridge = StudioBridge(
            arguments.get("hub") or os.environ.get("RQE_HUB_URL", "http://127.0.0.1:8790"),
            token=os.environ.get("RQE_BRIDGE_TOKEN"),
        )

        shots: list[dict[str, Any]] = []
        failures: list[dict[str, Any]] = []
        for viewpoint in viewpoints:
            try:
                shot = capture_viewpoint(
                    bridge,
                    target=arguments.get("target", "Workspace"),
                    output=output_dir / f"{viewpoint}.png",
                    viewpoint=viewpoint,
                    expected_place=arguments.get("expectedPlace", ""),
                )
            except Exception as exc:  # noqa: BLE001
                failures.append({"viewpoint": viewpoint, "error": f"{type(exc).__name__}: {exc}"})
                continue
            shots.append(shot.to_dict() if hasattr(shot, "to_dict") else {"viewpoint": viewpoint})

        untrustworthy = [item for item in shots if not item.get("trustworthy", False)]
        return {
            "requested": list(viewpoints),
            "captured": len(shots),
            "failures": failures,
            "untrustworthy": len(untrustworthy),
            # A partial set cannot support a comparison: the missing viewpoint is
            # exactly the one nobody looked at.
            "complete": not failures and not untrustworthy,
            "shots": shots,
        }

    server.register(Tool(
        name="capture_sequence",
        description=(
            "Capture several named viewpoints in one pass, so a device matrix or a "
            "before/after sweep is taken from one world state. Reports the set as "
            "incomplete if any frame failed or is untrustworthy."
        ),
        input_schema={
            "type": "object",
            "required": ["viewpoints"],
            "additionalProperties": False,
            "properties": {
                "viewpoints": {
                    "type": "array", "minItems": 1,
                    "items": {"type": "string", "minLength": 1},
                },
                "outputDir": {"type": "string"},
                "hub": {"type": "string"},
            },
        },
        handler=capture_sequence,
    ))

    # --------------------------------------------------------------- scenario

    def scenario_compile(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..scenario import load_scenario, scenario_document_issues

        path = _inside(root, arguments["scenario"], "scenario")
        if not path.is_file():
            raise ToolError(f"scenario not found: {path}")
        try:
            document = load_scenario(path)
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        issues = scenario_document_issues(document)
        steps = document.get("steps", []) if isinstance(document, dict) else []
        return {
            "scenario": str(path.relative_to(root)),
            "name": document.get("name", path.stem) if isinstance(document, dict) else path.stem,
            "steps": len(steps),
            "actions": sorted({str(step.get("step", "?")) for step in steps if isinstance(step, dict)}),
            "issues": [str(item) for item in issues],
            "valid": not issues,
        }

    server.register(Tool(
        name="scenario_compile",
        description=(
            "Validate a scenario file and report its shape without running it. Catches a "
            "malformed step before a live session is spent on it."
        ),
        input_schema={
            "type": "object",
            "required": ["scenario"],
            "additionalProperties": False,
            "properties": {"scenario": {"type": "string", "minLength": 1}},
        },
        handler=scenario_compile,
    ))

    def scenario_run(arguments: dict[str, Any]) -> dict[str, Any]:
        """Play a scenario against a live game and return every step's verdict.

        The one tool here that needs a running place, and the only one that can
        prove a loop works rather than that its pieces exist.
        """

        from ..hub.client import StudioBridge
        from ..scenario import ScenarioRunner, load_scenario

        scenario_path = _inside(root, arguments["scenario"], "scenario")
        if not scenario_path.is_file():
            raise ToolError(f"scenario not found: {scenario_path}")
        document = load_scenario(scenario_path)

        bridge = StudioBridge(
            arguments.get("hub") or os.environ.get("RQE_HUB_URL", "http://127.0.0.1:8790"),
            token=os.environ.get("RQE_BRIDGE_TOKEN"),
        )
        if arguments.get("pinToRunning", True):
            try:
                bridge.pin_to_running()
            except Exception as exc:  # noqa: BLE001
                raise ToolError(
                    f"a scenario needs a running place and none was reachable: {exc}"
                ) from exc

        try:
            result = ScenarioRunner(bridge).run(document)
        except Exception as exc:  # noqa: BLE001 - a refusal, never a crash
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        payload = result.to_dict() if hasattr(result, "to_dict") else {}
        steps = payload.get("steps") or []
        failed = [item for item in steps if item.get("status") != "PASS"]
        return {
            "scenario": str(scenario_path.relative_to(root)),
            "status": payload.get("status"),
            "steps": len(steps),
            "failed": len(failed),
            # Named individually: "three steps failed" sends nobody anywhere,
            # "step 4, interact, prompt was disabled" sends them to the defect.
            "failures": [
                {
                    "index": item.get("index"),
                    "kind": item.get("kind"),
                    "reason": item.get("reason"),
                }
                for item in failed
            ],
            "result": payload,
        }

    server.register(Tool(
        name="scenario_run",
        description=(
            "Play a scenario against a running place and report each step's verdict. "
            "Requires a live session; refuses rather than pretending when none is "
            "reachable."
        ),
        input_schema={
            "type": "object",
            "required": ["scenario"],
            "additionalProperties": False,
            "properties": {
                "scenario": {"type": "string", "minLength": 1},
                "hub": {"type": "string"},
                "pinToRunning": {"type": "boolean"},
            },
        },
        handler=scenario_run,
    ))

    def scenario_step(arguments: dict[str, Any]) -> dict[str, Any]:
        """Execute a single step against a running place.

        Separate from `scenario_run` because a repair loop does not want the
        whole sequence: it wants to retry the one step that failed, against the
        state the previous steps already produced. Running the lot again would
        reset that state and measure something else.
        """

        from ..hub.client import StudioBridge
        from ..scenario import ScenarioRunner, load_scenario

        scenario_path = _inside(root, arguments["scenario"], "scenario")
        if not scenario_path.is_file():
            raise ToolError(f"scenario not found: {scenario_path}")
        document = load_scenario(scenario_path)
        steps = document.get("steps") or []

        index = int(arguments["index"])
        if not 0 <= index < len(steps):
            raise ToolError(
                f"step {index} does not exist; this scenario has {len(steps)} steps (0..{len(steps) - 1})"
            )

        bridge = StudioBridge(
            arguments.get("hub") or os.environ.get("RQE_HUB_URL", "http://127.0.0.1:8790"),
            token=os.environ.get("RQE_BRIDGE_TOKEN"),
        )
        try:
            bridge.pin_to_running()
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"a scenario step needs a running place: {exc}") from exc

        # A one-step scenario carrying only the requested step. Reusing the
        # runner rather than reimplementing dispatch keeps a stepped run and a
        # full run measuring the same thing.
        single = dict(document)
        single["steps"] = [steps[index]]
        try:
            result = ScenarioRunner(bridge).run(single)
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        payload = result.to_dict() if hasattr(result, "to_dict") else {}
        executed = (payload.get("steps") or [{}])[0]
        return {
            "scenario": str(scenario_path.relative_to(root)),
            "index": index,
            "kind": executed.get("kind"),
            "status": executed.get("status"),
            "reason": executed.get("reason"),
            "detail": executed.get("detail"),
            "note": (
                "this ran one step against whatever state the place was already in; "
                "it is not equivalent to reaching that step through the full scenario"
            ),
        }

    server.register(Tool(
        name="scenario_step",
        description=(
            "Run one step of a scenario against the current state of a running place. For "
            "retrying a failed step without resetting what the previous steps built."
        ),
        input_schema={
            "type": "object",
            "required": ["scenario", "index"],
            "additionalProperties": False,
            "properties": {
                "scenario": {"type": "string", "minLength": 1},
                "index": {"type": "integer", "minimum": 0},
                "hub": {"type": "string"},
            },
        },
        handler=scenario_step,
    ))

    def scenario_replay(arguments: dict[str, Any]) -> dict[str, Any]:
        """Re-run a stored result's scenario and compare the two.

        The regression instrument. A stored result names the scenario and the
        verdicts it reached; replaying and diffing answers "is this still true"
        without anyone deciding by hand which steps matter.
        """

        from ..scenario_compare import compare_results

        stored_path = _inside(root, arguments["result"], "result")
        if not stored_path.is_file():
            raise ToolError(f"stored result not found: {stored_path}")
        stored = json.loads(stored_path.read_text(encoding="utf-8"))

        scenario_relative = arguments.get("scenario") or stored.get("scenarioPath")
        if not scenario_relative:
            raise ToolError(
                "the stored result does not record which file produced it; pass `scenario`"
            )

        fresh = scenario_run({
            "scenario": scenario_relative,
            "hub": arguments.get("hub"),
            "pinToRunning": True,
        })
        comparison = compare_results(stored, fresh.get("result") or {})
        payload = comparison.to_dict()
        payload["summary"] = comparison.summary()
        payload["scenario"] = scenario_relative
        payload["storedResult"] = str(stored_path.relative_to(root))
        return payload

    server.register(Tool(
        name="scenario_replay",
        description=(
            "Re-run the scenario behind a stored result and report which steps regressed "
            "or were fixed. Turns a scenario from a test into a regression instrument."
        ),
        input_schema={
            "type": "object",
            "required": ["result"],
            "additionalProperties": False,
            "properties": {
                "result": {"type": "string", "minLength": 1},
                "scenario": {"type": "string"},
                "hub": {"type": "string"},
            },
        },
        handler=scenario_replay,
    ))

    # ---------------------------------------------------------------- factory

    def factory_inspect(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..orchestrator.blueprint import compile_production_blueprint

        path = _inside(root, arguments["project"], "project")
        if not path.is_file():
            raise ToolError(f"project definition not found: {path}")
        try:
            # The compiler takes the document, not the path. Handing it a Path
            # fails with "'WindowsPath' object is not iterable", which reads as
            # a compiler bug rather than a caller one.
            plan = compile_production_blueprint(json.loads(path.read_text(encoding="utf-8")))
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        payload = plan.to_dict() if hasattr(plan, "to_dict") else {}
        return {
            "project": str(path.relative_to(root)),
            **_summarise_plan(payload),
        }

    server.register(Tool(
        name="factory_inspect",
        description=(
            "Compile a game project definition into its production DAG and report the "
            "shape. Does not execute anything and cannot authorise a release."
        ),
        input_schema={
            "type": "object",
            "required": ["project"],
            "additionalProperties": False,
            "properties": {"project": {"type": "string", "minLength": 1}},
        },
        handler=factory_inspect,
    ))

    def factory_execute(arguments: dict[str, Any]) -> dict[str, Any]:
        """Run or inspect the durable production DAG without inventing adapters.

        The source may be the original blueprint or a stored compiled plan.  A
        blueprint has enough context for the two read-only verification
        adapters currently implemented; a serialized plan deliberately gets an
        empty registry because its declared checks cannot be re-proved from the
        DAG alone.
        """

        from .factory_execution import FactoryExecutionError, execute_factory_action

        source = _inside(root, arguments["source"], "source")
        if not source.is_file():
            raise ToolError(f"factory execution source not found: {source}")
        journal = _inside(
            root,
            arguments.get("journal", ".tmp/factory-executor.sqlite3"),
            "journal",
        )
        journal.parent.mkdir(parents=True, exist_ok=True)
        try:
            return execute_factory_action(
                root=root,
                source_path=source,
                source_relative=source.relative_to(root).as_posix(),
                journal_path=journal,
                journal_relative=journal.relative_to(root).as_posix(),
                campaign_id=arguments["campaign"],
                action=arguments["action"],
                worker_id=arguments.get("workerId", "mcp-factory-executor"),
                max_tasks=arguments.get("maxTasks"),
                cancellation_reason=arguments.get("cancellationReason"),
            )
        except FactoryExecutionError as exc:
            raise ToolError(str(exc)) from exc
        except Exception as exc:  # noqa: BLE001 - one fail-closed MCP boundary
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

    server.register(Tool(
        name="factory_execute",
        description=(
            "Durably run, resume, inspect, or cancel a compiled production DAG from a "
            "blueprint or hash-verified plan. Invokes only explicitly registered "
            "deterministic handlers; unsupported production work is recorded as "
            "UNSUPPORTED/BLOCKED. Never opens Studio and never authorizes release."
        ),
        input_schema={
            "type": "object",
            "required": ["source", "campaign", "action"],
            "additionalProperties": False,
            "properties": {
                "source": {
                    "type": "string",
                    "minLength": 1,
                    "description": "repository-relative production blueprint or compiled .plan.json",
                },
                "campaign": {"type": "string", "minLength": 1, "maxLength": 128},
                "action": {"enum": ["run", "resume", "inspect", "cancel"]},
                "journal": {"type": "string", "minLength": 1},
                "workerId": {"type": "string", "minLength": 1, "maxLength": 128},
                "maxTasks": {"type": "integer", "minimum": 1, "maximum": 10000},
                "cancellationReason": {"type": "string", "minLength": 1, "maxLength": 500},
            },
        },
        handler=factory_execute,
    ))

    def capabilities_report(_: dict[str, Any]) -> dict[str, Any]:
        from ..production_capabilities import CapabilityCatalogError, load_default_catalog

        try:
            catalog = load_default_catalog()
        except CapabilityCatalogError as exc:
            raise ToolError(str(exc)) from exc
        report = catalog.coverage_report()
        return {
            "integrityStatus": report["integrityStatus"],
            "validationLevel": report["validationLevel"],
            # Stated on every response: an inventory of what exists is not a
            # statement that any of it works well enough to ship.
            "authorizesRelease": report["authorizesRelease"],
            "summary": report["summary"],
            "bridgeCommands": report["bridgeCommands"],
        }

    server.register(Tool(
        name="capabilities_report",
        description=(
            "The production capability inventory: which phases, commands and adapters are "
            "covered, and which are gaps. Never authorises a release."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=capabilities_report,
    ))

    def release_blockers(_: dict[str, Any]) -> dict[str, Any]:
        from ..measurement_plan import compile_measurement_plan
        from ..project import Project

        try:
            plan = compile_measurement_plan(Project.load(root))
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        orphans = (plan.metadata.get("probeRegistry") or {}).get("orphans") or []
        conformance = plan.metadata.get("tokenConformance") or {}
        return {
            "requirements": len(plan.requirements),
            "requiredCategories": list(plan.required_categories),
            "orphanRequirements": [item.get("requirementId") for item in orphans],
            "orphanCount": len(orphans),
            "tokenConformance": conformance.get("status"),
            "tokenIssues": len(conformance.get("issues") or []),
            "minimumVisualScore": plan.minimum_visual_score,
        }

    server.register(Tool(
        name="release_blockers",
        description=(
            "What stands between the current project and a release candidate: how many "
            "requirements exist, which have no producer, and whether the visual "
            "thresholds trace to a token set."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=release_blockers,
    ))

    return server
