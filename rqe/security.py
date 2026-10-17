"""Shared trust-boundary helpers for agent-facing surfaces.

The engine is intentionally powerful: it can write source, publish assets and
drive a live Studio.  Every entry point must therefore agree on two rules:

* an agent-provided path stays inside an explicitly allowed root;
* a bridge credential is sent only to a loopback or operator-allowlisted URL.

Keeping these checks here avoids the dangerous state where one MCP tool is
careful and the next tool added quietly is not.
"""

from __future__ import annotations

import ipaddress
import os
import re
from pathlib import Path
from typing import Iterable
from urllib.parse import urlsplit, urlunsplit


IMPORT_ROOTS_ENVIRONMENT = "RQE_IMPORT_ROOTS"
TRUSTED_HUB_URLS_ENVIRONMENT = "RQE_TRUSTED_HUB_URLS"
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
WINDOWS_RESERVED_FILENAMES = {
    "CON",
    "PRN",
    "AUX",
    "NUL",
    *(f"COM{index}" for index in range(1, 10)),
    *(f"LPT{index}" for index in range(1, 10)),
}


class SecurityBoundaryError(ValueError):
    """Untrusted input attempted to cross a filesystem or network boundary."""


def validate_path_component(value: object, *, label: str = "identifier", maximum: int = 128) -> str:
    """Validate one portable filename/id component, never a path fragment."""

    text = str(value or "").strip()
    if not text or len(text) > maximum or text in {".", ".."}:
        raise SecurityBoundaryError(f"{label} must contain 1 to {maximum} safe characters")
    if SAFE_COMPONENT.fullmatch(text) is None:
        raise SecurityBoundaryError(
            f"{label} may contain only letters, digits, dot, underscore and hyphen"
        )
    return text


def validate_filename(value: object, *, label: str = "filename", maximum: int = 255) -> str:
    """Validate a human-readable portable leaf name without changing it."""

    text = str(value or "")
    if not text or len(text) > maximum or text in {".", ".."}:
        raise SecurityBoundaryError(f"{label} must contain 1 to {maximum} characters")
    if text.endswith((" ", ".")) or any(ord(character) < 32 for character in text):
        raise SecurityBoundaryError(f"{label} contains unsupported control or trailing characters")
    if any(character in text for character in '<>:"/\\|?*'):
        raise SecurityBoundaryError(f"{label} must be one filename, not a path")
    stem = text.split(".", 1)[0].upper()
    if stem in WINDOWS_RESERVED_FILENAMES:
        raise SecurityBoundaryError(f"{label} uses a reserved Windows filename")
    return text


def _reject_symlink_components(root: Path, target: Path, label: str) -> None:
    """Reject every existing symlink between ``root`` and ``target``.

    ``Path.resolve`` prevents a symlink from escaping the root, but an in-root
    symlink can still change meaning between validation and use.  Agent-facing
    writes and publications choose the simpler invariant: no symlink at all.
    """

    relative = target.relative_to(root)
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise SecurityBoundaryError(f"{label} crosses a symbolic link: {current}")


def resolve_inside(
    root: str | Path,
    candidate: str | Path,
    *,
    label: str = "path",
    must_exist: bool = False,
    file_only: bool = False,
    directory_only: bool = False,
    suffixes: Iterable[str] = (),
) -> Path:
    """Resolve a relative path and prove that it remains inside ``root``.

    Absolute paths are rejected even when they happen to point into the root.
    This keeps command transcripts portable and prevents a caller from using a
    path accepted on one machine as authority over another machine.
    """

    base = Path(root).resolve()
    raw = Path(candidate)
    if raw.is_absolute():
        raise SecurityBoundaryError(f"{label} must be relative to {base}")

    target = (base / raw).resolve(strict=False)
    try:
        target.relative_to(base)
    except ValueError as exc:
        raise SecurityBoundaryError(f"{label} escapes the workspace: {candidate}") from exc

    _reject_symlink_components(base, target, label)

    if must_exist and not target.exists():
        raise SecurityBoundaryError(f"{label} does not exist: {candidate}")
    if file_only and (not target.exists() or not target.is_file()):
        raise SecurityBoundaryError(f"{label} must name an existing file: {candidate}")
    if directory_only and (not target.exists() or not target.is_dir()):
        raise SecurityBoundaryError(f"{label} must name an existing directory: {candidate}")
    allowed = {str(item).lower() for item in suffixes}
    if allowed and target.suffix.lower() not in allowed:
        raise SecurityBoundaryError(
            f"{label} must use one of {', '.join(sorted(allowed))}: {candidate}"
        )
    return target


def resolve_import_source(
    workspace_root: str | Path,
    candidate: str | Path,
    *,
    label: str = "import source",
    environment: str = IMPORT_ROOTS_ENVIRONMENT,
) -> Path:
    """Resolve an existing import directory under an operator-approved root.

    The workspace itself is always approved.  Additional absolute roots must be
    configured out of band in ``RQE_IMPORT_ROOTS`` (``os.pathsep`` separated),
    never supplied by the agent in the same call that reads them.
    """

    workspace = Path(workspace_root).resolve()
    roots = [workspace]
    for value in os.environ.get(environment, "").split(os.pathsep):
        if value.strip():
            roots.append(Path(value.strip()).resolve())

    raw = Path(candidate)
    attempted = raw.resolve(strict=False) if raw.is_absolute() else (workspace / raw).resolve(strict=False)
    for root in roots:
        try:
            attempted.relative_to(root)
        except ValueError:
            continue
        _reject_symlink_components(root, attempted, label)
        if not attempted.is_dir():
            raise SecurityBoundaryError(f"{label} must name an existing directory: {candidate}")
        return attempted

    raise SecurityBoundaryError(
        f"{label} is outside the workspace and configured {environment} roots: {candidate}"
    )


def _normalise_base_url(value: str) -> tuple[str, str]:
    raw = str(value or "").strip().rstrip("/")
    parsed = urlsplit(raw)
    if parsed.scheme not in {"http", "https"}:
        raise SecurityBoundaryError("hub URL must use http or https")
    if not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise SecurityBoundaryError("hub URL must contain a host and no embedded credentials")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise SecurityBoundaryError("hub URL must be an origin without a path, query or fragment")
    try:
        port = parsed.port
    except ValueError as exc:
        raise SecurityBoundaryError("hub URL has an invalid port") from exc
    if port is None:
        port = 443 if parsed.scheme == "https" else 80
    host = parsed.hostname.lower()
    display_host = f"[{host}]" if ":" in host else host
    normalised = urlunsplit((parsed.scheme.lower(), f"{display_host}:{port}", "", "", ""))
    return normalised, host


def validate_hub_url(
    value: str,
    *,
    allowlist_environment: str = TRUSTED_HUB_URLS_ENVIRONMENT,
) -> str:
    """Return a normalised hub origin only when it is trusted.

    Loopback is always trusted.  Remote origins require an exact origin in the
    operator-controlled ``RQE_TRUSTED_HUB_URLS`` environment variable.  This is
    evaluated before a bearer token is attached, closing credential redirects.
    """

    normalised, host = _normalise_base_url(value)
    loopback = host == "localhost"
    if not loopback:
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
    if loopback:
        return normalised

    allowed: set[str] = set()
    for item in os.environ.get(allowlist_environment, "").split(","):
        if item.strip():
            try:
                approved, _ = _normalise_base_url(item)
            except SecurityBoundaryError:
                continue
            allowed.add(approved)
    if normalised in allowed:
        return normalised

    raise SecurityBoundaryError(
        f"hub URL is not loopback or listed in {allowlist_environment}: {normalised}"
    )
