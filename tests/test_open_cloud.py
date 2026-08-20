"""Open Cloud beyond Luau execution.

No credentials are used and no request reaches Roblox. What is verified is the
part that decides whether an agent can trust the answer: a missing key is
BLOCKED before a request is formed, a refused key is DENIED with the scope it
needs, and neither is confused with a server that answered nothing.
"""

from __future__ import annotations

import json
import unittest

from rqe.assets.http import HttpRequest, HttpResponse
from rqe.cloud.open_cloud import OpenCloudClient, Outcome, summarise


def _response(status: int, payload: dict) -> HttpResponse:
    return HttpResponse(status=status, body=json.dumps(payload).encode("utf-8"))


class ScriptedTransport:
    def __init__(self, status: int = 200, payload: dict | None = None) -> None:
        self.status = status
        self.payload = payload if payload is not None else {}
        self.requests: list[HttpRequest] = []

    def send(self, request: HttpRequest) -> HttpResponse:
        self.requests.append(request)
        return _response(self.status, self.payload)


KEYED = {"ROBLOX_OPEN_CLOUD_KEY": "secret-key"}


def _client(transport, environment=KEYED) -> OpenCloudClient:
    return OpenCloudClient(transport=transport, environment=environment)


class TestCredentialDiscipline(unittest.TestCase):
    def test_no_key_blocks_before_any_request_is_formed(self):
        """An absent key must never look like a server that answered nothing."""

        transport = ScriptedTransport()
        result = _client(transport, environment={}).universe("1")
        self.assertIs(result.outcome, Outcome.BLOCKED)
        self.assertEqual(transport.requests, [])
        self.assertIn("universe:read", result.blockers[0])

    def test_every_family_blocks_without_a_key(self):
        client = _client(ScriptedTransport(), environment={})
        for call in (
            lambda: client.universe("1"),
            lambda: client.place("1", "2"),
            lambda: client.list_versions("1", "2"),
            lambda: client.publish_place("1", "2", b"<roblox/>"),
            lambda: client.datastore_entry("1", "store", "key"),
            lambda: client.list_datastores("1"),
            lambda: client.asset("9"),
        ):
            self.assertIs(call().outcome, Outcome.BLOCKED)

    def test_the_key_travels_as_a_header_and_never_in_a_url(self):
        transport = ScriptedTransport()
        _client(transport).universe("1")
        request = transport.requests[0]
        self.assertEqual(request.headers["x-api-key"], "secret-key")
        self.assertNotIn("secret-key", request.url)

    def test_capabilities_name_what_is_missing(self):
        report = OpenCloudClient(transport=ScriptedTransport(), environment={}).capabilities()
        self.assertFalse(report["available"])
        self.assertIn("ROBLOX_OPEN_CLOUD_KEY", report["blockers"][0])


class TestOutcomeSeparation(unittest.TestCase):
    def test_a_refused_key_is_denied_and_names_the_scope(self):
        """A denied call needs a scope; a failed one needs a retry. Collapsing
        them into one outcome sends the caller down the wrong path."""

        result = _client(ScriptedTransport(403, {"message": "insufficient scope"})).place("1", "2")
        self.assertIs(result.outcome, Outcome.DENIED)
        self.assertIn("universe.place:read", result.blockers[0])

    def test_a_missing_resource_is_not_found_rather_than_failed(self):
        result = _client(ScriptedTransport(404, {"message": "gone"})).universe("1")
        self.assertIs(result.outcome, Outcome.NOT_FOUND)

    def test_a_server_error_fails(self):
        result = _client(ScriptedTransport(500, {"message": "boom"})).universe("1")
        self.assertIs(result.outcome, Outcome.FAILED)

    def test_a_transport_error_fails_rather_than_raising(self):
        class Broken:
            def send(self, request):
                raise OSError("connection reset")

        result = _client(Broken()).universe("1")
        self.assertIs(result.outcome, Outcome.FAILED)
        self.assertIn("connection reset", result.error or "")


