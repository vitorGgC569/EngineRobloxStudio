"""Load Roblox Open Cloud credentials from the operator's local key file.

Why this module exists
----------------------

`rqe assets` reads `RQE_ROBLOX_OPEN_CLOUD_API_KEY` from the environment, which
is the right interface for CI and the wrong one for a person sitting at their
own machine: they have a key file, they do not have a shell profile, and the
capability report cheerfully says `search: AVAILABLE` right up until the API
answers `roblox_authorization_blocked`.

So this reads the key from a file and puts it in the environment, and nothing
else. It never prints the key, never returns it to a caller that did not ask,
and never writes it anywhere. The file itself is excluded from git by
`.gitignore` (`docs/goal/`, `*.txt`) and must stay that way -- it authenticates
as a real Roblox account.

The file format
---------------

Roblox's key download hands over one string that reads like two things
concatenated: a short opaque prefix, then a base64-wrapped JWT which embeds
that prefix as `baseApiKey` alongside the owner id and an expiry.

It is tempting to conclude the prefix is the key and the rest is a session
token to discard. It is not: Roblox answers `Invalid API Key` to the prefix and
to the token, and `200` only to the whole string. **The entire file content is
the credential.** The split is only ever used to read the JWT for the owner id
and expiry that `describe` reports -- never to decide what to send.
"""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
from typing import Any

#: Where the operator keeps the key. Checked in order; the first that exists
#: wins. Nothing here is committed.
DEFAULT_LOCATIONS = (
    Path("docs/goal/key.txt"),
    Path(".secrets/roblox-open-cloud.key"),
)

#: The environment variable the rest of `rqe assets` already reads.
ENV_VAR = "RQE_ROBLOX_OPEN_CLOUD_API_KEY"

#: Every Roblox JWT starts with this header once base64-decoded.
_JWT_PREFIX = "eyJ"


def _session_token(raw: str) -> str | None:
    """The JWT half, for reading the owner and expiry out of.

    The token is base64 of a string that starts `eyJ`, so its own encoding
    starts `ZXlK`. This is a reporting aid only -- the credential sent to
    Roblox is always `raw` in full.
    """
    marker = raw.find("ZXlK")
    return raw[marker:] if marker > 0 else None


def describe(path: Path | None = None) -> dict[str, Any]:
    """What the key file contains, with the key itself left out.

    Deliberately returns no secret. This is what a `--check` prints and what a
    log may keep: the owner it authenticates as, whether the bundled session
    token has expired, and nothing that would let a reader use the credential.
    """
    source = _locate(path)
    if source is None:
        return {"found": False, "searched": [str(p) for p in DEFAULT_LOCATIONS]}

    raw = source.read_text(encoding="utf-8").strip()
    token = _session_token(raw)
    out: dict[str, Any] = {
        "found": True,
        "path": str(source),
        "keyLength": len(raw),
        "hasSessionToken": token is not None,
    }
    if token:
        try:
            jwt = base64.b64decode(token + "==").decode("utf-8", "replace")
            payload = json.loads(
                base64.urlsafe_b64decode(jwt.split(".")[1] + "==").decode("utf-8", "replace"))
            out["ownerId"] = payload.get("ownerId")
            out["audience"] = payload.get("aud")
            out["expiresAt"] = payload.get("exp")
            # The embedded prefix must match the front of the file, or this has
            # been edited into a state where the credential and the description
            # of it disagree -- worth knowing before a request goes out.
            out["consistent"] = raw.startswith(str(payload.get("baseApiKey") or "\0"))
        except Exception:
            out["sessionTokenReadable"] = False
    return out


def _locate(path: Path | None = None) -> Path | None:
    if path is not None:
        return path if path.is_file() else None
    for candidate in DEFAULT_LOCATIONS:
        if candidate.is_file():
            return candidate
    return None


def load(path: Path | None = None, *, overwrite: bool = False) -> bool:
    """Put the API key into the environment for this process only.

    Returns whether the environment now carries a key. An existing value is
    left alone unless `overwrite` is asked for: a key deliberately exported by
    the operator outranks a file this found on its own.
    """
    if os.environ.get(ENV_VAR) and not overwrite:
        return True

    source = _locate(path)
    if source is None:
        return False

    raw = source.read_text(encoding="utf-8").strip()
    if not raw:
        return False

    os.environ[ENV_VAR] = raw
    return True
