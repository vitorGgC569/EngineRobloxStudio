"""Forge — the authoring half.

Deliberately thin. Every line of Python here is scaffolding, checking or
plumbing to the Studio bridge; none of it writes gameplay. The moment this
file starts emitting Luau, Forge has become the thing it was built to replace.

    python forge/forge.py new mygame
    python forge/forge.py doctor mygame
    python forge/forge.py build mygame
    python forge/forge.py probe --hub http://127.0.0.1:8790
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from forge.cli import doctor as doctor_module  # noqa: E402
from forge.cli import scaffold as scaffold_module  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent


def _resolve(target: str) -> Path:
    path = Path(target)
    if path.exists():
        return path.resolve()
    for base in (REPO_ROOT / "games", REPO_ROOT):
        candidate = base / target
        if candidate.exists():
            return candidate.resolve()
    raise SystemExit(f"forge: no project at '{target}'")


# --------------------------------------------------------------------------


def cmd_new(args: argparse.Namespace) -> int:
    destination = Path(args.into).resolve() if args.into else (REPO_ROOT / "games")
    destination.mkdir(parents=True, exist_ok=True)
    try:
        root = scaffold_module.create(args.name, destination, vendor=args.vendor, force=args.force)
    except (ValueError, FileExistsError, FileNotFoundError) as exc:
        raise SystemExit(f"forge: {exc}")

    print(f"created {root}")
    print()
    print("  next:")
    print(f"    python forge/forge.py doctor {root.name}")
    print(f"    python forge/forge.py build {root.name}")
    print()
    print("  the skeleton has no gameplay in it. write systems in src/server/systems/.")
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    root = _resolve(args.project)
    findings = doctor_module.run(root)

    if args.json:
        print(
            json.dumps(
                [
                    {"severity": f.severity, "file": f.file, "line": f.line, "message": f.message}
                    for f in findings
                ],
                indent=2,
            )
        )
    else:
        errors = sum(1 for f in findings if f.severity == "error")
        warnings = sum(1 for f in findings if f.severity == "warning")
        notes = sum(1 for f in findings if f.severity == "note")

        if not findings:
            print(f"forge doctor: {root.name} - nothing to report")
        else:
            print(f"forge doctor: {root.name}")
            print()
            for finding in findings:
                print(finding.render(root))
            print()
            print(f"  {errors} error(s), {warnings} warning(s), {notes} note(s)")
            print()
            print("  these are authoring notes, not a release gate. Fix what is real,")
            print("  ignore what is not, and ship when the game is good.")

    return 1 if any(f.severity == "error" for f in findings) and args.strict else 0


def cmd_build(args: argparse.Namespace) -> int:
    root = _resolve(args.project)
    project_file = root / "default.project.json"
    if not project_file.exists():
        raise SystemExit(f"forge: no default.project.json in {root}")

    output = Path(args.output) if args.output else root / f"{root.name}.rbxlx"
    command = ["rojo", "build", str(project_file), "--output", str(output)]
    print(" ".join(command))
    try:
        result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    except FileNotFoundError:
        raise SystemExit("forge: rojo is not on PATH. Install it from https://rojo.space")

    if result.stdout.strip():
        print(result.stdout.strip())
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
        return result.returncode

    size = output.stat().st_size if output.exists() else 0
    print(f"built {output} ({size / 1024:.0f} KB)")
    return 0


def cmd_probe(args: argparse.Namespace) -> int:
    """Read a running game's own account of itself, through the Studio bridge.

    This is the half that Forge does not own. It calls the Quality Engine's hub
    and asks it to invoke `ReplicatedStorage.ForgeDebug`, which the game
    published by calling `Debug.expose()`.
    """
    import urllib.error
    import urllib.request

    # dm.properties, not a bindable invoke: a BindableFunction's OnInvoke lives
    # in one Lua VM, so a server-side handler is invisible to the client-side
    # command and every call returns null. A replicated StringValue is readable
    # from any context.
    if args.command == "snapshot":
        params = {"path": args.path + ".Snapshot", "properties": ["Value"]}
    else:
        params = {"path": args.path + ".Result", "properties": ["Value"]}

    payload = {"method": "dm.properties", "params": params, "id": 1}
    request = urllib.request.Request(
        args.hub.rstrip("/") + "/rpc",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        print(f"forge: cannot reach the hub at {args.hub} ({exc.reason})", file=sys.stderr)
        print("       start it with: python rqe.py studio serve", file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001
        print(f"forge: probe failed: {exc}", file=sys.stderr)
        return 2

    # The hub nests: { result: { ok, result: { properties: { Value } } } }.
    result = body.get("result", body)
    for _ in range(3):
        if isinstance(result, dict) and "properties" in result:
            props = result.get("properties") or {}
            if "Value" in props:
                result = props["Value"]
                break
        if isinstance(result, dict) and "result" in result:
            result = result["result"]
            continue
        break
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except json.JSONDecodeError:
            pass
    if result in (None, "", {}):
        print("forge: nothing published yet. Did the game call Debug.expose()?", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


def cmd_bench(args: argparse.Namespace) -> int:
    """Ask a running game to benchmark itself, and print the distribution.

    Median and p95, not mean: the mean hides the frame that took 40ms, and that
    frame is the one a player felt.
    """
    import urllib.error
    import urllib.request

    # Driven through the Debug command channel. `instance.update` runs in "run"
    # context, which is what `rqe studio call run.start` produces — and a
    # headless run is the right place to benchmark anyway, with no player
    # competing for the frame.
    command = {
        "method": "instance.update",
        "params": {
            "path": "ReplicatedStorage.ForgeDebug.Command",
            "properties": {"Value": json.dumps({"cmd": "bench", "entities": args.entities, "anchors": args.anchors})},
        },
        "id": 1,
    }

    def call(body: dict) -> dict:
        request = urllib.request.Request(
            args.hub.rstrip("/") + "/rpc",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=args.timeout) as response:
            return json.loads(response.read().decode("utf-8"))

    try:
        call(command)
    except urllib.error.URLError as exc:
        print(f"forge: cannot reach the hub at {args.hub} ({exc.reason})", file=sys.stderr)
        print("       start it with: python rqe.py studio serve", file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001
        print(f"forge: bench failed to start: {exc}", file=sys.stderr)
        return 2

    import time

    time.sleep(6)
    read = {
        "method": "dm.properties",
        "params": {"path": "ReplicatedStorage.ForgeDebug.Result", "properties": ["Value"]},
        "id": 2,
    }
    try:
        body = call(read)
    except Exception as exc:  # noqa: BLE001
        print(f"forge: could not read the result: {exc}", file=sys.stderr)
        return 2

    result = body.get("result", body)
    for _ in range(3):
        if isinstance(result, dict) and "properties" in result:
            result = (result.get("properties") or {}).get("Value")
            break
        if isinstance(result, dict) and "result" in result:
            result = result["result"]
            continue
        break
    if isinstance(result, str):
        try:
            result = json.loads(result)
        except json.JSONDecodeError:
            pass

    if not isinstance(result, dict) or not result.get("results"):
        print("forge: no benchmark result. Is the game running with Debug.expose()?", file=sys.stderr)
        return 1

    print(f"forge bench  |  {result.get('players', 0)} player(s)  "
          f"heartbeat {result.get('heartbeatMs', 0):.2f}ms  memory {result.get('memoryMb', 0)}MB")
    print()
    print(f"  {'case':<38} {'median':>9} {'p95':>9} {'max':>9}")
    for name in sorted(result["results"]):
        entry = result["results"][name]
        if "error" in entry:
            print(f"  {name:<38} {entry['error'][:40]}")
            continue
        print(f"  {name:<38} {entry['medianMs']:>8.3f}ms {entry['p95Ms']:>8.3f}ms {entry['maxMs']:>8.3f}ms")
    print()
    print("  not measured here (needs real clients):")
    for item in result.get("notMeasured", []):
        print(f"    - {item}")
    return 0


def cmd_engine(args: argparse.Namespace) -> int:
    """What the engine offers, so an agent does not have to guess."""
    engine = REPO_ROOT / "forge" / "luau" / "Forge"
    modules = []
    for child in sorted(engine.iterdir()):
        if child.is_dir() and (child / "init.lua").exists():
            source = (child / "init.lua").read_text(encoding="utf-8", errors="replace")
            functions = sorted(
                set(
                    line.split("function ")[1].split("(")[0].strip()
                    for line in source.splitlines()
                    if line.startswith("function ") and "." in line
                )
            )
            lines = len(source.splitlines())
            modules.append({"module": child.name, "lines": lines, "api": functions})

    if args.json:
        print(json.dumps(modules, indent=2))
        return 0

    for entry in modules:
        print(f"{entry['module']}  ({entry['lines']} lines)")
        for name in entry["api"]:
            print(f"    {name}")
        print()
    return 0


# =============================== the store ==================================
def cmd_toolbox(args: argparse.Namespace) -> int:
    """Harvest and curate Creator Store models through a live Studio."""
    from cli import toolbox

    if args.step in ("harvest", "all"):
        report = toolbox.harvest()
        print(f"\n{report['pieces']} pieces, {report['approved']} approved, "
              f"{report['carryingScripts']} carrying scripts (refused)")
        for pack in report["packs"]:
            if not pack.get("ok"):
                print(f"  pack {pack['pack']}: {pack.get('error')}")

    if args.step in ("curate", "all"):
        path, count = toolbox.curate(args.cap)
        print(f"curated {count} entries -> {path.relative_to(REPO_ROOT)}")
    return 0


# ============================ asset verification ============================
def cmd_assets(args: argparse.Namespace) -> int:
    """Load every asset id this project references and record the verdict."""
    from cli import assetcheck

    roots = [REPO_ROOT / "games", REPO_ROOT / "forge" / "luau"]
    refs = sorted(assetcheck.scan(roots))
    if not refs:
        print("no asset ids referenced")
        return 0

    if args.step == "scan":
        for ref in refs:
            print(" ", ref)
        print(f"{len(refs)} referenced")
        return 0

    registry = assetcheck.verify(refs)
    failed = [r for r, v in registry["assets"].items() if not v.get("ok")]
    print(f"\n{registry['passing']}/{registry['count']} load")
    for ref in failed:
        print(f"  FAILS  {ref}")
    return 1 if failed else 0


# ============================== pose preview ================================
def cmd_pose(args: argparse.Namespace) -> int:
    """Pose a rig from a clip in the open place and report the result."""
    from cli import pose

    report = pose.preview(args.clip, samples=args.samples, duration=args.duration,
                          rig_type=args.rig)
    print(pose.render(report))
    return 1 if report.get("error") else 0


# ============================== scene round trip ============================
def cmd_scene(args: argparse.Namespace) -> int:
    """Move a scene between a live session and the repository."""
    from cli import scene as scenes

    try:
        if args.step == "list":
            live = scenes.list_live()
            if live:
                for scene_name in live:
                    print("  " + scene_name)
            else:
                print("the session has published no scenes")
            return 0
        if args.step == "pull":
            written = scenes.pull(args.game, args.name)
            print(f"{len(written)} scene(s) pulled")
            return 0
        result = scenes.push(args.game, args.name)
        print(f"pushed {result.get('name')} ({result.get('placements')} placements)")
        return 0
    except scenes.BridgeError as exc:
        print(f"scene: {exc}")
        return 1


# ============================== live gameplay ===============================
def cmd_gametest(args: argparse.Namespace) -> int:
    """Run the game's own scenarios inside the open Studio session."""
    from cli import gametest

    try:
        report = gametest.run(args.filter)
    except gametest.BridgeError as exc:
        print(f"gametest: {exc}")
        return 1
    print(gametest.render(report))
    return 0 if report.get("ok") else 1