class TestPublishing(unittest.TestCase):
    def test_saving_is_the_default_and_publishing_is_explicit(self):
        """Publishing pushes to every live server. A default that does that is a
        default that eventually does it by accident."""

        transport = ScriptedTransport(200, {"versionNumber": 7})
        _client(transport).publish_place("1", "2", b"<roblox/>")
        self.assertIn("versionType=Saved", transport.requests[0].url)

        transport = ScriptedTransport(200, {"versionNumber": 8})
        _client(transport).publish_place("1", "2", b"<roblox/>", published=True)
        self.assertIn("versionType=Published", transport.requests[0].url)

    def test_an_empty_place_file_is_refused_locally(self):
        transport = ScriptedTransport()
        result = _client(transport).publish_place("1", "2", b"")
        self.assertIs(result.outcome, Outcome.FAILED)
        self.assertEqual(transport.requests, [])

    def test_binary_and_xml_declare_different_content_types(self):
        transport = ScriptedTransport(200, {})
        _client(transport).publish_place("1", "2", b"<roblox/>")
        self.assertEqual(transport.requests[0].headers["Content-Type"], "application/xml")

        transport = ScriptedTransport(200, {})
        _client(transport).publish_place("1", "2", b"\x00rbx", binary=True)
        self.assertEqual(transport.requests[0].headers["Content-Type"], "application/octet-stream")

    def test_versions_can_be_listed_for_rollback(self):
        """Publishing without being able to see what came before is a one-way
        door."""

        transport = ScriptedTransport(200, {"placeVersions": [{"versionNumber": 3}]})
        result = _client(transport).list_versions("1", "2")
        self.assertTrue(result.ok)
        self.assertIn("maxPageSize=25", transport.requests[0].url)

    def test_place_content_cannot_be_patched(self):
        """Content is published as a version. Conflating the two is how a build
        gets overwritten by a field edit."""

        transport = ScriptedTransport()
        result = _client(transport).update_place("1", "2", {"geometry": "..."})
        self.assertIs(result.outcome, Outcome.FAILED)
        self.assertIn("published as a version", result.error or "")
        self.assertEqual(transport.requests, [])

    def test_metadata_patches_send_an_update_mask(self):
        transport = ScriptedTransport(200, {})
        _client(transport).update_place("1", "2", {"displayName": "New"})
        self.assertIn("updateMask=displayName", transport.requests[0].url)


class TestAssets(unittest.TestCase):
    def test_a_published_asset_is_not_an_approved_one(self):
        """The distinction moderation exists to make."""

        transport = ScriptedTransport(200, {
            "assetId": "123", "moderationResult": {"moderationState": "Reviewing"},
        })
        result = _client(transport).asset("123")
        self.assertTrue(result.ok)
        self.assertFalse(result.data["approved"])
        self.assertEqual(result.data["moderationState"], "Reviewing")

    def test_an_approved_asset_is_usable(self):
        transport = ScriptedTransport(200, {
            "assetId": "123", "moderationResult": {"moderationState": "Approved"},
        })
        result = _client(transport).asset("123")
        self.assertTrue(result.data["approved"])
        self.assertTrue(result.data["usableInGame"])

    def test_a_missing_moderation_block_is_unknown_not_approved(self):
        result = _client(ScriptedTransport(200, {"assetId": "123"})).asset("123")
        self.assertEqual(result.data["moderationState"], "UNKNOWN")
        self.assertFalse(result.data["approved"])


class TestDataStores(unittest.TestCase):
    def test_an_entry_can_be_read_from_outside_the_game(self):
        """A save only the game can read is a save nobody can verify."""

        transport = ScriptedTransport(200, {"value": {"cash": 900}})
        result = _client(transport).datastore_entry("1", "PlayerData", "user_7")
        self.assertTrue(result.ok)
        self.assertIn("/data-stores/PlayerData/scopes/global/entries/user_7", transport.requests[0].url)


class TestSummary(unittest.TestCase):
    def test_a_summary_keeps_the_reasons(self):
        client = _client(ScriptedTransport(), environment={})
        results = {"universe": client.universe("1"), "place": client.place("1", "2")}
        summary = summarise(results)
        self.assertFalse(summary["ok"])
        self.assertEqual(sorted(summary["blocked"]), ["place", "universe"])


if __name__ == "__main__":
    unittest.main()
