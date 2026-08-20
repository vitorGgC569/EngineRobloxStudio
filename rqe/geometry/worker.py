"""The Blender worker: a headless modelling process the engine commands.

An LLM should not be building meshes vertex by vertex through text, and it
should not be limited to what Roblox Studio can assemble from parts. Blender has
a complete Python API and runs headless, so it becomes exactly what this
platform needs -- a modelling runtime that takes a program and returns geometry.

The agent never sees `bpy`. It sends a modelling *program* -- base box, bevel,
extrude the reactor, radial vents, pipes, supports, UV, materials, optimise --
and gets back an asset package with the mesh, renders from five angles, and a
topology analysis. `bpy` stays behind this boundary.

Three rules govern the process boundary:

**Every invocation is a fresh process.** Blender's global state is a
single-document application; reusing a process between builds means the second
build inherits whatever the first left behind. A cold `--background` start per
job costs a second and removes a whole class of irreproducible results.

**The script talks JSON over a file, not stdout.** Blender writes plugin
chatter, render progress and driver warnings to stdout, so parsing results out
of it is unreliable in a way that only shows up on someone else's machine.

**A missing Blender is BLOCKED, never a silent no-op.** It names the install and
the environment variable that fixes it.
"""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence


#: Lowest Blender that has the bmesh and glTF exporter behaviour this worker
#: relies on. Older builds fail in ways that look like modelling bugs.
MINIMUM_VERSION = (3, 6, 0)

#: Where Blender installs itself when nobody chose a directory. Ordered by how
#: likely they are, so the common case is found on the first stat.
_WINDOWS_CANDIDATES = (
    r"C:\Program Files\Blender Foundation\Blender {major}.{minor}\blender.exe",
    r"C:\Program Files\Blender Foundation\Blender\blender.exe",
    r"C:\Program Files (x86)\Steam\steamapps\common\Blender\blender.exe",
    r"C:\Program Files\Blender\blender.exe",
)
_POSIX_CANDIDATES = (
    "/usr/bin/blender",
    "/usr/local/bin/blender",
    "/snap/bin/blender",
    "/Applications/Blender.app/Contents/MacOS/Blender",
)

_VERSION = re.compile(r"Blender\s+(\d+)\.(\d+)(?:\.(\d+))?")


def _absolute(path: Path | str) -> Path:
    """Every path handed to Blender must be absolute.

    Measured: a relative output directory made Blender write renders to
    ``C:\\.tmp\\...`` -- the drive root, not the working directory. It reported
    success, the job returned the paths it was given, and the files were
    nowhere near them. Blender resolves relative paths against its own notion of
    a base, so the only safe convention is to never give it one.
    """

    return Path(path).expanduser().resolve()


class BlenderUnavailable(RuntimeError):
    """Blender could not be located or is too old."""


class WorkerError(RuntimeError):
    """Blender ran and the job failed."""


@dataclass(frozen=True)
class BlenderInstall:
    path: Path
    version: tuple[int, int, int]

    @property
    def version_string(self) -> str:
        return ".".join(str(part) for part in self.version)

    def to_dict(self) -> dict[str, Any]:
        return {"path": str(self.path), "version": self.version_string}


