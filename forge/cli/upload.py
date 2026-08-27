"""Upload a local file to Roblox and record the id it came back with.

The gap this closes
-------------------

The engine can *verify* an asset id and refuses any that has never loaded.
What it could not do was produce one. That is the whole reason `Material`
defines variants with no texture maps: real PBR needs a colour, normal,
roughness and metalness map uploaded to Roblox, and there was no way to get
them there from here.

So: upload through Open Cloud, wait for moderation, and write the resulting id
straight into the verification registry — which means an uploaded asset is
usable by the doctor the moment it exists, with no hand-copied number in
between. A hand-copied number is how three separate sets of invented ids got
into this project.

    forge upload textures/rock_color.png --type Image --name rock_color
    forge upload sfx/swing.ogg --type Audio --name swing

What Roblox allows
------------------

Images and audio. Meshes are not uploadable through Open Cloud, and audio
requires a verified account — the error says which, rather than being reported
as a generic failure, because those two need different things from you.

Moderation is asynchronous. A fresh upload is `Pending` for a while and cannot
be loaded yet; this polls until it resolves and refuses to register an id that
came back `Rejected`. Registering a pending id would put an unusable asset
past the doctor, which is precisely the check's reason for existing.
"""

from __future__ import annotations

import json
import mimetypes
import os
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
REGISTRY = REPO / "forge" / "catalog" / "assets-verified.json"

#: What Open Cloud accepts, and what it calls each one.
TYPES = {
    "Image": {"extensions": (".png", ".jpg", ".jpeg", ".bmp", ".tga"),
              "content": "image/png"},
    "Audio": {"extensions": (".mp3", ".ogg", ".wav"), "content": "audio/mpeg"},
}


class UploadError(RuntimeError):
    pass


def load_key() -> str:
    """The Open Cloud key, from the environment or the local file.

    Shared with `publish`, and for the same reason: the key is never accepted
    as an argument, so it appears in no command line and no shell history.
    """
    from forge.cli import publish

    return publish.load_key()


def _multipart(request_payload: dict, file_path: Path, content_type: str) -> tuple[bytes, str]:
    """Build the multipart body Open Cloud's asset endpoint expects.

    Hand-rolled rather than pulled from a library: this project vendors no
    third-party Python, and one boundary is less machinery than a dependency.
    """
    boundary = f"----forge{uuid.uuid4().hex}"
    parts: list[bytes] = []

    parts.append(f"--{boundary}\r\n".encode())
    parts.append(b'Content-Disposition: form-data; name="request"\r\n')
    parts.append(b"Content-Type: application/json\r\n\r\n")
    parts.append(json.dumps(request_payload).encode() + b"\r\n")

    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        f'Content-Disposition: form-data; name="fileContent"; filename="{file_path.name}"\r\n'.encode())
    parts.append(f"Content-Type: {content_type}\r\n\r\n".encode())
    parts.append(file_path.read_bytes() + b"\r\n")

    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def _send(method: str, url: str, key: str, body: bytes | None = None,
          content_type: str | None = None, timeout: int = 180) -> tuple[int, str]:
    headers = {"x-api-key": key}
    if content_type:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", "replace")
    except urllib.error.URLError as exc:
        raise UploadError(f"cannot reach Roblox: {exc.reason}")


def kind_for(path: Path, declared: str | None) -> str:
    if declared:
        if declared not in TYPES:
            raise UploadError(f"Open Cloud uploads {', '.join(TYPES)}, not '{declared}'")
        return declared
    suffix = path.suffix.lower()
    for name, spec in TYPES.items():
        if suffix in spec["extensions"]:
            return name
    raise UploadError(
        f"cannot tell what '{path.name}' is. Pass --type Image or --type Audio. "
        "Meshes cannot be uploaded through Open Cloud at all.")


def upload(path: Path, user_id: str, name: str | None = None,
           declared_type: str | None = None, description: str = "",
           wait: int = 180) -> dict[str, Any]:
    """Upload one file and return the resolved asset record."""
    if not path.exists():
        raise UploadError(f"no file at {path}")

    kind = kind_for(path, declared_type)
    key = load_key()
    content = mimetypes.guess_type(path.name)[0] or TYPES[kind]["content"]

    payload = {
        "assetType": kind,
        "displayName": name or path.stem,
        "description": description or f"uploaded by forge from {path.name}",
        "creationContext": {"creator": {"userId": str(user_id)}},
    }
    body, content_type = _multipart(payload, path, content)

    status, text = _send("POST", "https://apis.roblox.com/assets/v1/assets",
                         key, body, content_type)
    if status == 401:
        raise UploadError("the key did not authenticate")
    if status == 403:
        raise UploadError(
            "the key authenticated but lacks asset:write, or this account is "
            "not verified — audio upload requires a verified account")
    if status < 200 or status >= 300:
        raise UploadError(f"HTTP {status}: {text[:300]}")

    operation = json.loads(text)
    return _await_operation(operation, key, wait)


def _await_operation(operation: dict, key: str, wait: int) -> dict[str, Any]:
    """Poll until moderation resolves.

    An asset is `Pending` for a while after upload and cannot be loaded yet.
    Returning its id at that point would put an unusable asset into the
    registry, past the doctor and into a game.
    """
    path = operation.get("path") or operation.get("operationId")
    if not path:
        raise UploadError(f"no operation to follow: {json.dumps(operation)[:200]}")
    if not path.startswith("operations/"):
        path = f"operations/{path}"

    deadline = time.time() + wait
    while time.time() < deadline:
        status, text = _send("GET", f"https://apis.roblox.com/assets/v1/{path}", key)
        if status < 200 or status >= 300:
            raise UploadError(f"polling failed: HTTP {status} {text[:200]}")
        result = json.loads(text)
        if result.get("done"):
            response = result.get("response") or {}
            asset_id = response.get("assetId")
            state = (response.get("moderationResult") or {}).get("moderationState")
            if not asset_id:
                raise UploadError(f"finished with no asset id: {text[:300]}")
            if state == "Rejected":
                raise UploadError(f"asset {asset_id} was rejected by moderation")
            return {
                "assetId": str(asset_id),
                "reference": f"rbxassetid://{asset_id}",
                "moderation": state or "Unknown",
                "name": response.get("displayName"),
            }
        time.sleep(3)

    raise UploadError(
        f"still pending after {wait}s. It may resolve later; re-check before using it.")


def register(reference: str, record: dict[str, Any]) -> Path:
    """Write an uploaded id into the verification registry.

    Marked `ok` only when moderation approved it, so the doctor treats a
    pending or rejected upload exactly as it treats an invented id.
    """
    data: dict[str, Any] = {"assets": {}}
    if REGISTRY.exists():
        try:
            data = json.loads(REGISTRY.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass
    assets = data.setdefault("assets", {})
    assets[reference] = {
        "ok": record.get("moderation") == "Approved",
        "kind": "uploaded",
        "moderation": record.get("moderation"),
        "uploadedName": record.get("name"),
    }
    data["count"] = len(assets)
    data["passing"] = sum(1 for row in assets.values() if row.get("ok"))
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    return REGISTRY
