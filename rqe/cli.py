from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
import time
from pathlib import Path

from .audit import run_audit
from .assets.cli import add_assets_parser, render_payload, run_assets_command
from .bridge.adapters import HeadlessGameAdapter, StudioGameAdapter
from .bridge.core import GameAgentBridge
from .bridge.rpc import serve
from .bridge.transport import HttpJsonRpcTransport
from .bridge.studio_mcp import (
    FederatedStudioTransport,
    RobloxStudioMcpTransport,
)
from .continuous import run_cycle, run_forever
from .exits import INTERRUPTED
from .factory_cli import add_factory_parsers, run_factory_command
from .fixes import write_fix_plan
from .hub.client import StudioBridge
from .hub.install import install_plugin
from .hub.lifecycle import ensure_studio_session, restart_for_bridge, start_play_solo, stop_play_solo
from .hub.protocol import BridgeError
from .hub.server import BridgeHub, serve_forever
from .observe import measure_place, write_observation
from .project import Project, ProjectError, read_json
from .release import execute_release, release_terminal_summary
from .scenario import ScenarioRunner, load_scenario, write_scenario_result
from .reporting import terminal_summary, write_reports
from .visual_cli import VisualCliError, add_visual_parser, run_visual_command
from .workspace import hub_port, hub_url


LOGGER = logging.getLogger("rqe")