def _probe_version(executable: Path, timeout: float = 60.0) -> tuple[int, int, int] | None:
    try:
        process = subprocess.run(
            [str(executable), "--version"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    match = _VERSION.search(process.stdout or "")
    if match is None:
        return None
    major, minor, patch = match.group(1), match.group(2), match.group(3) or "0"
    return (int(major), int(minor), int(patch))


def _candidates() -> Iterable[Path]:
    override = os.environ.get("BLENDER_PATH")
    if override:
        yield Path(override)

    found = shutil.which("blender")
    if found:
        yield Path(found)

    if platform.system() == "Windows":
        base = Path(r"C:\Program Files\Blender Foundation")
        if base.is_dir():
            # Newest first: a machine with several versions should use the one
            # most likely to have the exporter behaviour this worker expects.
            for directory in sorted(base.iterdir(), reverse=True):
                executable = directory / "blender.exe"
                if executable.is_file():
                    yield executable
        for template in _WINDOWS_CANDIDATES:
            if "{major}" in template:
                continue
            yield Path(template)
    else:
        for candidate in _POSIX_CANDIDATES:
            yield Path(candidate)


def locate(*, minimum: tuple[int, int, int] = MINIMUM_VERSION) -> BlenderInstall:
    """Find a usable Blender, or say precisely why there is none."""

    seen: set[Path] = set()
    too_old: list[str] = []

    for candidate in _candidates():
        if candidate in seen:
            continue
        seen.add(candidate)
        if not candidate.is_file():
            continue
        version = _probe_version(candidate)
        if version is None:
            continue
        if version < minimum:
            too_old.append(f"{candidate} is {'.'.join(map(str, version))}")
            continue
        return BlenderInstall(path=candidate, version=version)

    detail = ""
    if too_old:
        detail = (
            " Found but too old: " + "; ".join(too_old)
            + f". This worker needs {'.'.join(map(str, minimum))} or newer."
        )
    raise BlenderUnavailable(
        "no usable Blender was found. Install Blender and either put it on PATH "
        "or set BLENDER_PATH to the executable." + detail
    )


def capabilities() -> dict[str, Any]:
    """What the geometry worker can do right now, and what blocks it."""

    try:
        install = locate()
    except BlenderUnavailable as exc:
        return {
            "backend": "blender",
            "available": False,
            "blockers": [str(exc)],
        }
    return {
        "backend": "blender",
        "available": True,
        "blockers": [],
        **install.to_dict(),
        "minimumVersion": ".".join(map(str, MINIMUM_VERSION)),
    }


@dataclass
class JobResult:
    """One Blender run: what it produced and everything it said."""

    ok: bool
    data: dict[str, Any] = field(default_factory=dict)
    error: str | None = None
    traceback: str | None = None
    stdout: str = ""
    stderr: str = ""
    exit_code: int = 0
    duration_seconds: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "error": self.error,
            "exitCode": self.exit_code,
            "durationSeconds": round(self.duration_seconds, 3),
            "data": self.data,
        }


#: Directory holding the Python this worker runs *inside* Blender.
SCRIPT_ROOT = Path(__file__).resolve().parent / "blender"


class GeometryWorker:
    """Drives `blender --background --python`."""

    def __init__(self, install: BlenderInstall | None = None, *, timeout: float = 300.0) -> None:
        self.install = install or locate()
        self.timeout = timeout

    # -- process ---------------------------------------------------------

    def run_script(
        self,
        script: Path,
        payload: dict[str, Any],
        *,
        blend_file: Path | None = None,
        timeout: float | None = None,
        extra_args: Sequence[str] = (),
    ) -> JobResult:
        """Execute one script inside Blender with a JSON payload."""

        import time

        script = Path(script)
        if not script.is_file():
            raise WorkerError(f"worker script not found: {script}")

        with tempfile.TemporaryDirectory(prefix="rqe-geometry-") as directory:
            workspace = Path(directory)
            input_path = workspace / "input.json"
            output_path = workspace / "output.json"
            input_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

            command: list[str] = [str(self.install.path), "--background"]
            if blend_file is not None:
                command.append(str(blend_file))
            # `--factory-startup` keeps a user's add-ons, themes and unit
            # preferences out of the build. Without it the same program produces
            # different geometry on two machines and nobody can say why.
            command += ["--factory-startup", "--python-exit-code", "1"]
            command += ["--python", str(script), "--"]
            command += [str(input_path), str(output_path)]
            command += list(extra_args)

            started = time.monotonic()
            try:
                process = subprocess.run(
                    command,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=timeout or self.timeout,
                )
            except subprocess.TimeoutExpired as exc:
                return JobResult(
                    ok=False,
                    error=f"Blender did not finish within {timeout or self.timeout}s",
                    stdout=(exc.stdout or b"").decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else (exc.stdout or ""),
                    exit_code=-1,
                    duration_seconds=time.monotonic() - started,
                )
            duration = time.monotonic() - started

            if not output_path.is_file():
                # No result file means the script died before it could report.
                # Blender's own stderr is the only evidence of why.
                return JobResult(
                    ok=False,
                    error="the worker script produced no result file",
                    stdout=process.stdout,
                    stderr=process.stderr,
                    exit_code=process.returncode,
                    duration_seconds=duration,
                )

            try:
                document = json.loads(output_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                return JobResult(
                    ok=False,
                    error=f"the worker script wrote invalid JSON: {exc}",
                    stdout=process.stdout,
                    stderr=process.stderr,
                    exit_code=process.returncode,
                    duration_seconds=duration,
                )

        if not isinstance(document, dict):
            return JobResult(ok=False, error="worker result was not an object", duration_seconds=duration)

        return JobResult(
            ok=bool(document.get("ok")),
            data=document.get("data") or {},
            error=document.get("error"),
            traceback=document.get("traceback"),
            stdout=process.stdout,
            stderr=process.stderr,
            exit_code=process.returncode,
            duration_seconds=duration,
        )

    # -- jobs ------------------------------------------------------------

    def build(self, program: dict[str, Any], output_dir: Path) -> JobResult:
        """Execute a modelling program and write an asset package."""

        output_dir = _absolute(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        return self.run_script(
            SCRIPT_ROOT / "build.py",
            {"program": program, "outputDir": str(output_dir)},
        )

    def analyse(self, mesh_path: Path) -> JobResult:
        """Load a mesh and report its topology."""

        return self.run_script(
            SCRIPT_ROOT / "analyse.py",
            {"meshPath": str(_absolute(mesh_path))},
        )

    def render(self, blend_path: Path, output_dir: Path, *, views: Sequence[str] = (), samples: int = 32) -> JobResult:
        """Render preview images from named viewpoints."""

        output_dir = _absolute(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        return self.run_script(
            SCRIPT_ROOT / "render.py",
            {
                "outputDir": str(output_dir),
                "views": list(views),
                "samples": samples,
            },
            blend_file=_absolute(blend_path),
        )
