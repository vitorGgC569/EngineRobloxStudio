"""The sourcing policy, and the two ways it can go wrong.

`REUSE > ADAPT > GENERATE` has a failure mode at each end. Source too little and
the factory spends hours rebuilding a barrel. Source too much and every game
built from the same free pack is the same game. Both are tested here, because
the second one is invisible until you have shipped ten titles.
"""

from __future__ import annotations

import stat
import zipfile

import pytest

from rqe.geometry.kit import backend_for
from rqe.sourcing import (
    AUTHORED_ROLES,
    LICENCES,
    SOURCEABLE_ROLES,
    STRUCTURAL_ROLES,
    attributions,
    decide,
    policy,
    sources_for,
)


# ------------------------------------------------------------------ the order


def test_a_sourceable_role_is_reused_when_something_offers_it():
    verdict = decide("oak", role="vegetation", kind="geometry",
                     available=["quaternius"])
    assert verdict.action == "reuse"
    assert verdict.source == "quaternius"


def test_the_same_role_is_generated_when_nothing_offers_it():
    """A failed lookup must never stop the factory."""

    verdict = decide("oak", role="vegetation", kind="geometry", available=[])
    assert verdict.action == "generate"
    assert verdict.source == "internal"


def test_internal_wins_over_everything():
    verdict = decide("oak", role="vegetation", kind="geometry",
                     available=["internal", "quaternius"])
    assert verdict.action == "reuse"
    assert verdict.source == "internal"


# --------------------------------------------------------- sourcing too much


@pytest.mark.parametrize("role", sorted(AUTHORED_ROLES))
def test_identity_roles_are_never_bought(role):
    """The failure mode of REUSE > GENERATE taken too far.

    A landmark is what a player remembers a game by. Buying it is how every
    game built from the same CC0 pack becomes the same game, and no licence
    check catches that.
    """

    verdict = decide(role, role=role, kind="geometry",
                     available=["quaternius", "kenney", "internal"])
    assert verdict.action == "generate"
    assert verdict.source == "internal"


@pytest.mark.parametrize("role", sorted(STRUCTURAL_ROLES))
def test_modular_and_surface_roles_are_never_bought(role):
    """Caught on the first run of the wiring, not in review.

    `structure` and `ground` both routed to an external source because neither
    was named anywhere and the generic branch took them. A building is sized to
    its plot; a bought mesh of one is a mesh of exactly one at one size.
    """

    verdict = decide(role, role=role, kind="geometry", available=["quaternius"])
    assert verdict.action == "generate"


# --------------------------------------------------------------- the licences


def test_an_unchecked_licence_cannot_ship():
    assert not LICENCES["unknown"].commercial


def test_roblox_reference_places_are_read_not_copied():
    assert not LICENCES["roblox-template"].commercial
    assert "roblox-reference" not in {s.id for s in sources_for("reference")}


def test_attribution_is_reported_as_data_for_a_screen():
    """CC-BY credit has to reach the running game, not a README."""

    verdict = decide("coin", role="prop", kind="icon", available=["game-icons"])
    assert verdict.attribution_required
    credits = attributions([verdict])
    assert credits and credits[0]["source"] == "game-icons"


def test_cc0_needs_no_credit():
    verdict = decide("click", role="feedback", kind="audio", available=["kenney-audio"])
    assert not verdict.attribution_required
    assert attributions([verdict]) == []


def test_music_and_unclassified_audio_are_authored_not_bought():
    verdict = decide("boss-theme", role="music", kind="audio", available=["kenney-audio"])
    assert verdict.action == "generate"
    assert verdict.source == "internal"


# ------------------------------------------------- one question, one answer


@pytest.mark.parametrize("role,available,expected", [
    ("vegetation", ["quaternius"], "sourced:quaternius"),
    ("rock", ["kenney"], "sourced:kenney"),
    ("vegetation", [], "blender"),
    ("hero", ["quaternius"], "blender"),
    ("objective", ["kenney"], "blender"),
    ("structure", ["quaternius"], "worldkit"),
    ("tower", ["quaternius"], "worldkit"),
    ("ground", ["kenney"], "parts"),
    ("paving", ["kenney"], "parts"),
])
def test_the_asset_director_and_the_policy_agree(role, available, expected):
    """They used to answer the same question in two places.

    `backend_for` asked "Blender, WorldKit or Parts"; `decide` asked "reuse,
    adapt or generate". Both are the Asset Director's job, and a factory whose
    two halves can disagree about one asset ships whichever answered last.
    """

    assert backend_for(role, available=available) == expected