# ============================== api index ===================================
def cmd_api(args: argparse.Namespace) -> int:
    """Describe the engine as JSON, or print one module's surface."""
    from cli import apiindex

    if args.module:
        print(apiindex.render_module(args.module))
        return 0
    path, data = apiindex.write()
    print(f"{data['modules']} modules, {data['functions']} public functions "
          f"-> {path.relative_to(REPO_ROOT)}")
    return 0


# ================================ publishing ================================
def cmd_publish(args: argparse.Namespace) -> int:
    """Upload the built place as a new version of a Roblox experience."""
    from cli import publish as pub

    try:
        if args.check:
            result = pub.check_key()
            print(f"key: {'authenticates' if result['ok'] else 'rejected'} "
                  f"(HTTP {result['status']}) -- {result['meaning']}")
            return 0 if result["ok"] else 1

        result = pub.publish(args.game, release=args.release,
                             universe_id=args.universe, place_id=args.place)
    except pub.PublishError as exc:
        print(f"publish: {exc}")
        return 1

    if result.get("ok"):
        print(f"{result['versionType']} version {result.get('versionNumber')} "
              f"({result['bytes']} bytes)")
        if result["versionType"] == "Saved":
            print("  saved to version history; live servers are untouched")
        return 0
    print(f"publish: HTTP {result['status']} -- {result.get('hint')}")
    print(f"  {result.get('body')}")
    return 1


