"""Is this installation ready, and if not, what exactly is missing.

Why this exists
---------------

Nothing answered that question. `forge doctor` audits a game's Luau;
`rqe capabilities` audits the capability catalogue against the command
manifest. Neither looks at the machine the tools are about to run on.

So every missing piece was discovered the same way: by running a real command,
failing several frames into it, and reading an error written for a different
audience. A missing `numpy` surfaced as an ImportError inside a visual metric.
An uninstalled Studio plugin surfaced as "the bridge did not return JSON". A
key with the publish scope but not the DataStore scope surfaced as an empty
analytics report, which reads as *nobody played your game*.

Each check here answers three things in order, and the third is the one that
was always missing:

    what is it        so the reader knows what broke
    is it there       measured, never assumed
    how to get it     one command, copyable

A check that cannot run says so and does not pass. `forge preflight` exits
`ENVIRONMENT` when anything required is absent, which is the code that tells a
caller to stop and fix the machine rather than blame the game.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

REPO = Path(__file__).resolve().parents[2]


@dataclass
class Check:
    """One thing that has to be true, and what to do when it is not."""

    name: str
    what: str
    #: `required` failures are ENVIRONMENT. Optional ones are reported and do
    #: not fail the run: a machine with no Roblox Studio can still compile,
    #: test and audit, and refusing that would make preflight useless in CI.
    required: bool
    probe: Callable[[], tuple[bool, str]]
    fix: str

    def run(self) -> "Result":
        try:
            ok, detail = self.probe()
        except Exception as exc:  # noqa: BLE001 - a probe that crashes is a fail
            return Result(self, False, f"{type(exc).__name__}: {exc}")
        return Result(self, ok, detail)


@dataclass
class Result:
    check: Check
    ok: bool
    detail: str = ""

    @property
    def blocking(self) -> bool:
        return self.check.required and not self.ok

    def render(self) -> str:
        mark = "ok  " if self.ok else ("MISS" if self.check.required else "--  ")
        line = f"  {mark} {self.check.name:<18} {self.detail}"
        if not self.ok:
            line += f"\n       {self.check.what}\n       fix: {self.check.fix}"
        return line

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.check.name,
            "ok": self.ok,
            "required": self.check.required,
            "detail": self.detail,
            "what": self.check.what,
            "fix": self.check.fix,
        }


@dataclass
class Report:
    results: list[Result] = field(default_factory=list)

    @property
    def blocking(self) -> list[Result]:
        return [item for item in self.results if item.blocking]

    @property
    def ready(self) -> bool:
        return not self.blocking

    def to_dict(self) -> dict[str, Any]:
        return {
            "ready": self.ready,
            "platform": f"{platform.system()} {platform.release()}",
            "python": sys.version.split()[0],
            "checks": [item.to_dict() for item in self.results],
            "blocking": [item.check.name for item in self.blocking],
        }

    def render(self) -> str:
        out = [
            "forge preflight",
            f"  {platform.system()} {platform.release()}  |  Python {sys.version.split()[0]}",
            "",
        ]
        out += [item.render() for item in self.results]
        out.append("")
        if self.ready:
            out.append("  ready.")
            optional = [item for item in self.results
                        if not item.ok and not item.check.required]
            if optional:
                out.append(f"  {len(optional)} optional piece(s) absent: "
                           + ", ".join(item.check.name for item in optional))
                out.append("  everything that does not need a live Studio will run.")
        else:
            out.append(f"  NOT ready: {len(self.blocking)} required piece(s) missing.")
            out.append("  fix those, then run this again.")
        return "\n".join(out)


# --------------------------------------------------------------------- probes


def _python_version() -> tuple[bool, str]:
    major, minor = sys.version_info[:2]
    return (major, minor) >= (3, 11), f"{major}.{minor}"


def _module(name: str) -> Callable[[], tuple[bool, str]]:
    def probe() -> tuple[bool, str]:
        try:
            module = __import__(name)
        except ImportError as exc:
            return False, str(exc)
        return True, getattr(module, "__version__", "present")

    return probe


def _rojo() -> tuple[bool, str]:
    found = shutil.which("rojo")
    if not found:
        return False, "not on PATH"
    try:
        out = subprocess.run([found, "--version"], capture_output=True,
                             text=True, timeout=20)
    except Exception as exc:  # noqa: BLE001
        return False, f"{found} would not run: {exc}"
    #: `--version` has to exit 0. The code used to be discarded, so a binary
    #: that started and then failed still counted as a working Rojo.
    if out.returncode != 0:
        snippet = (out.stderr or out.stdout or "").strip()[:40]
        detail = f"exit {out.returncode}"
        if snippet:
            detail = f"{detail}: {snippet}"
        return False, detail
    return True, (out.stdout or out.stderr or "").strip()[:40]


def _luau() -> tuple[bool, str]:
    """The compiler is present only if it can compile.

    A file at the compiler path used to count, and the detail printed the
    constant `LUAU_VERSION` without the binary ever starting. `return 1` is
    the smallest source that has to compile for the toolchain to be usable.
    """

    sys.path.insert(0, str(REPO))
    from rqe.luau_check import compile_file, compiler_path

    path = compiler_path(REPO)
    if not path.is_file():
        return False, f"absent at {path.relative_to(REPO)}"
    descriptor, name = tempfile.mkstemp(suffix=".lua")
    source = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write("return 1\n")
        try:
            failure = compile_file(path, source)
        except Exception as exc:  # noqa: BLE001 - a binary that will not start is a miss
            return False, f"compiler would not run: {exc}"
    finally:
        source.unlink(missing_ok=True)
    if failure is not None:
        return False, failure.message
    return True, "compiler ran"


def _runtime() -> tuple[bool, str]:
    """The headless runtime is present only if it can execute.

    A file at the runtime path used to count as luau.exe. This starts that
    binary on `return 1` with the same argv the harness uses, `luau <script>`,
    and does not load the SDK through `luau_harness.run`.
    """

    sys.path.insert(0, str(REPO))
    from rqe.luau_harness import runtime_path

    path = runtime_path(REPO)
    if not path.is_file():
        return False, f"absent at {path.relative_to(REPO)}"
    descriptor, name = tempfile.mkstemp(suffix=".luau")
    source = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write("return 1\n")
        try:
            # Same invocation as rqe.luau_harness.run: the runtime, then the
            # script. A one-line probe does not get the harness's 60s SDK budget.
            out = subprocess.run(
                [str(path), str(source)],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=20,
            )
        except Exception as exc:  # noqa: BLE001 - spawn and timeout are both a miss
            return False, f"runtime would not run: {exc}"
    finally:
        source.unlink(missing_ok=True)
    if out.returncode != 0:
        snippet = (out.stderr or out.stdout or "").strip()[:40]
        detail = f"exit {out.returncode}"
        if snippet:
            detail = f"{detail}: {snippet}"
        return False, detail
    return True, "runtime ran"


def _hub_address() -> tuple[str, int]:
    """Host and port of this workspace's hub, resolved when the check runs.

    A second checkout sets `RQE_HUB_PORT` or `RQE_HUB_URL` and the hub binds
    there. `hub_url()` is the same resolution `serve` uses, so the probe
    measures the process this workspace will talk to. A fixed port measures
    whichever other process still occupies 8790.
    """

    from urllib.parse import urlsplit

    sys.path.insert(0, str(REPO))
    from rqe.security import validate_hub_url
    from rqe.workspace import hub_url

    parsed = urlsplit(validate_hub_url(hub_url()))
    if parsed.hostname is None or parsed.port is None:
        raise ValueError(f"hub URL has no endpoint: {parsed.geturl()}")
    return parsed.hostname, parsed.port


def _hub() -> tuple[bool, str]:
    """Is anything answering on this workspace's bridge port.

    A socket probe rather than an HTTP round trip: this must be fast and must
    not need the hub to be healthy, only to exist. Whether it *works* is
    `bridge.ping`'s question, and asking it here would make preflight depend on
    the thing it is checking.
    """

    host, port = _hub_address()
    where = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
    try:
        candidates = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        return False, f"cannot resolve {where}: {exc}"
    for family, socktype, proto, _canon, sockaddr in candidates:
        try:
            with socket.socket(family, socktype, proto) as probe:
                probe.settimeout(0.6)
                if probe.connect_ex(sockaddr) == 0:
                    return True, f"answering on {where}"
        except OSError:
            continue
    return False, f"nothing on {where}"


def _plugin() -> tuple[bool, str]:
    """Is the bridge plugin installed where Studio will load it from.

    Studio loads every file in the plugins folder. The file the installer
    writes is `PLUGIN_FILENAME`. A different file whose name contains "RQE"
    used to pass this check, and a second copy with the same stem — the
    `.rbxm` an older install leaves behind — answers commands first.
    """

    if platform.system() != "Windows":
        return False, "Studio plugins are a Windows path on this platform"
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        return False, "LOCALAPPDATA is not set"
    plugins = Path(local) / "Roblox" / "Plugins"
    if not plugins.is_dir():
        return False, f"no plugin directory at {plugins}"

    sys.path.insert(0, str(REPO))
    from rqe.hub.install import PLUGIN_FILENAME

    installed = plugins / PLUGIN_FILENAME
    if not installed.is_file():
        return False, f"absent at {installed}"
    if installed.stat().st_size < 1:
        return False, f"{PLUGIN_FILENAME} is empty"
    rivals = sorted(
        path.name
        for path in plugins.iterdir()
        if path.is_file() and path != installed and path.stem.lower() == installed.stem.lower()
    )
    if rivals:
        return False, "competing copy: " + ", ".join(rivals)
    return True, installed.name


def _studio() -> tuple[bool, str]:
    if platform.system() != "Windows":
        return False, "not this platform"
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq RobloxStudioBeta.exe"],
            capture_output=True, text=True, timeout=20)
        running = "RobloxStudio" in out.stdout
        return running, "running" if running else "not running"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def _credential() -> tuple[bool, str]:
    sys.path.insert(0, str(REPO))
    try:
        from forge.cli import publish
        key = publish.load_key()
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)[:80]
    #: Length only. Printing any part of a credential into a report that people
    #: paste into issues is how a key leaves the machine.
    return bool(key), f"{len(key)} characters" if key else "absent"


def _stamps() -> tuple[bool, str]:
    sys.path.insert(0, str(REPO))
    from rqe.stamps import drifted, verify

    bad = drifted(verify(REPO))
    if bad:
        return False, f"{len(bad)} drifted: " + ", ".join(item.stamp.name for item in bad)
    return True, "all match"


def checks() -> list[Check]:
    """Everything preflight knows how to look at, required first."""

    return [
        Check("python", "Python 3.11 or newer", True, _python_version,
              "install Python 3.11+"),
        Check("pillow", "image measurement needs Pillow", True, _module("PIL"),
              "pip install -e ."),
        Check("numpy", "the visual metrics need numpy", True, _module("numpy"),
              "pip install -e ."),
        Check("luau-compile", "the pinned Luau compiler; every static check "
                              "runs through it", True, _luau,
              "python -m rqe.luau_check --bootstrap"),
        Check("luau-runtime", "the headless runtime that executes engine "
                              "modules outside Roblox", True, _runtime,
              "python -m rqe.luau_check --bootstrap"),
        Check("stamps", "derived hashes in checked-in files match their "
                        "sources", True, _stamps,
              "python rqe.py stamp --write, then review the diff"),
        Check("rojo", "builds source into a .rbxlx place file", True, _rojo,
              "install Rojo from https://rojo.space"),

        # Optional: everything below needs a live machine with Studio on it.
        # A CI runner has none of them and is still a working installation.
        Check("studio", "Roblox Studio, for anything that runs a game", False,
              _studio, "open Roblox Studio, or `rqe studio restart`"),
        Check("plugin", "the bridge plugin Studio loads to accept commands",
              False, _plugin, "python rqe.py studio install"),
        Check("hub", "the local bridge every live command talks to", False,
              _hub, "python rqe.py studio serve"),
        Check("credential", "an Open Cloud key, for publishing and analytics",
              False, _credential,
              "put the key in .secrets/ (see forge/cli/publish.py)"),
    ]


def run() -> Report:
    return Report(results=[check.run() for check in checks()])


def main(as_json: bool = False) -> int:
    from rqe.exits import ENVIRONMENT, OK

    report = run()
    if as_json:
        print(json.dumps(report.to_dict(), indent=2))
    else:
        print(report.render())
    return OK if report.ready else ENVIRONMENT
