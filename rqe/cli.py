from __future__ import annotations

import argparse
import json
import logging
import subprocess
import time
from pathlib import Path

from .audit import run_audit
from .assets.cli import add_assets_parser, render_payload, run_assets_command
from .bridge.adapters import HeadlessGameAdapter, StudioGameAdapter
from .bridge.core import GameAgentBridge
from .bridge.rpc import serve
from .bridge.transport import HttpJsonRpcTransport
from .continuous import run_cycle, run_forever
from .factory_cli import add_factory_parsers, run_factory_command
from .fixes import write_fix_plan
from .hub.client import StudioBridge
from .hub.install import install_plugin
from .hub.lifecycle import restart_for_bridge, start_play_solo
from .hub.protocol import BridgeError
from .hub.server import BridgeHub, serve_forever
from .observe import measure_place, write_observation
from .project import Project, ProjectError, read_json
from .release import execute_release, release_terminal_summary
from .scenario import ScenarioRunner, load_scenario, write_scenario_result
from .reporting import terminal_summary, write_reports
from .visual_cli import VisualCliError, add_visual_parser, run_visual_command


LOGGER = logging.getLogger("rqe")

DEFAULT_HUB_URL = "http://127.0.0.1:8790"


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
    serve_parser.add_argument("--studio-url", help="Studio/MCP relay URL; omit for headless backend")
    serve_parser.add_argument("--token", help="optional bearer token")
    bridge_sub.add_parser("operations", help="list the bridge operation surface")

    studio = subparsers.add_parser("studio", help="talk to a live Roblox Studio through the Studio Bridge")
    studio_sub = studio.add_subparsers(dest="studio_command", required=True)

    hub_serve = studio_sub.add_parser("serve", help="run the bridge hub the Studio plugin connects to")
    hub_serve.add_argument("--host", default="127.0.0.1", help="bind address; loopback only by default")
    hub_serve.add_argument("--port", type=int, default=8790)
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

    hub_scenario = studio_sub.add_parser("scenario", help="run a gameplay scenario against the live game")
    hub_scenario.add_argument("file", help="scenario JSON, e.g. contracts/scenarios/first-purchase-e2e.json")
    hub_scenario.add_argument("path", nargs="?", default=".", help="project root")
    hub_scenario.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_scenario.add_argument("--run-id", help="artifact run id to file the result under")
    hub_scenario.add_argument("--place", help="place to reload for a 'reset' step; scenarios may set 'place' themselves")

    hub_play = studio_sub.add_parser("play_solo", help="start Play Solo to get a real Player (briefly focuses Studio; F5 cannot be synthesised)")
    hub_play.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_play.add_argument("--timeout", type=float, default=90.0)

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
    hub_restart.add_argument("--foreground", action="store_true", help="let Studio take the screen; by default it starts minimised and stays out of the way")

    hub_measure = studio_sub.add_parser("measure", help="measure the live place and write runtime-sourced evidence")
    hub_measure.add_argument("path", nargs="?", default=".", help="project root")
    hub_measure.add_argument("--hub", default=DEFAULT_HUB_URL)
    hub_measure.add_argument("--run-id", help="artifact run id; generated when omitted")
    hub_measure.add_argument("--start-run", action="store_true", help="start the simulation, measure it, then return Studio to edit mode")
    hub_measure.add_argument("--keep-running", action="store_true", help="with --start-run, leave the simulation running")

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
    if args.studio_url:
        adapter = StudioGameAdapter(HttpJsonRpcTransport(args.studio_url, token=args.token))
    else:
        adapter = HeadlessGameAdapter(project)
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

    if args.studio_command == "scenario":
        root = Path(args.path).resolve()
        scenario = load_scenario(Path(args.file))

        place = scenario.get("place") or args.place
        archive_root = root / "artifacts" / "_archive"

        def reset_session() -> dict:
            """Give the scenario a clean game: fresh place, fresh player.

            A full Studio restart rather than Shift+F5/F5 cycling. Measured: the
            plugin is not reliably loaded into the play DataModel after a
            stop/start cycle within one Studio process -- both sessions came back
            reporting `edit` while a play session was visibly running, so
            gameplay commands had nowhere correct to go. Restarting is slower and
            it is deterministic.
            """
            if not place:
                return {"started": False, "reason": "scenario needs a 'place' (or --place) to reset from"}
            steps = restart_for_bridge(Path(place).resolve(), archive_root, bridge=bridge, wait_seconds=240)
            if not steps["handshake"].get("sessions"):
                return {"started": False, "reason": "Studio did not reconnect after the restart", "restart": steps}
            bridge.call("bridge.install_client", timeout=40)
            played = start_play_solo(bridge, wait_seconds=120)
            played["restart"] = {"minimized": steps.get("minimized"), "recovery": steps.get("recovery")}
            return played

        result = ScenarioRunner(bridge, reset_session=reset_session).run(scenario)
        run_id = args.run_id or "adhoc"
        target = write_scenario_result(result, root / "artifacts" / run_id / "scenarios")
        LOGGER.info(result.terminal_summary())
        LOGGER.info("scenario evidence: %s", target)
        return 0 if result.status == "PASS" else 1

    if args.studio_command == "play_solo":
        result = start_play_solo(bridge, wait_seconds=args.timeout)
        LOGGER.info(json.dumps(result, indent=2, ensure_ascii=False))
        return 0 if result.get("started") else 1

    if args.studio_command == "exec":
        source = Path(args.file).read_text(encoding="utf-8")
        response = bridge.call_response(
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
        response = bridge.call_response(args.method, params, timeout=args.timeout)
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
    args = build_parser().parse_args(argv)
    # Without this the CLI is silent: every command reports through LOGGER.
    logging.basicConfig(level=logging.INFO, format="%(message)s")

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
        except KeyboardInterrupt:
            LOGGER.info("stopped")
            return 0

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