# ============================== runnable examples ===========================
def cmd_example(args: argparse.Namespace) -> int:
    """Run the engine's own examples inside Studio."""
    from cli import example as ex

    try:
        report = ex.run(args.module)
    except ex.BridgeError as exc:
        print(f"example: {exc}")
        return 1
    print(ex.render(report))
    if report.get("error"):
        return 1
    return 0 if report.get("ok", True) else 1


# ================================ asset upload ==============================
def cmd_upload(args: argparse.Namespace) -> int:
    """Upload a local file to Roblox and register the id it comes back with."""
    from cli import upload as up

    try:
        record = up.upload(Path(args.path), args.user, name=args.name,
                           declared_type=args.type, wait=args.wait)
    except up.UploadError as exc:
        print(f"upload: {exc}")
        return 1

    print(f"{record['reference']}  ({record['moderation']})")
    if record["moderation"] == "Approved":
        registry = up.register(record["reference"], record)
        print(f"  registered in {registry.relative_to(REPO_ROOT)}")
    else:
        print("  not registered: only an approved asset may pass the doctor")
    return 0


# ============================== quality and sight ===========================
def cmd_quality(args: argparse.Namespace) -> int:
    """Run the Quality Engine against a Forge game.

    The two halves of this repository, finally pointed at each other. Forge
    proves a game works; the RQE measures whether it is any good, and until
    now neither knew the other existed.
    """
    from cli import quality

    try:
        descriptor, contract = quality.generate(args.game)
    except quality.QualityError as exc:
        raise SystemExit(f"forge: {exc}")

    print(f"  {descriptor.relative_to(REPO_ROOT)}")
    print(f"  {contract.relative_to(REPO_ROOT)}  "
          f"({len(quality.forge_requirements(args.game))} requirements)")

    if args.generate:
        print()
        print("  the bar is a decision, not a derivation. edit the contract, "
              "then run `forge quality` without --generate.")
        return 0

    print()
    result = quality.audit(args.game, static_only=args.static_only)
    print(quality.render(result))
    return 0 if result["exit"] == 0 else 1