def test_an_unknown_role_is_built_not_bought():
    """The safe default in both directions: no mesh, no download."""

    assert backend_for("whatever", available=["quaternius", "kenney"]) == "parts"


def test_the_policy_states_its_own_order():
    document = policy()
    assert document["order"] == ["reuse", "adapt", "generate"]
    assert set(document["authoredRoles"]) == AUTHORED_ROLES
    assert set(document["structuralRoles"]) == STRUCTURAL_ROLES
    assert {entry["licence"] for entry in document["refused"]} == {
        "roblox-template", "unknown"}


# ---------------------------------------------------------------- connectors


def test_every_catalogued_source_is_reachable_by_search():
    """A catalogue nobody can find is a catalogue nobody uses."""

    from rqe.sourcing.connectors import catalogues, search

    for entry in catalogues():
        for term in entry["covers"]:
            assert any(hit["pack"] == entry["pack"] for hit in search(term)), (
                entry["pack"], term)


def test_the_catalogue_covers_more_than_one_source():
    from rqe.sourcing.connectors import catalogues

    sources = {entry["source"] for entry in catalogues()}
    assert len(sources) >= 4, sources


def test_a_pack_with_no_direct_url_says_so_instead_of_failing_at_the_network():
    """Quaternius, ambientCG and game-icons do not serve a stable link.

    Guessing one produced a confident 404. Naming the situation is more useful
    than pretending to try.
    """

    from rqe.sourcing.connectors import ConnectorError, fetch

    with pytest.raises(ConnectorError, match="no direct download"):
        fetch("quaternius", "ultimate-nature")


def test_an_attribution_licence_is_carried_through_the_catalogue():
    from rqe.sourcing.connectors import catalogues

    icons = [entry for entry in catalogues("icon")]
    assert icons and any(entry["attributionRequired"] for entry in icons)


def test_every_direct_download_is_pinned_by_hash_and_size():
    from rqe.sourcing.connectors import catalogues

    direct = [item for item in catalogues() if item["fetchable"]]
    assert direct
    assert all(item["integrityPinned"] for item in direct)


def test_zip_slip_is_checked_by_path_containment_not_string_prefix(tmp_path):
    from rqe.sourcing.connectors import ConnectorError, _extract_archive

    archive = tmp_path / "malicious.zip"
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr("../files-evil/payload.lua", "bad")
    with pytest.raises(ConnectorError, match="unsafe path|escapes"):
        _extract_archive(archive, tmp_path / "files", "malicious")
    assert not (tmp_path / "files-evil" / "payload.lua").exists()


def test_zip_symlinks_are_refused(tmp_path):
    from rqe.sourcing.connectors import ConnectorError, _extract_archive

    archive = tmp_path / "symlink.zip"
    link = zipfile.ZipInfo("link")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    with zipfile.ZipFile(archive, "w") as bundle:
        bundle.writestr(link, "../outside")
    with pytest.raises(ConnectorError, match="symbolic link"):
        _extract_archive(archive, tmp_path / "files", "symlink")


def test_cached_download_with_wrong_checksum_is_deleted_and_refused(tmp_path):
    from rqe.sourcing.connectors import CACHE, ConnectorError, fetch

    archive = tmp_path / CACHE / "kenney" / "ui-audio" / "ui-audio.zip"
    archive.parent.mkdir(parents=True)
    archive.write_bytes(b"tampered")
    with pytest.raises(ConnectorError, match="integrity verification"):
        fetch("kenney", "ui-audio", root=tmp_path)
    assert not archive.exists()


def test_source_and_pack_identifiers_cannot_escape_the_cache(tmp_path):
    from rqe.sourcing.connectors import ConnectorError, assets

    with pytest.raises(ConnectorError, match="safe"):
        assets("../outside", "pack", root=tmp_path)
