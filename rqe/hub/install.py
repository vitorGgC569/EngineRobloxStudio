"""Build and install the Studio Bridge plugin into the local Studio."""

from __future__ import annotations

import os
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from .auth import load_or_create_bridge_token, token_fingerprint, validate_token

PLUGIN_PROJECT = Path("apps/studio-plugin/default.project.json")
PLUGIN_FILENAME = "RQEStudioBridge.rbxmx"


def studio_plugins_dir() -> Path:
    """Where Roblox Studio loads local plugins from on this machine."""
    local_app_data = os.environ.get("LOCALAPPDATA")
    if not local_app_data:
        raise RuntimeError("LOCALAPPDATA is not set; cannot locate the Studio plugins folder")
    return Path(local_app_data) / "Roblox" / "Plugins"


def build_plugin(root: Path, output: Path, *, bearer_token: str | None = None) -> dict[str, Any]:
    """Build the plugin model with Rojo."""
    source_project = root / PLUGIN_PROJECT
    if not source_project.exists():
        raise FileNotFoundError(f"plugin project not found: {source_project}")
    if shutil.which("rojo") is None:
        raise RuntimeError("rojo is not on PATH; install it from https://rojo.space to build the plugin")

    output.parent.mkdir(parents=True, exist_ok=True)

    temporary: tempfile.TemporaryDirectory[str] | None = None
    project = source_project
    try:
        if bearer_token is not None:
            token = validate_token(bearer_token)
            temporary = tempfile.TemporaryDirectory(prefix="rqe-plugin-build-")
            staging = Path(temporary.name)
            staged_source = staging / "src"
            shutil.copytree(root / "apps" / "studio-plugin" / "src", staged_source)
            # token characters are deliberately restricted by validate_token,
            # so the value is safe inside this short-lived Luau string literal.
            (staged_source / "Auth.lua").write_text(
                "--!strict\nreturn table.freeze({ bearerToken = \"" + token + "\" })\n",
                encoding="utf-8",
                newline="\n",
            )
            project = staging / "default.project.json"
            project.write_text(
                json.dumps({"name": "RQEStudioBridge", "tree": {"$path": "src"}}, indent=2) + "\n",
                encoding="utf-8",
                newline="\n",
            )

        result = subprocess.run(
            ["rojo", "build", str(project), "--output", str(output)],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(project.parent if bearer_token is not None else root),
        )
    finally:
        if temporary is not None:
            temporary.cleanup()
    if result.returncode != 0:
        raise RuntimeError(f"rojo build failed: {result.stderr.strip() or result.stdout.strip()}")
    return {
        "project": str(source_project),
        "output": str(output),
        "bytes": output.stat().st_size,
        "stdout": result.stdout.strip(),
    }


def install_plugin(
    root: Path,
    plugins_dir: Path | None = None,
    *,
    bearer_token: str | None = None,
    token_path: Path | None = None,
) -> dict[str, Any]:
    """Build the plugin straight into Studio's plugins folder."""
    if bearer_token is None:
        token, credential_path, credential_created = load_or_create_bridge_token(token_path)
    else:
        token = validate_token(bearer_token)
        credential_path = token_path
        credential_created = False
    target_dir = plugins_dir or studio_plugins_dir()
    created = not target_dir.exists()
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / PLUGIN_FILENAME
    existed = target.exists()
    previous_size = target.stat().st_size if existed else 0

    build = build_plugin(root, target, bearer_token=token)

    # Any *other* copy of this plugin in the same folder is a trap.
    #
    # Studio loads every file in the plugins directory, so an `.rbxm` left by an
    # older install runs alongside the `.rbxmx` written here. Both connect to the
    # hub, both answer, and the hub cannot tell them apart -- so commands land on
    # whichever replies first. Measured: a stale copy from an earlier build
    # answered `client.camera_set` with `E_UNKNOWN_METHOD` while the fresh one
    # sitting beside it implemented the command, and reinstalling did not help
    # because reinstalling only rewrites one of the two files.
    #
    # Reported rather than deleted. These are files in the user's Roblox folder
    # and this tool did not necessarily put all of them there.
    rivals = sorted(
        str(other) for other in target_dir.iterdir()
        if other.is_file()
        and other != target
        and other.stem.lower() == target.stem.lower()
    )

    return {
        "installed": True,
        "competingCopies": rivals,
        "competingCopiesNote": (
            "another copy of this plugin is installed beside the one just written. "
            "Studio loads both and commands land on whichever answers first, so a "
            "stale copy can shadow this build. Move the listed files out of the "
            "plugins folder and restart Studio"
        ) if rivals else "",
        "path": str(target),
        "pluginsDir": str(target_dir),
        "createdPluginsDir": created,
        "replacedExisting": existed,
        "previousBytes": previous_size,
        "bytes": build["bytes"],
        "authentication": {
            "required": True,
            "tokenFingerprint": token_fingerprint(token),
            "credentialPath": str(credential_path) if credential_path is not None else None,
            "credentialCreated": credential_created,
            "secretIncluded": False,
        },
        "note": (
            "Studio loads plugins from this folder at startup. If the bridge does not "
            "connect within a few seconds, restart Roblox Studio once."
        ),
    }
