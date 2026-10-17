"""Local secret management for the Studio Bridge.

The hub binds to loopback, but it is still a code-execution control plane.  A
per-machine bearer token protects both the agent RPC surface and every plugin
transport endpoint.  Secret bytes live outside the repository and artifacts;
only a short SHA-256 fingerprint is safe to report.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import base64
from pathlib import Path


TOKEN_ENVIRONMENT = "RQE_BRIDGE_TOKEN"
TOKEN_FILENAME = "bridge-token"
MIN_TOKEN_BYTES = 32
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9._~+/=-]+$")
# Wire credentials are capabilities, not identities.  In particular, a token
# that can inspect a place must not also be enough to mutate it or execute an
# arbitrary Luau chunk.  ``publisher`` is intentionally separate even though
# the Studio command manifest currently contains no publication command: Open
# Cloud publishing uses it at the application boundary rather than smuggling
# publication authority through a generic "agent" credential.
ROLES = frozenset({"reader", "mutator", "executor", "publisher", "plugin", "admin"})

COMMAND_ROLE_BY_EFFECT = {
    "read": "reader",
    "transient": "mutator",
    "mutation": "mutator",
    "context-transition": "mutator",
    "arbitrary": "executor",
}


class BridgeAuthError(ValueError):
    pass


def default_token_path() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if not local_app_data:
        raise BridgeAuthError("LOCALAPPDATA is not set; cannot locate the RQE bridge credential store")
    return Path(local_app_data) / "RQE" / TOKEN_FILENAME


def validate_token(value: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise BridgeAuthError("bridge token must be a non-empty string")
    token = value.strip()
    if len(token.encode("utf-8")) < MIN_TOKEN_BYTES:
        raise BridgeAuthError(f"bridge token must contain at least {MIN_TOKEN_BYTES} UTF-8 bytes")
    if any(character in token for character in "\r\n\0"):
        raise BridgeAuthError("bridge token contains a forbidden control character")
    if TOKEN_PATTERN.fullmatch(token) is None:
        raise BridgeAuthError("bridge token must use only printable bearer-token characters")
    return token


def token_fingerprint(token: str) -> str:
    validated = validate_token(token)
    return hashlib.sha256(validated.encode("utf-8")).hexdigest()[:16]


def derive_role_token(root_token: str, role: str) -> str:
    """Derive a purpose-bound bearer credential from the machine secret.

    The root credential never crosses HTTP and is never embedded in the Studio
    plugin.  Compromise of a plugin credential therefore cannot authorize agent
    RPC calls or administrative session retirement.
    """

    root = validate_token(root_token)
    if role not in ROLES:
        raise BridgeAuthError(f"unknown bridge credential role: {role}")
    digest = hmac.new(
        root.encode("utf-8"),
        f"rqe.bridge/1:{role}".encode("ascii"),
        hashlib.sha256,
    ).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


def derive_role_tokens(root_token: str) -> dict[str, str]:
    """Return all wire credentials derived from one local root secret."""

    return {role: derive_role_token(root_token, role) for role in sorted(ROLES)}


def derive_installation_id(root_token: str) -> str:
    """Stable, non-secret identity for this machine's installed plugin."""

    root = validate_token(root_token)
    digest = hmac.new(
        root.encode("utf-8"),
        b"rqe.bridge/2:installation",
        hashlib.sha256,
    ).hexdigest()
    return f"inst-{digest[:32]}"


def role_for_command_effect(effect: str) -> str:
    """Return the one wire capability required by a manifest effect."""

    try:
        return COMMAND_ROLE_BY_EFFECT[effect]
    except KeyError as exc:
        raise BridgeAuthError(f"unknown bridge command effect: {effect}") from exc


def load_bridge_token(
    path: Path | None = None,
    *,
    allow_environment: bool = True,
) -> str:
    if allow_environment:
        environment = os.environ.get(TOKEN_ENVIRONMENT)
        if environment:
            return validate_token(environment)
    target = (path or default_token_path()).resolve()
    try:
        return validate_token(target.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise BridgeAuthError(
            f"bridge credential is missing at {target}; run 'rqe studio install' first"
        ) from exc
    except OSError as exc:
        raise BridgeAuthError(f"could not read bridge credential {target}: {exc}") from exc


def load_or_create_bridge_token(path: Path | None = None) -> tuple[str, Path, bool]:
    """Read the machine token or atomically create it once.

    ``xb`` prevents two installers from silently rotating each other's token.
    If another process wins the race, this process simply reads the winner.
    """

    environment = os.environ.get(TOKEN_ENVIRONMENT)
    if environment:
        return validate_token(environment), path or default_token_path(), False

    target = (path or default_token_path()).resolve()
    try:
        return load_bridge_token(target, allow_environment=False), target, False
    except BridgeAuthError:
        if target.exists():
            raise

    target.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(48)
    try:
        with target.open("x", encoding="utf-8", newline="\n") as handle:
            handle.write(token + "\n")
        try:
            target.chmod(0o600)
        except OSError:
            # Windows ACLs are inherited from LOCALAPPDATA; chmod is best-effort.
            pass
        return validate_token(token), target, True
    except FileExistsError:
        return load_bridge_token(target, allow_environment=False), target, False