def cmd_look(args: argparse.Namespace) -> int:
    """Photograph the game, so the agent can see what it built.

    Every visual defect in this project was found by a person looking at a
    screen and none of them by a test. This is the agent doing the looking.
    """
    from cli import look

    try:
        if args.tour:
            shots = look.tour()
        else:
            if args.at:
                point = tuple(float(value) for value in args.at.split(","))
                if len(point) != 3:
                    raise SystemExit("forge: --at wants x,y,z")
                look.aim(point, args.distance, args.height)  # type: ignore[arg-type]
            shots = [look.shoot(args.name)]
    except look.LookError as exc:
        raise SystemExit(f"forge: {exc}")

    for shot in shots:
        print(f"  {shot.relative_to(REPO_ROOT)}  ({shot.stat().st_size:,} bytes)")
    return 0 if shots else 1


def cmd_analytics(args: argparse.Namespace) -> int:
    """Read the telemetry back out of the DataStore it was written into."""
    from cli import analytics
    from cli import publish as pub

    try:
        fetched = analytics.fetch(args.game, days=args.days)
    except (analytics.AnalyticsError, pub.PublishError) as exc:
        raise SystemExit(f"forge: {exc}")

    if args.raw:
        print(json.dumps(fetched["events"], indent=2, ensure_ascii=False))
        return 0

    summary = analytics.summarise(fetched)
    if args.json:
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return 0
    print(analytics.render(summary))
    return 0