DEFAULT_HUB_URL = hub_url()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="rqe", description="Roblox Quality Engine")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("audit", "verify", "fix"):
        sub = subparsers.add_parser(command, help=f"{command} a Roblox project")
        sub.add_argument("path", nargs="?", default=".", help="project root")
    release = subparsers.add_parser("release", help="build and evaluate one immutable fail-closed release run")
    release.add_argument("path", nargs="?", default=".", help="project root")
    release.add_argument("--hub", default=DEFAULT_HUB_URL)
    release.add_argument("--run-id", help="unique immutable run id; generated when omitted")
    release.add_argument(
        "--static-only",
        action="store_true",
        help="prepare provenance and static evidence only; the release will remain blocked",
    )
    improve = subparsers.add_parser("improve", help="run the continuous audit/improvement cycle")
    improve.add_argument("path", nargs="?", default=".", help="project root")
    improve.add_argument("--interval-seconds", type=float, default=300.0, help="wait between cycles")
    improve.add_argument("--once", action="store_true", help="run one cycle and exit")
    bridge = subparsers.add_parser("bridge", help="run the Game Agent Bridge")
    bridge_sub = bridge.add_subparsers(dest="bridge_command", required=True)
    demo = bridge_sub.add_parser("demo", help="run the human-mode purchase scenario headlessly")
    demo.add_argument("path", nargs="?", default=".", help="project root")
    demo.add_argument("--mode", choices=["blackbox", "graybox", "whitebox"], default="blackbox")
    demo.add_argument("--scenario", default="contracts/scenarios/purchase-first-pack.json")
    serve_parser = bridge_sub.add_parser("serve", help="serve the bridge over localhost JSON-RPC")
    serve_parser.add_argument("path", nargs="?", default=".", help="project root")
    serve_parser.add_argument("--port", type=int, default=8765)
    serve_parser.add_argument(
        "--backend",
        choices=["headless", "relay", "federated"],
        help=(
            "execution backend; default preserves legacy behavior "
            "(relay when --studio-url is set, otherwise headless)"
        ),
    )
    serve_parser.add_argument(
        "--studio-url",
        help=(
            "RQE/Studio relay URL. Required by relay and federated backends; "
            "in federated mode this carries RQE-only semantic probes"
        ),
    )
    serve_parser.add_argument(
        "--studio-id",
        help="exact built-in Roblox Studio MCP instance id for federated mode",
    )
    serve_parser.add_argument(
        "--studio-place-name",
        help="exact place name used to select the Studio MCP instance",
    )
    serve_parser.add_argument(
        "--studio-place-id",
        type=int,
        help="published place id used to disambiguate Studio MCP instances",
    )
    serve_parser.add_argument("--token", help="optional bearer token")
    bridge_sub.add_parser("operations", help="list the bridge operation surface")

    studio = subparsers.add_parser("studio", help="talk to a live Roblox Studio through the Studio Bridge")
    studio_sub = studio.add_subparsers(dest="studio_command", required=True)

    hub_serve = studio_sub.add_parser("serve", help="run the bridge hub the Studio plugin connects to")
    hub_serve.add_argument("--host", default="127.0.0.1", help="bind address; loopback only by default")
    hub_serve.add_argument("--port", type=int, default=hub_port())
    hub_serve.add_argument("--token", help="optional bearer token required from agents")
    hub_serve.add_argument(
        "--require-mutation-leases",
        action="store_true",
        help="reject transient/mutating commands unless they carry a current fenced lease",
    )

    hub_status = studio_sub.add_parser("status", help="show the hub and any connected Studio sessions")
    hub_status.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_status.add_argument("--wait", type=float, default=0.0, help="wait up to N seconds for a plugin to connect")

    hub_call = studio_sub.add_parser("call", help="run one bridge command in Studio and print the result")
    hub_call.add_argument("method", help="for example: bridge.ping, dm.tree, world.ground_support")
    hub_call.add_argument("--params", default="{}", help="JSON object of parameters")
    hub_call.add_argument("--timeout", type=float, default=15.0)
    hub_call.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_call.add_argument(
        "--allow-arbitrary",
        action="store_true",
        help="explicitly authorize commands such as bridge.exec and test.run",
    )

    hub_scenario = studio_sub.add_parser("scenario", help="run a gameplay scenario against the live game")
    hub_scenario.add_argument("file", help="scenario JSON, e.g. contracts/scenarios/first-purchase-e2e.json")
    hub_scenario.add_argument("path", nargs="?", default=".", help="project root")
    hub_scenario.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_scenario.add_argument("--run-id", help="artifact run id to file the result under")
    hub_scenario.add_argument("--place", help="place to use for reset steps; scenarios may set 'place' themselves")
    hub_scenario.add_argument(
        "--allow-cold-launch",
        action="store_true",
        help="explicitly allow a destructive Studio cold launch if no compatible background session exists",
    )

    hub_play = studio_sub.add_parser(
        "play_solo",
        help="start Play Solo through StudioTestService without foreground focus",
    )
    hub_play.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_play.add_argument("--timeout", type=float, default=90.0)

    hub_native = studio_sub.add_parser("test", help="run and close an identity-bound native Studio test (transport smoke only)")
    hub_native.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_native.add_argument("--mode", choices=["play", "run", "multiplayer"], default="play")
    hub_native.add_argument("--players", type=int, default=2)
    hub_native.add_argument("--timeout", type=float, default=120.0)

    hub_exec = studio_sub.add_parser("exec", help="run a Luau file inside the live Studio and print what it returns")
    hub_exec.add_argument("file", help="path to a .lua/.luau file; its return value comes back as JSON")
    hub_exec.add_argument("--timeout", type=float, default=30.0)
    hub_exec.add_argument("--hub", default=DEFAULT_HUB_URL)

    hub_install = studio_sub.add_parser("install", help="build and install the Studio plugin locally")
    hub_install.add_argument("path", nargs="?", default=".", help="project root")
    hub_install.add_argument("--plugins-dir", help="override the Studio plugins folder")

    hub_restart = studio_sub.add_parser("restart", help="restart Studio unattended: archives auto-recovery files, clears the lock, waits for the bridge")
    hub_restart.add_argument("place", help="path to the .rbxlx/.rbxl place to open")
    hub_restart.add_argument("path", nargs="?", default=".", help="project root")
    hub_restart.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_restart.add_argument("--timeout", type=float, default=180.0)
    hub_restart.add_argument("--no-wait", action="store_true", help="launch without waiting for the plugin handshake")
    hub_restart.add_argument("--foreground", action="store_true", help="allow the explicit cold launch to foreground; background launch requests minimised/no-activate but Studio or Windows may still surface it briefly — prefer persistent sessions for true background work")

    hub_measure = studio_sub.add_parser("measure", help="measure the live place and write runtime-sourced evidence")
    hub_measure.add_argument("path", nargs="?", default=".", help="project root")
    hub_measure.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_measure.add_argument("--run-id", help="artifact run id; generated when omitted")
    hub_measure.add_argument("--start-run", action="store_true", help="start the simulation, measure it, then return Studio to edit mode")
    hub_measure.add_argument("--keep-running", action="store_true", help="with --start-run, leave the simulation running")

    stamp = subparsers.add_parser(
        "stamp",
        help="check the derived hashes checked into this repository, and re-cut them")
    stamp.add_argument("path", nargs="?", default=".", help="repository root")
    stamp.add_argument("--write", action="store_true",
                       help="re-cut every drifted stamp, then read the diff")
    stamp.add_argument("--json", action="store_true", help="machine-readable")

    add_assets_parser(subparsers)
    add_factory_parsers(subparsers)
    add_visual_parser(subparsers)

    return parser


