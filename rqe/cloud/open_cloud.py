"""Open Cloud: the half of Roblox that needs no desktop.

Luau execution was already here. This adds the rest of the family, and one pair
matters more than the others: `publish_place` and `list_versions` are what make
CI real. Build with Rojo, publish a version, run a Luau task against it, measure
the result -- with no Studio, no window, and no machine that has to stay awake.

Everything shares the transport and the discipline of the execution client:

**A missing credential is BLOCKED before any request is formed**, so an absent
key can never be mistaken for a server that answered nothing.

**Every method returns an outcome, not an exception.** An HTTP failure, a
permission refusal and an empty result are three different facts, and a caller
that has to catch to tell them apart will eventually catch too broadly.

**The key is never accepted as an argument.** It comes from the environment, so
a credential cannot be written into an agent transcript.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Mapping, Sequence

from ..assets.http import HttpRequest, HttpResponse, HttpTransport, UrllibTransport, json_body


DEFAULT_API_ROOT = "https://apis.roblox.com"

#: Scopes each family needs. Reported with a refusal so the remedy is the
#: message rather than a documentation hunt.
SCOPES = {
    "universe": "universe:read",
    "place": "universe.place:read",
    "publish": "universe.place:write",
    "datastore": "universe.datastore:read",
    "asset": "asset:read",
}


class Outcome(str, Enum):
    OK = "OK"
    BLOCKED = "BLOCKED"
    DENIED = "DENIED"
    NOT_FOUND = "NOT_FOUND"
    FAILED = "FAILED"


@dataclass(frozen=True)
class CloudResult:
    outcome: Outcome
    data: Mapping[str, Any] = field(default_factory=dict)
    status: int = 0
    error: str | None = None
    blockers: tuple[str, ...] = ()

    @property
    def ok(self) -> bool:
        return self.outcome is Outcome.OK

    def to_dict(self) -> dict[str, Any]:
        return {
            "outcome": self.outcome.value,
            "ok": self.ok,
            "status": self.status,
            "error": self.error,
            "blockers": list(self.blockers),
            "data": dict(self.data),
        }


class OpenCloudClient:
    """Universes, places, versions, data stores and assets."""

    def __init__(
        self,
        *,
        api_root: str = DEFAULT_API_ROOT,
        transport: HttpTransport | None = None,
        environment: Mapping[str, str] | None = None,
    ) -> None:
        self.api_root = api_root.rstrip("/")
        self.transport = transport or UrllibTransport()
        self._environment = dict(environment if environment is not None else os.environ)

    # -- credentials -----------------------------------------------------

    @property
    def api_key(self) -> str | None:
        return self._environment.get("ROBLOX_OPEN_CLOUD_KEY") or None

    def _blocked(self, scope: str) -> CloudResult:
        return CloudResult(
            outcome=Outcome.BLOCKED,
            error="no Open Cloud API key",
            blockers=(
                f"set ROBLOX_OPEN_CLOUD_KEY to a key with the {scope} scope, "
                "created on the Creator Dashboard",
            ),
        )

    def capabilities(self) -> dict[str, Any]:
        return {
            "backend": "open-cloud",
            "available": self.api_key is not None,
            "apiRoot": self.api_root,
            "scopes": dict(SCOPES),
            "blockers": [] if self.api_key else [
                "ROBLOX_OPEN_CLOUD_KEY is not set; every call will be BLOCKED"
            ],
        }

    # -- plumbing --------------------------------------------------------

    def _headers(self, content_type: str | None = None) -> dict[str, str]:
        headers = {"x-api-key": self.api_key or ""}
        if content_type:
            headers["Content-Type"] = content_type
        return headers

    def _send(self, request: HttpRequest, scope: str) -> CloudResult:
        try:
            response = self.transport.send(request)
        except Exception as exc:  # noqa: BLE001 - transport specific
            return CloudResult(outcome=Outcome.FAILED, error=f"transport error: {exc}")
        return self._interpret(response, scope)

    def _interpret(self, response: HttpResponse, scope: str) -> CloudResult:
        try:
            document = response.json()
        except (ValueError, json.JSONDecodeError):
            document = {}
        if not isinstance(document, dict):
            document = {"value": document}

        if response.status in (401, 403):
            # Distinguished from a generic failure because the remedy is
            # different: a denied call needs a scope, a failed one needs a retry.
            return CloudResult(
                outcome=Outcome.DENIED,
                status=response.status,
                data=document,
                error=str(document.get("message") or "the API key was refused"),
                blockers=(f"the key needs the {scope} scope for this resource",),
            )
        if response.status == 404:
            return CloudResult(outcome=Outcome.NOT_FOUND, status=response.status, data=document,
                               error=str(document.get("message") or "not found"))
        if response.status >= 400:
            return CloudResult(outcome=Outcome.FAILED, status=response.status, data=document,
                               error=str(document.get("message") or f"HTTP {response.status}"))
        return CloudResult(outcome=Outcome.OK, status=response.status, data=document)

    # -- universes and places --------------------------------------------

    def universe(self, universe_id: str) -> CloudResult:
        """Read a universe: its name, visibility and age rating."""

        if not self.api_key:
            return self._blocked(SCOPES["universe"])
        return self._send(HttpRequest(
            method="GET",
            url=f"{self.api_root}/cloud/v2/universes/{universe_id}",
            headers=self._headers(),
        ), SCOPES["universe"])

    def place(self, universe_id: str, place_id: str) -> CloudResult:
        """Read a place: its name, description and server size."""

        if not self.api_key:
            return self._blocked(SCOPES["place"])
        return self._send(HttpRequest(
            method="GET",
            url=f"{self.api_root}/cloud/v2/universes/{universe_id}/places/{place_id}",
            headers=self._headers(),
        ), SCOPES["place"])

    def update_place(self, universe_id: str, place_id: str, fields: Mapping[str, Any]) -> CloudResult:
        """Change a place's metadata.

        Restricted to metadata on purpose: the geometry of a place is published
        as a version, not patched in place, and conflating the two is how a
        build gets overwritten by a field edit.
        """

        allowed = {"displayName", "description", "serverSize"}
        unknown = sorted(set(fields) - allowed)
        if unknown:
            return CloudResult(
                outcome=Outcome.FAILED,
                error=f"these fields cannot be patched: {', '.join(unknown)}; "
                      f"place content is published as a version, not patched",
            )
        if not self.api_key:
            return self._blocked(SCOPES["publish"])

        mask = ",".join(sorted(fields))
        return self._send(HttpRequest(
            method="PATCH",
            url=f"{self.api_root}/cloud/v2/universes/{universe_id}/places/{place_id}?updateMask={mask}",
            headers=self._headers("application/json"),
            body=json_body(dict(fields)),
        ), SCOPES["publish"])

    # -- publishing -------------------------------------------------------

    def publish_place(
        self,
        universe_id: str,
        place_id: str,
        payload: bytes,
        *,
        published: bool = False,
        binary: bool = False,
    ) -> CloudResult:
        """Upload a place file as a new version.

        `published=False` saves the version without releasing it, which is the
        right default: publishing pushes it to every live server, and a default
        that does that is a default that eventually does it by accident.
        """

        if not self.api_key:
            return self._blocked(SCOPES["publish"])
        if not payload:
            return CloudResult(outcome=Outcome.FAILED, error="the place file is empty")

        version_type = "Published" if published else "Saved"
        content_type = "application/octet-stream" if binary else "application/xml"
        return self._send(HttpRequest(
            method="POST",
            url=(
                f"{self.api_root}/universes/v1/{universe_id}/places/{place_id}"
                f"/versions?versionType={version_type}"
            ),
            headers=self._headers(content_type),
            body=payload,
            timeout_seconds=180.0,
        ), SCOPES["publish"])

    def list_versions(self, universe_id: str, place_id: str, *, limit: int = 25) -> CloudResult:
        """Every version of a place, newest first.

        The other half of a rollback: publishing without being able to see what
        came before is a one-way door.
        """

        if not self.api_key:
            return self._blocked(SCOPES["place"])
        return self._send(HttpRequest(
            method="GET",
            url=(
                f"{self.api_root}/cloud/v2/universes/{universe_id}/places/{place_id}"
                f"/versions?maxPageSize={max(1, min(limit, 100))}"
            ),
            headers=self._headers(),
        ), SCOPES["place"])

    # -- data stores ------------------------------------------------------

    def datastore_entry(
        self,
        universe_id: str,
        datastore: str,
        entry_id: str,
        *,
        scope: str = "global",
    ) -> CloudResult:
        """Read one entry, so a persistence claim can be checked from outside.

        A save that only the game can read is a save nobody can verify. This is
        what turns "the purchase persisted" from an assertion into evidence.
        """

        if not self.api_key:
            return self._blocked(SCOPES["datastore"])
        return self._send(HttpRequest(
            method="GET",
            url=(
                f"{self.api_root}/cloud/v2/universes/{universe_id}"
                f"/data-stores/{datastore}/scopes/{scope}/entries/{entry_id}"
            ),
            headers=self._headers(),
        ), SCOPES["datastore"])

    def list_datastores(self, universe_id: str, *, limit: int = 25) -> CloudResult:
        if not self.api_key:
            return self._blocked(SCOPES["datastore"])
        return self._send(HttpRequest(
            method="GET",
            url=(
                f"{self.api_root}/cloud/v2/universes/{universe_id}"
                f"/data-stores?maxPageSize={max(1, min(limit, 100))}"
            ),
            headers=self._headers(),
        ), SCOPES["datastore"])

    # -- assets -----------------------------------------------------------

    def asset(self, asset_id: str) -> CloudResult:
        """Read an asset's metadata and moderation state.

        Moderation is the reason this exists. A published asset id is not an
        approved one, and the difference is only visible here.
        """

        if not self.api_key:
            return self._blocked(SCOPES["asset"])
        result = self._send(HttpRequest(
            method="GET",
            url=f"{self.api_root}/assets/v1/assets/{asset_id}",
            headers=self._headers(),
        ), SCOPES["asset"])

        if result.ok:
            moderation = result.data.get("moderationResult") or {}
            state = moderation.get("moderationState") if isinstance(moderation, Mapping) else None
            enriched = dict(result.data)
            enriched["moderationState"] = state or "UNKNOWN"
            enriched["approved"] = state == "Approved"
            enriched["usableInGame"] = state == "Approved"
            return CloudResult(outcome=result.outcome, data=enriched, status=result.status)
        return result


def summarise(results: Mapping[str, CloudResult]) -> dict[str, Any]:
    """Fold several calls into one verdict, keeping the reasons."""

    blocked = [name for name, result in results.items() if result.outcome is Outcome.BLOCKED]
    denied = [name for name, result in results.items() if result.outcome is Outcome.DENIED]
    failed = [name for name, result in results.items() if result.outcome is Outcome.FAILED]
    return {
        "ok": all(result.ok for result in results.values()),
        "blocked": blocked,
        "denied": denied,
        "failed": failed,
        "results": {name: result.to_dict() for name, result in results.items()},
    }