def cmd_traps(args: argparse.Namespace) -> int:
    """The traps this engine knows about, as data rather than as folklore.

    Every one was paid for by a real failure in this project, and every one
    lived in a comment — where only a reader of that exact file ever finds it.
    Here an agent can ask before it writes instead of after it breaks.
    """
    catalogue = REPO_ROOT / "forge" / "catalog" / "traps.json"
    traps = json.loads(catalogue.read_text(encoding="utf-8"))["traps"]

    if args.module:
        traps = [trap for trap in traps if args.module in trap.get("modules", [])]
    if args.search:
        needle = args.search.lower()
        traps = [trap for trap in traps
                 if needle in json.dumps(trap, ensure_ascii=False).lower()]

    if args.json:
        print(json.dumps(traps, indent=2, ensure_ascii=False))
        return 0

    for trap in traps:
        print(f"{trap['id']}  [{trap['severity']}]  {', '.join(trap.get('modules', []))}")
        print(f"    symptom: {trap['symptom']}")
        print(f"    rule:    {trap['rule']}")
        print(f"    why:     {trap['why']}")
        print(f"    instead: {trap['instead']}")
        print()
    print(f"  {len(traps)} traps")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="forge", description="Forge — the authoring half")
    sub = parser.add_subparsers(dest="command", required=True)

    p_new = sub.add_parser("new", help="scaffold an empty project wired to the engine")
    p_new.add_argument("name")
    p_new.add_argument("--into", help="where to create it (default: games/)")
    p_new.add_argument("--vendor", action="store_true", help="copy the engine into the project")
    p_new.add_argument("--force", action="store_true")
    p_new.set_defaults(func=cmd_new)

    p_doc = sub.add_parser("doctor", help="authoring-time checks over a project's Luau")
    p_doc.add_argument("project")
    p_doc.add_argument("--json", action="store_true")
    p_doc.add_argument("--strict", action="store_true", help="exit non-zero on any error")
    p_doc.set_defaults(func=cmd_doctor)

    p_build = sub.add_parser("build", help="rojo build the project into a place file")
    p_build.add_argument("project")
    p_build.add_argument("--output")
    p_build.set_defaults(func=cmd_build)

    p_probe = sub.add_parser("probe", help="ask a running game to describe itself")
    p_probe.add_argument("--hub", default="http://127.0.0.1:8790")
    p_probe.add_argument("--path", default="ReplicatedStorage.ForgeDebug")
    p_probe.add_argument("--command", default="snapshot")
    p_probe.add_argument("--argument")
    p_probe.add_argument("--timeout", type=float, default=30)
    p_probe.set_defaults(func=cmd_probe)

    p_bench = sub.add_parser("bench", help="run the load suite inside a live session and print the numbers")
    p_bench.add_argument("--hub", default="http://127.0.0.1:8790")
    p_bench.add_argument("--entities", type=int, default=2000)
    p_bench.add_argument("--anchors", type=int, default=30)
    p_bench.add_argument("--timeout", type=float, default=120)
    p_bench.set_defaults(func=cmd_bench)

    p_toolbox = sub.add_parser("toolbox", help="harvest and curate Creator Store models")
    p_toolbox.add_argument("step", nargs="?", default="all",
                           choices=("harvest", "curate", "all"))
    p_toolbox.add_argument("--cap", type=int, default=200,
                           help="how many entries to curate (default 200)")
    p_toolbox.set_defaults(func=cmd_toolbox)

    p_assets = sub.add_parser("assets", help="verify every asset id by loading it in Studio")
    p_assets.add_argument("step", nargs="?", default="verify", choices=("scan", "verify"))
    p_assets.set_defaults(func=cmd_assets)

    p_pose = sub.add_parser("pose", help="preview an animation clip on a rig, in edit mode")
    p_pose.add_argument("clip")
    p_pose.add_argument("--samples", type=int, default=6)
    p_pose.add_argument("--duration", type=float, default=1.0)
    p_pose.add_argument("--rig", default="R15", choices=("R15", "R6"),
                        help="which rig to pose; R15 has elbows and knees")
    p_pose.set_defaults(func=cmd_pose)

    p_scene = sub.add_parser("scene", help="pull a scene out of a live session, or push one in")
    p_scene.add_argument("step", choices=("pull", "push", "list"))
    p_scene.add_argument("game", nargs="?", default="provingground")
    p_scene.add_argument("name", nargs="?", default=None)
    p_scene.set_defaults(func=cmd_scene)

    p_gt = sub.add_parser("gametest", help="run gameplay scenarios inside the live game")
    p_gt.add_argument("--filter", default=None, help="only scenarios whose name contains this")
    p_gt.set_defaults(func=cmd_gametest)

    p_api = sub.add_parser("api", help="write a machine-readable index of the engine")
    p_api.add_argument("--module", default=None, help="print one module instead")
    p_api.set_defaults(func=cmd_api)

    p_pub = sub.add_parser("publish", help="upload the built place to a Roblox experience")
    p_pub.add_argument("game", nargs="?", default="provingground")
    p_pub.add_argument("--universe", default=None)
    p_pub.add_argument("--place", default=None)
    p_pub.add_argument("--release", action="store_true",
                       help="push live to running servers instead of saving privately")
    p_pub.add_argument("--check", action="store_true", help="only test the credential")
    p_pub.set_defaults(func=cmd_publish)

    p_ex = sub.add_parser("example", help="run the engine's runnable examples")
    p_ex.add_argument("module", nargs="?", default=None)
    p_ex.set_defaults(func=cmd_example)

    p_up = sub.add_parser("upload", help="upload an image or sound and register its id")
    p_up.add_argument("path")
    p_up.add_argument("--user", required=True, help="the creator's Roblox user id")
    p_up.add_argument("--name", default=None)
    p_up.add_argument("--type", default=None, choices=("Image", "Audio"))
    p_up.add_argument("--wait", type=int, default=180, help="seconds to wait for moderation")
    p_up.set_defaults(func=cmd_upload)

    p_engine = sub.add_parser("engine", help="list the engine's modules and public API")
    p_engine.add_argument("--json", action="store_true")
    p_engine.set_defaults(func=cmd_engine)

    p_quality = sub.add_parser("quality", help="audit a game with the Quality Engine")
    p_quality.add_argument("game", nargs="?", default="provingground")
    p_quality.add_argument("--generate", action="store_true",
                           help="write the descriptor and contract without auditing")
    p_quality.add_argument("--static-only", action="store_true",
                           help="source evidence only; the release stays blocked")
    p_quality.set_defaults(func=cmd_quality)

    p_look = sub.add_parser("look", help="take a picture of the game in Studio")
    p_look.add_argument("--at", default=None, help="x,y,z to frame")
    p_look.add_argument("--distance", type=float, default=60)
    p_look.add_argument("--height", type=float, default=25)
    p_look.add_argument("--name", default="look")
    p_look.add_argument("--tour", action="store_true",
                        help="the standard viewpoints, so two runs are comparable")
    p_look.set_defaults(func=cmd_look)

    p_an = sub.add_parser("analytics", help="read the telemetry back out of the DataStore")
    p_an.add_argument("game", nargs="?", default="provingground")
    p_an.add_argument("--days", type=int, default=7)
    p_an.add_argument("--raw", action="store_true", help="the events, unaggregated")
    p_an.add_argument("--json", action="store_true")
    p_an.set_defaults(func=cmd_analytics)

    p_traps = sub.add_parser("traps", help="what breaks, and what to do instead")
    p_traps.add_argument("search", nargs="?", default=None)
    p_traps.add_argument("--module", default=None, help="only traps touching this module")
    p_traps.add_argument("--json", action="store_true")
    p_traps.set_defaults(func=cmd_traps)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
