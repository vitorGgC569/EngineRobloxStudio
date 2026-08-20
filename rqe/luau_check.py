"""Compile every Luau file in the repository, or refuse to proceed.

Rojo packages files; it does not parse them. A place can therefore build cleanly
from source that never compiles, and the failure only surfaces when a script
silently does not run inside Studio -- which is exactly how a HUD once shipped
with zero buttons and no server-side error to show for it.

This module owns the pinned toolchain and the check. It fails closed: a missing
compiler is a blocked check, never a passed one.
"""

from __future__ import annotations

import io
import os
import platform
import shutil
import stat
import subprocess
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


#: Pinned so a toolchain upgrade is a reviewed change rather than a surprise on
#: whichever machine happens to run the suite next.
LUAU_VERSION = "0.733"
LUAU_RELEASE_URL = "https://github.com/luau-lang/luau/releases/download/{version}/luau-{platform}.zip"

_PLATFORM_ASSET = {"Windows": "windows", "Linux": "ubuntu", "Darwin": "macos"}


class ToolchainUnavailable(RuntimeError):
    """The compiler is not present and could not be fetched."""


@dataclass(frozen=True)
class CompileFailure:
    path: Path
    message: str

    def __str__(self) -> str:
        return f"{self.path}: {self.message}"


def toolchain_dir(root: Path) -> Path:
    return Path(root) / ".tools" / "luau"


def _executable_name(stem: str) -> str:
    return f"{stem}.exe" if os.name == "nt" else stem


def compiler_path(root: Path) -> Path:
    return toolchain_dir(root) / _executable_name("luau-compile")


def analyzer_path(root: Path) -> Path:
    return toolchain_dir(root) / _executable_name("luau-analyze")


def bootstrap(root: Path, *, version: str = LUAU_VERSION, timeout: float = 180.0) -> Path:
    """Download and unpack the pinned Luau toolchain into `.tools/luau`."""

    system = platform.system()
    asset = _PLATFORM_ASSET.get(system)
    if asset is None:
        raise ToolchainUnavailable(f"no pinned Luau build for platform {system!r}")

    target = toolchain_dir(root)
    target.mkdir(parents=True, exist_ok=True)
    url = LUAU_RELEASE_URL.format(version=version, platform=asset)
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            payload = response.read()
    except Exception as exc:  # pragma: no cover - network dependent
        raise ToolchainUnavailable(f"could not download {url}: {exc}") from exc

    wanted = {_executable_name("luau-compile"), _executable_name("luau-analyze")}
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        for member in archive.namelist():
            name = Path(member).name
            if name in wanted:
                with archive.open(member) as source, (target / name).open("wb") as sink:
                    shutil.copyfileobj(source, sink)

    compiler = compiler_path(root)
    if not compiler.is_file():
        raise ToolchainUnavailable(f"{url} did not contain a Luau compiler")
    for path in (compiler, analyzer_path(root)):
        if path.is_file():
            path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return compiler


def ensure_compiler(root: Path, *, allow_download: bool = True) -> Path:
    compiler = compiler_path(root)
    if compiler.is_file():
        return compiler
    if not allow_download:
        raise ToolchainUnavailable(
            f"Luau compiler missing at {compiler}; run `python -m rqe.luau_check --bootstrap`"
        )
    return bootstrap(root)


#: Directories that hold Luau the engine is responsible for. Deliberately
#: explicit: a glob over the whole tree would also compile whatever a user
#: dropped in a scratch folder and turn an unrelated file into a release blocker.
DEFAULT_SOURCE_ROOTS = (
    "roblox/lib",
    "roblox/mvp/src",
    "roblox/runtime",
    "apps/studio-plugin/src",
    "sdk",
)


def discover(root: Path, source_roots: Iterable[str] = DEFAULT_SOURCE_ROOTS) -> list[Path]:
    root = Path(root)
    found: list[Path] = []
    for relative in source_roots:
        base = root / relative
        if not base.exists():
            continue
        # `.lua.disabled` is how this repository retires a script without
        # deleting it. Retired code is not required to compile.
        found.extend(sorted(path for path in base.rglob("*.lua") if path.is_file()))
        found.extend(sorted(path for path in base.rglob("*.luau") if path.is_file()))
    return found


def compile_file(compiler: Path, path: Path, *, timeout: float = 30.0) -> CompileFailure | None:
    # Bytecode goes to stdout and must be discarded rather than captured: it is
    # binary, and decoding it as text raises before any diagnostic is read.
    process = subprocess.run(
        [str(compiler), "--binary", str(path)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    # A clean compile leaves stderr empty regardless of exit-code conventions.
    message = process.stderr.decode("utf-8", errors="replace").strip()
    if message:
        return CompileFailure(path, message.splitlines()[0])
    if process.returncode != 0:
        return CompileFailure(path, f"compiler exited {process.returncode}")
    return None


def check_all(
    root: Path,
    *,
    source_roots: Iterable[str] = DEFAULT_SOURCE_ROOTS,
    allow_download: bool = True,
) -> list[CompileFailure]:
    """Compile every discovered Luau file and return the failures."""

    compiler = ensure_compiler(Path(root), allow_download=allow_download)
    failures: list[CompileFailure] = []
    for path in discover(root, source_roots):
        failure = compile_file(compiler, path)
        if failure is not None:
            failures.append(failure)
    return failures


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - CLI
    import argparse

    parser = argparse.ArgumentParser(description="Compile every Luau source file.")
    parser.add_argument("--root", default=".", help="repository root")
    parser.add_argument("--bootstrap", action="store_true", help="download the toolchain and exit")
    arguments = parser.parse_args(argv)

    root = Path(arguments.root).resolve()
    if arguments.bootstrap:
        print(f"installed {bootstrap(root)}")
        return 0

    failures = check_all(root)
    sources = discover(root)
    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        print(f"\n{len(failures)} of {len(sources)} Luau files failed to compile")
        return 1
    print(f"{len(sources)} Luau files compiled")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