def _write_agent_markdown(session: dict, path: Path) -> None:
    lines = [
        "# Game Agent Bridge Session",
        "",
        f"Mode: **{session['bridge']['mode']}**",
        f"Started: **{session['started']}**",
        "",
        "## Action evidence",
        "",
        "| # | Result | Action | Reason |",
        "|---:|---|---|---|",
    ]
    for record in session.get("actionRecords", []):
        lines.append(f"| {record['sequence']} | {record['result']} | `{record['action']}` | {record.get('reason') or ''} |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _run_bridge(args: argparse.Namespace) -> int:
    if args.bridge_command == "operations":
        LOGGER.info("\n".join(GameAgentBridge.OPERATIONS))
        return 0
    project = Project.load(Path(args.path).resolve())
    if args.bridge_command == "demo":
        adapter = HeadlessGameAdapter(project)
        bridge = GameAgentBridge(adapter, args.mode)
        scenario = read_json(Path(args.path).resolve() / args.scenario)
        result = bridge.run_scenario(scenario)
        reports_dir = project.reports_dir
        session_path = bridge.save_session(reports_dir / "agent-session.json")
        _write_agent_markdown(bridge.session(), reports_dir / "agent-session.md")
        LOGGER.info(json.dumps(result, indent=2, ensure_ascii=False))
        LOGGER.info("Agent evidence: %s", session_path)
        return 0 if result["status"] == "PASS" else 1
    backend = args.backend or ("relay" if args.studio_url else "headless")
    if backend == "headless":
        adapter = HeadlessGameAdapter(project)
    elif backend == "relay":
        if not args.studio_url:
            raise SystemExit("rqe bridge serve: --backend relay requires --studio-url")
        adapter = StudioGameAdapter(
            HttpJsonRpcTransport(args.studio_url, token=args.token)
        )
    else:
        if not args.studio_url:
            raise SystemExit(
                "rqe bridge serve: --backend federated requires --studio-url "
                "for the RQE semantic-probe extension"
            )
        official = RobloxStudioMcpTransport(
            studio_id=args.studio_id,
            place_name=args.studio_place_name,
            place_id=args.studio_place_id,
        )
        extension = HttpJsonRpcTransport(args.studio_url, token=args.token)
        adapter = StudioGameAdapter(
            FederatedStudioTransport(official, extension)
        )
    bridge = GameAgentBridge(adapter, "graybox")
    serve(bridge, port=args.port, token=args.token)
    return 0


def _run_studio(args: argparse.Namespace) -> int:
    if args.studio_command == "serve":
        hub = BridgeHub(token=args.token, require_mutation_leases=args.require_mutation_leases)
        LOGGER.info("Bridge hub on http://%s:%d - waiting for the Studio plugin", args.host, args.port)
        LOGGER.info("Install the plugin with: python rqe.py studio install")
        serve_forever(hub, host=args.host, port=args.port)
        return 0

    if args.studio_command == "install":
        result = install_plugin(Path(args.path).resolve(), Path(args.plugins_dir) if args.plugins_dir else None)
        LOGGER.info(json.dumps(result, indent=2, ensure_ascii=False))
        return 0

    bridge = StudioBridge(args.hub)

    if args.studio_command == "restart":
        root = Path(args.path).resolve()
        result = restart_for_bridge(
            Path(args.place).resolve(),
            root / "artifacts" / "_archive",
            bridge=None if args.no_wait else bridge,
            wait_seconds=args.timeout,
            background=not args.foreground,
        )
        LOGGER.info(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if args.no_wait or result["handshake"].get("sessions") else 1

    if args.studio_command == "status":
        if args.wait > 0:
            try:
                bridge.wait_for_plugin(timeout=args.wait)
            except BridgeError as exc:
                LOGGER.error(json.dumps(exc.to_dict(), indent=2, ensure_ascii=False))
                return 1
        status = bridge.status()
        LOGGER.info(json.dumps(status, indent=2, ensure_ascii=False))
        return 0 if status.get("sessions") else 1

    if args.studio_command == "test":
        from .hub.native_test import run_native_test
        result = run_native_test(bridge, mode=args.mode, players=args.players, timeout=args.timeout)
        LOGGER.info(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if result["status"] == "COMPLETED" else 1

    if args.studio_command == "scenario":
        root = Path(args.path).resolve()
        scenario = load_scenario(Path(args.file))

        place = scenario.get("place") or args.place
        archive_root = root / "artifacts" / "_archive"

        def reset_session() -> dict:
            """Give the scenario a clean player without stealing desktop focus.

            Reuse an identity-matched persistent edit session and transition the
            test through StudioTestService. A destructive cold launch is allowed
            only when the caller explicitly passes --allow-cold-launch.
            """
            if not place:
                return {"started": False, "reason": "scenario needs a 'place' (or --place) to reset from"}
            bridge.unpin()
            ensured = ensure_studio_session(
                Path(place).resolve(),
                archive_root,
                bridge,
                wait_seconds=45,
                background=True,
                allow_cold_launch=bool(args.allow_cold_launch),
            )
            if not ensured.get("ready"):
                return {
                    "started": False,
                    "reason": ensured.get("reason") or "compatible background Studio session unavailable",
                    "needsColdLaunch": ensured.get("needsColdLaunch", False),
                    "session": ensured,
                }
            try:
                sessions = bridge.status().get("sessions", [])
            except Exception:
                sessions = []
            runtime = [
                item for item in sessions
                if item.get("context") in {"run", "server", "client"}
                and int(item.get("polls") or 0) > 0
            ]

            stopped = None
            if runtime:
                stopped = stop_play_solo(
                    bridge,
                    wait_seconds=30,
                    allow_foreground_fallback=False,
                )
                if not stopped.get("stopped"):
                    return {
                        "started": False,
                        "reason": "native StudioTestService could not reset the active scenario",
                        "stop": stopped,
                    }

            bridge.unpin()
            played = start_play_solo(
                bridge,
                wait_seconds=120,
                allow_foreground_fallback=False,
            )
            played["sessionReuse"] = {
                "reused": ensured.get("reused", False),
                "coldLaunched": ensured.get("coldLaunched", False),
                "stoppedPreviousRun": bool(runtime),
            }
            if stopped is not None:
                played["stop"] = stopped
            return played

        result = ScenarioRunner(bridge, reset_session=reset_session).run(scenario)
        run_id = args.run_id or "adhoc"
        target = write_scenario_result(result, root / "artifacts" / run_id / "scenarios")
        LOGGER.info(result.terminal_summary())
        LOGGER.info("scenario evidence: %s", target)
        return 0 if result.status == "PASS" else 1

    if args.studio_command == "play_solo":
        result = start_play_solo(bridge, wait_seconds=args.timeout, allow_foreground_fallback=False)
        LOGGER.info(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if result.get("started") else 1

    if args.studio_command == "exec":
        source = Path(args.file).read_text(encoding="utf-8")
        # Choosing the dedicated `studio exec` command is the operator's
        # explicit opt-in; ordinary StudioBridge clients stay fail-closed.
        executor = StudioBridge(args.hub, allow_arbitrary=True)
        with executor.lease_scope(
            agent_id="rqe-cli-exec",
            context="edit",
            ttl_seconds=max(30.0, min(float(args.timeout) + 30.0, 300.0)),
        ):
            response = executor.call_response(
                "bridge.exec",
                {"source": source, "chunkName": Path(args.file).name},
                timeout=args.timeout,
            )
        if response.ok:
            LOGGER.info(json.dumps(response.result.get("returned"), indent=2, ensure_ascii=False))
        else:
            LOGGER.error(json.dumps(response.error, indent=2, ensure_ascii=False))
        return 0 if response.ok else 1

    if args.studio_command == "call":
        params = json.loads(args.params)
        if not isinstance(params, dict):
            LOGGER.error("--params must be a JSON object")
            return 2
        caller = StudioBridge(args.hub, allow_arbitrary=bool(args.allow_arbitrary))
        from .hub.commands import load_default_registry

        try:
            spec = load_default_registry(verify_dispatcher=False).require(args.method)
        except Exception:
            spec = None
        if spec is not None and spec.lease_targeted and "_lease" not in params:
            requested_context = str(params.get("_context") or "")
            if not requested_context:
                if args.method == "run.start" or args.method.startswith("assets.") or args.method.startswith("bridge."):
                    requested_context = "edit"
                elif (
                    args.method == "run.stop"
                    or args.method.startswith("actor.")
                    or args.method.startswith("client.")
                    or args.method in {"product.identity", "quality.snapshot"}
                ):
                    requested_context = "running"
                else:
                    requested_context = "any"
            scoped_params = dict(params)
            scoped_params.pop("_context", None)
            with caller.lease_scope(
                agent_id="rqe-cli-call",
                context=requested_context,
                ttl_seconds=max(30.0, min(float(args.timeout) + 30.0, 300.0)),
            ):
                response = caller.call_response(args.method, scoped_params, timeout=args.timeout)
        else:
            response = caller.call_response(args.method, params, timeout=args.timeout)
        LOGGER.info(json.dumps(response.to_dict(), indent=2, ensure_ascii=False))
        return 0 if response.ok else 1

    if args.studio_command == "measure":
        project = Project.load(Path(args.path).resolve())
        observation = measure_place(
            bridge,
            project,
            run_id=args.run_id,
            start_run=args.start_run,
            stop_after=not args.keep_running,
        )
        paths = write_observation(observation, project.reports_dir)
        LOGGER.info(observation.terminal_summary())
        for label, path in paths.items():
            LOGGER.info("%s: %s", label, path)
        return 0 if observation.ok else 1

    return 2


def main(argv: list[str] | None = None) -> int:
    try:
        return _dispatch(argv)
    except KeyboardInterrupt:
        print("rqe: interrupted", file=sys.stderr)
        return INTERRUPTED


def _dispatch(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    # Without this the CLI is silent: every command reports through LOGGER.
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    if args.command == "stamp":
        from .stamps import StampError, refresh, verify

        root = Path(args.path).resolve()
        try:
            if args.write:
                refresh(root)
            results = verify(root)
        except StampError as exc:
            LOGGER.error("stamp: %s", exc)
            return 2

        if args.json:
            LOGGER.info(json.dumps([item.to_dict() for item in results], indent=2))
        else:
            for item in results:
                LOGGER.info(item.render())
        bad = [item for item in results if not item.ok]
        if bad and not args.write:
            LOGGER.info("")
            LOGGER.info("  re-cut them with:  python rqe.py stamp --write")
        return 1 if bad else 0

    if args.command == "assets":
        try:
            exit_code, payload = run_assets_command(args)
            LOGGER.info(render_payload(payload))
            return exit_code
        except (OSError, RuntimeError, TypeError, ValueError, json.JSONDecodeError) as exc:
            LOGGER.error("Asset pipeline error: %s", exc)
            return 2

    if args.command in {"capabilities", "factory"}:
        try:
            exit_code, payload = run_factory_command(args)
            LOGGER.info(render_payload(payload))
            return exit_code
        except (OSError, RuntimeError, TypeError, ValueError, json.JSONDecodeError) as exc:
            LOGGER.error("Factory control error: %s", exc)
            return 2

    if args.command == "visual":
        try:
            exit_code, payload = run_visual_command(args)
            LOGGER.info(render_payload(payload))
            return exit_code
        except (VisualCliError, OSError, RuntimeError, TypeError, ValueError, json.JSONDecodeError) as exc:
            LOGGER.error("Visual review error: %s", exc)
            return 2

    if args.command == "release":
        try:
            outcome = execute_release(
                Path(args.path).resolve(),
                hub_url=args.hub,
                run_id=args.run_id,
                static_only=args.static_only,
            )
            LOGGER.info(release_terminal_summary(outcome))
            return 0 if outcome.gate.release_allowed else 1
        except (ProjectError, OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exc:
            LOGGER.error("Release infrastructure error: %s", exc)
            return 2

    if args.command == "studio":
        try:
            return _run_studio(args)
        except BridgeError as exc:
            LOGGER.error("Studio bridge error: %s", json.dumps(exc.to_dict(), ensure_ascii=False))
            return 1
        except (ProjectError, OSError, RuntimeError, ValueError, json.JSONDecodeError) as exc:
            LOGGER.error("Studio command failed: %s", exc)
            return 2

    if args.command == "bridge":
        try:
            return _run_bridge(args)
        except (ProjectError, OSError, KeyError, ValueError) as exc:
            LOGGER.error("RQE bridge error: %s", exc)
            return 2
    if args.command == "improve":
        try:
            root = Path(args.path).resolve()
            if args.once:
                run_cycle(root)
            else:
                run_forever(root, interval_seconds=args.interval_seconds)
            return 0
        except (ProjectError, OSError, ValueError) as exc:
            LOGGER.error("RQE improvement cycle error: %s", exc)
            return 2
    root = Path(args.path).resolve()
    try:
        report = run_audit(root)
        json_path, md_path = write_reports(report, root / "reports")
        LOGGER.info(terminal_summary(report))
        LOGGER.info("Evidence JSON: %s", json_path)
        LOGGER.info("Markdown report: %s", md_path)
        if args.command == "fix":
            fix_path = write_fix_plan(report, root / "reports")
            LOGGER.info("Fix plan: %s", fix_path)
        if args.command == "verify" and not report.release_allowed:
            return 1
        return 0
    except ProjectError as exc:
        LOGGER.error("RQE error: %s", exc)
        return 2
