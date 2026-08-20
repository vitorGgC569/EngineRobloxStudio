"""Project scaffolding.

What this creates is a skeleton: bootstrap wiring, a config file, an empty
systems folder and a Rojo project that points at the engine. It contains no
gameplay, no genre and no example loop, and that is the entire point. A
scaffold that ships a working tycoon is not a scaffold, it is a ceiling.
"""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "templates" / "game"
ENGINE_DIR = Path(__file__).resolve().parent.parent / "luau" / "Forge"

_SAFE_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{0,48}$")


def _substitute(text: str, values: dict[str, str]) -> str:
    for key, value in values.items():
        text = text.replace("{{" + key + "}}", value)
    return text


def _relative_engine_path(destination: Path) -> str:
    """Prefer a relative reference so one engine serves every game in the repo.

    Games created outside the repository get the engine vendored instead,
    because a relative path that escapes the project directory is fragile the
    moment the folder is moved or zipped.
    """
    try:
        relative = os.path.relpath(ENGINE_DIR, destination)
    except ValueError:  # different drive on Windows
        return ""
    if relative.count("..") > 3:
        return ""
    return relative.replace("\\", "/")


def create(name: str, destination: Path, *, vendor: bool = False, force: bool = False) -> Path:
    if not _SAFE_NAME.match(name):
        raise ValueError(
            f"'{name}' is not a usable project name: start with a letter, then letters, digits, _ or -"
        )
    if not TEMPLATE_DIR.exists():
        raise FileNotFoundError(f"template missing at {TEMPLATE_DIR}")

    root = destination / name
    if root.exists():
        if not force:
            raise FileExistsError(f"{root} already exists (pass --force to overwrite)")

        # `--force` used to mean "write over whatever is here", and it once
        # overwrote a real project that happened to share a name. A scaffold
        # that can eat someone's game is a defect, not a convenience.
        #
        # So --force now only overwrites a directory this scaffold produced.
        # Anything else has to be moved or deleted deliberately, by a human.
        marker = root / ".forge-project"
        looks_foreign = any(root.iterdir()) and not marker.exists()
        if looks_foreign:
            existing = sorted(p.name for p in root.iterdir())[:8]
            raise FileExistsError(
                f"{root} already exists and was not created by forge "
                f"(found: {', '.join(existing)}). "
                "Refusing to overwrite it. Choose another name, or move that "
                "directory yourself first."
            )
    root.mkdir(parents=True, exist_ok=True)

    engine_path = "" if vendor else _relative_engine_path(root)
    if not engine_path:
        vendor = True
        engine_path = "vendor/Forge"

    values = {"NAME": name, "FORGE_PATH": engine_path}

    for source in sorted(TEMPLATE_DIR.rglob("*")):
        if source.is_dir():
            continue
        relative = source.relative_to(TEMPLATE_DIR)
        target = root / relative
        if target.suffix == ".tmpl":
            target = target.with_suffix("")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            _substitute(source.read_text(encoding="utf-8"), values),
            encoding="utf-8",
        )

    if vendor:
        vendor_target = root / "vendor" / "Forge"
        if vendor_target.exists():
            shutil.rmtree(vendor_target)
        vendor_target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(ENGINE_DIR, vendor_target)

    (root / "src" / "server" / "systems").mkdir(parents=True, exist_ok=True)
    (root / "src" / "client" / "ui").mkdir(parents=True, exist_ok=True)
    (root / ".gitignore").write_text("*.rbxlx\n*.rbxl\n*.lock\n.tmp/\n", encoding="utf-8")
    # Marks the directory as forge-owned, so a later --force knows it may
    # overwrite here and nowhere else.
    (root / ".forge-project").write_text(name + "\n", encoding="utf-8")

    readme = root / "README.md"
    readme.write_text(
        f"""# {name}

Built on Forge. The engine is a library you write against, not a generator that
writes for you — there is no gameplay in this folder yet, by design.

## Rodar

```bash
rojo build default.project.json --output {name}.rbxlx
```

Abra o `.rbxlx` no Studio, ou use `rojo serve` com o plugin do Rojo para sync ao vivo.

## Onde escrever

- `src/server/systems/` — um módulo por sistema, cada um com `start()`
- `src/client/ui/` — interface
- `src/shared/Config.lua` — todo número ajustável

## Checar antes de rodar

```bash
python forge/forge.py doctor {name}
```
""",
        encoding="utf-8",
    )

    return root
