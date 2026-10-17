"""Shared helpers for the suite. Chiefly: copying the repository cheaply.

Why this exists
---------------

Four tests began with `shutil.copytree(ROOT, temp_root)` where `ROOT` is the
repository root, so each of them copied **34 GB across 8,500 files** to change
one line of one JSON manifest:

    assets/itch      29 GB   downloaded itch.io packs (gitignored)
    assets/itch-ui    4.5 GB  downloaded UI packs
    forge/kits       251 MB   third-party salvage
    artifacts        235 MB   published evidence from earlier runs
    .tmp             225 MB   scratch captures
    tools/*/target   149 MB   a Rust build directory
    .git              89 MB

Thirty-four gigabytes, copied three times, to edit one field of one JSON file.
The measurement is unambiguous: 27 seconds of copying against **0.3 seconds** of
the audit those tests exist to run.

The whole suite took twelve minutes, so nobody ran it in the working loop -- and
that is exactly how six genuinely failing tests and a capability catalogue that
had drifted sat unnoticed for twenty-five commits.

A slow suite is not an inconvenience. It is a gate that stops being a gate.

What is left out, and why that is safe
--------------------------------------

Only directories an audit provably never reads: version control, the downloaded
toolchain, scratch output, published artifacts, third-party kit salvage, and
Python caches. Everything an audit *does* read -- `src/`, `assets/`,
`contracts/`, `schemas/`, `quality/`, `tokens/`, `forge/luau/`, `roblox/lib/` --
is copied verbatim.

If that list is ever wrong the tests fail loudly with a missing file, which is
the right failure: a fixture that quietly lacks what it needs is how a test
passes for the wrong reason.
"""

from __future__ import annotations

import shutil
from pathlib import Path

#: Directory names never read by anything under test.
#:
#: Matched by name at any depth, which is why `__pycache__` and `node_modules`
#: appear once rather than per location.
NEVER_READ = frozenset({
    ".git",
    ".tools",        # the downloaded Luau toolchain: re-derivable
    ".tmp",          # scratch captures and probe scripts
    ".venv", "venv",
    "__pycache__",
    ".pytest_cache",
    "node_modules",
    "target",        # a Rust build directory under tools/
    "artifacts",     # published evidence from previous runs
    "kits",          # third-party salvage under forge/
    "corpus",
    "reports",
})

#: Repository-relative directories left out by path rather than by name.
#:
#: `assets/` cannot go wholesale: `assets/asset-manifest.json` is the file two
#: of these tests edit, and `assets/generated/` holds authored art a probe
#: measures. What can go is the 33 GB of downloaded packs beneath it, which are
#: gitignored precisely because they are re-fetchable rather than authored.
NEVER_READ_PATHS = frozenset({
    "assets/itch",
    "assets/itch-ui",
})


def _ignore_for(source: Path):
    """An `ignore` callable that knows where it started, so paths can match."""

    root = source.resolve()

    def ignore(directory: str, names: list[str]) -> set[str]:
        skipped = {name for name in names if name in NEVER_READ}
        here = Path(directory).resolve()
        for name in names:
            try:
                relative = (here / name).relative_to(root).as_posix()
            except ValueError:
                continue
            if relative in NEVER_READ_PATHS:
                skipped.add(name)
        return skipped

    return ignore


def copy_project(source: Path, destination: Path) -> Path:
    """A working copy of a project or of the repository, without the ballast.

    Use this instead of `shutil.copytree` anywhere a test needs a mutable
    checkout. Measured on this repository, per call:

        shutil.copytree   34 GB   8,500 files   27.1 s
        copy_project      79 MB   2,076 files    1.8 s
    """

    shutil.copytree(source, destination, ignore=_ignore_for(source))
    return destination
