from __future__ import annotations

import json
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCRIPT_CLASSES = {"ModuleScript", "Script", "LocalScript"}


@dataclass(frozen=True)
class SourceBinding:
    source: Path
    data_model_path: str
    class_name: str

    @property
    def kind(self) -> str:
        if self.class_name == "ModuleScript":
            return "module"
        if self.class_name == "LocalScript":
            return "client"
        if self.class_name == "Script":
            return "server"
        raise ValueError(f"unsupported script class: {self.class_name}")


def generate(project_file: Path) -> dict[str, Any]:
    """Ask Rojo for the authoritative source→DataModel mapping."""
    project_file = project_file.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="rqe-rojo-sourcemap-") as raw:
        output = Path(raw) / "sourcemap.json"
        completed = subprocess.run(
            ["rojo", "sourcemap", str(project_file), "--output", str(output)],
            cwd=project_file.parent,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                "rojo sourcemap failed: "
                + (completed.stderr.strip() or completed.stdout.strip())
            )
        try:
            return json.loads(output.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"rojo sourcemap was unreadable: {exc}") from exc


def bindings(project_file: Path, payload: dict[str, Any] | None = None) -> dict[Path, SourceBinding]:
    """Flatten a Rojo sourcemap into absolute source-file bindings."""
    project_file = project_file.resolve(strict=True)
    project_dir = project_file.parent
    tree = payload if payload is not None else generate(project_file)
    found: dict[Path, SourceBinding] = {}

    def walk(node: dict[str, Any], parents: tuple[str, ...]) -> None:
        name = str(node.get("name") or "")
        class_name = str(node.get("className") or "")
        current = parents
        if class_name != "DataModel" and name:
            current = (*parents, name)

        if class_name in SCRIPT_CLASSES:
            dm_path = ".".join(current)
            for raw_path in node.get("filePaths") or []:
                source = (project_dir / str(raw_path)).resolve()
                if source.suffix.lower() not in {".lua", ".luau"}:
                    continue
                found[source] = SourceBinding(
                    source=source,
                    data_model_path=dm_path,
                    class_name=class_name,
                )

        for child in node.get("children") or []:
            if isinstance(child, dict):
                walk(child, current)

    walk(tree, ())
    return found


def classify(
    changed: list[str | Path],
    source_bindings: dict[Path, SourceBinding],
) -> tuple[list[SourceBinding], list[Path]]:
    """Return (hot-reloadable scripts, changes requiring a cold place reload)."""
    hot: list[SourceBinding] = []
    cold: list[Path] = []
    seen: set[Path] = set()

    for raw in changed:
        path = Path(raw).resolve()
        if path in seen:
            continue
        seen.add(path)

        binding = source_bindings.get(path)
        if (
            path.exists()
            and path.suffix.lower() in {".lua", ".luau"}
            and binding is not None
            and binding.class_name in SCRIPT_CLASSES
        ):
            hot.append(binding)
        else:
            cold.append(path)

    hot.sort(key=lambda item: (item.data_model_path, str(item.source)))
    cold.sort(key=str)
    return hot, cold


def apply(bridge: Any, scripts: list[SourceBinding]) -> list[dict[str, Any]]:
    """Synchronize changed scripts into the edit DataModel through native editor APIs."""
    if not scripts:
        return []

    session = bridge.pin_to_context("edit", timeout=15)
    receipts: list[dict[str, Any]] = []
    sources = [
        (binding, binding.source.read_text(encoding="utf-8"))
        for binding in scripts
    ]

    with bridge.lease_scope(
        agent_id="forge-watch-hot-reload",
        session_id=session,
        context="edit",
        ttl_seconds=120.0,
    ):
        # Compile the whole batch before mutating anything. A syntax error in
        # the third file must not leave files one and two live in Studio while
        # the repository still represents one atomic save.
        for binding, source in sources:
            compiled = bridge.call(
                "code.compile",
                {
                    "source": source,
                    "chunkName": str(binding.source),
                },
                timeout=20,
            )
            if compiled.get("compiles") is not True:
                raise RuntimeError(
                    f"{binding.source} does not compile: "
                    f"{compiled.get('error') or 'unknown Luau error'}"
                )

        for binding, source in sources:
            method = "code.reload" if binding.class_name == "ModuleScript" else "code.write"
            params: dict[str, Any] = {
                "path": binding.data_model_path,
                "source": source,
            }
            if method == "code.write":
                params["kind"] = binding.kind

            result = bridge.call(method, params, timeout=30)
            receipts.append({
                "source": str(binding.source),
                "path": binding.data_model_path,
                "className": binding.class_name,
                "method": method,
                "result": result,
            })
    return receipts
