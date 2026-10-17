"""What a pass is allowed to claim.

Positive, negative and no-op cases for the verdict model. The no-op tests are
the point: a command that returns cleanly while changing nothing is the failure
this whole module exists to catch, and it is the one that looks like success in
every log.
"""

from __future__ import annotations

import pytest

from rqe.evidence import (
    GATE_LEVELS,
    as_evidence,
    gate_level,
    BEHAVIOR_SUCCESS,
    COMMAND_SUCCESS,
    E2E_SUCCESS,
    FAILED,
    NOT_VALIDATED,
    EvidenceError,
    Verdict,
    from_bridge,
    not_validated,
    promote,
    summarise,
)


# ------------------------------------------------------------------- positive


def test_an_observed_effect_earns_behaviour():
    verdict = from_bridge("interact", {"success": True, "triggered": True},
                          effect_keys=["triggered"])
    assert verdict.level == BEHAVIOR_SUCCESS
    assert verdict.passed and verdict.trustworthy


def test_state_movement_earns_end_to_end():
    verdict = from_bridge("buy", {"success": True, "triggered": True},
                          effect_keys=["triggered"])
    promoted = promote(verdict, state_before=120, state_after=71, what="cash")
    assert promoted.level == E2E_SUCCESS
    assert promoted.observed["cash"]["before"] == 120
    assert promoted.observed["cash"]["after"] == 71


# -------------------------------------------------------------------- no-op


def test_success_without_an_observed_effect_is_only_the_wire():
    """The demotion that stops a bridge test reading as a game test."""

    verdict = from_bridge("interact", {"success": True}, effect_keys=["triggered"])
    assert verdict.level == COMMAND_SUCCESS
    assert verdict.passed
    assert not verdict.trustworthy


def test_a_handler_that_runs_and_changes_nothing_fails():
    """The no-op wearing a pass.

    The prompt fired, the handler ran, and the player is exactly as rich as
    before. Every field says success and the game did not move.
    """

    verdict = from_bridge("buy", {"success": True, "triggered": True},
                          effect_keys=["triggered"])
    promoted = promote(verdict, state_before=120, state_after=120, what="cash",
                       probe_proven=True)
    assert promoted.level == FAILED
    assert "no-op wearing a pass" in promoted.reason


def test_an_unmoved_probe_is_not_validated_until_it_has_been_seen_to_move():
    """The fifth measurement error of the session, encoded.

    Two purchases were called FAILED on "towers 29 -> 29" while the game had
    built four towers -- the pad renames each one to its catalogue id, so a
    count of models named "Tower" could never move. "I looked and saw nothing"
    is only evidence when you can show you would have seen something.
    """

    verdict = from_bridge("build", {"success": True, "triggered": True},
                          effect_keys=["triggered"])
    promoted = promote(verdict, state_before=29, state_after=29, what="towers")
    assert promoted.level == NOT_VALIDATED
    assert "shown capable of moving" in promoted.blocked_by


def test_income_accruing_during_a_purchase_does_not_count_as_a_purchase():
    """The bug this model had on its very first live run.

    Cash went 20 -> 49 across an `actor.interact` on a build pad: income accrued
    during the twenty-second round trip and outran the price. Every field said
    success and nothing had been bought.
    """

    verdict = from_bridge("buy", {"success": True, "triggered": True},
                          effect_keys=["triggered"])
    promoted = promote(verdict, state_before=20, state_after=49,
                       what="cash", expect="decreased")
    assert promoted.level == FAILED
    assert "not decreased" in promoted.reason


def test_a_spend_that_really_spends_is_end_to_end():
    verdict = from_bridge("buy", {"success": True, "triggered": True},
                          effect_keys=["triggered"])
    promoted = promote(verdict, state_before=120, state_after=71,
                       what="cash", expect="decreased")
    assert promoted.level == E2E_SUCCESS


def test_a_non_numeric_field_cannot_be_checked_for_direction():
    verdict = from_bridge("buy", {"success": True, "triggered": True},
                          effect_keys=["triggered"])
    promoted = promote(verdict, state_before="a", state_after="b",
                       what="tier", expect="decreased")
    assert promoted.level == NOT_VALIDATED


def test_a_verdict_cannot_claim_behaviour_with_nothing_observed():
    with pytest.raises(EvidenceError, match="nothing observed"):
        Verdict("interact", BEHAVIOR_SUCCESS)


# -------------------------------------------------------------- not validated


def test_an_instrument_that_cannot_tell_never_passes():
    verdict = not_validated("interact", blocked_by="no client half installed")
    assert verdict.level == NOT_VALIDATED
    assert not verdict.passed
    assert not verdict.trustworthy


def test_not_validated_must_name_its_blocker():
    """An unexplained non-answer reads as a product failure."""

    with pytest.raises(EvidenceError, match="without naming what blocked it"):
        Verdict("interact", NOT_VALIDATED)


def test_a_missing_player_is_the_harness_not_the_game():
    verdict = from_bridge("interact",
                          {"success": False, "requiresRealPlayer": True,
                           "reason": "no_player_to_attribute_the_trigger_to"})
    assert verdict.level == NOT_VALIDATED
    assert "Player" in verdict.blocked_by


def test_a_response_with_no_success_field_is_not_a_pass():
    verdict = from_bridge("mystery", {"elapsedMs": 12})
    assert verdict.level == NOT_VALIDATED


# ------------------------------------------------------------------ negative


def test_a_real_refusal_is_a_product_verdict():
    """Distinct from NOT_VALIDATED: here the instrument saw the game say no."""

    verdict = from_bridge("interact",
                          {"success": False, "reason": "prompt_did_not_fire"},
                          effect_keys=["triggered"])
    assert verdict.level == FAILED
    assert verdict.trustworthy
    assert not verdict.passed


# ------------------------------------------------------------------ the run


def test_a_run_of_wire_level_passes_says_it_tested_itself():
    verdicts = [
        from_bridge("a", {"success": True}),
        from_bridge("b", {"success": True}),
        not_validated("c", blocked_by="no client half"),
    ]
    report = summarise(verdicts)
    assert report["provesSomethingAboutTheProduct"] == 0
    assert report["wireOnly"] == ["a", "b"]
    assert report["instrumentCouldNotTell"] == ["c"]
    assert "tested itself" in report["note"]


def test_a_run_of_observed_effects_says_so():
    verdicts = [from_bridge("a", {"success": True, "triggered": True},
                            effect_keys=["triggered"])]
    report = summarise(verdicts)
    assert report["provesSomethingAboutTheProduct"] == 1
    assert "observed a real effect" in report["note"]


class TestTheSeamToTheGate:
    """The bridge this module went without: nothing imported it but its test.

    `evidence.py` names the distinction the whole engine is built on and had no
    way to carry it into the release gate, so the distinction was documented and
    never enforced. These assert the conversion, and above all that a verdict
    never claims more than it observed.
    """

    def test_every_level_maps_somewhere(self):
        from rqe.models import VALIDATION_LEVELS

        for level, mapped in GATE_LEVELS.items():
            assert mapped in VALIDATION_LEVELS, level

    def test_an_unknown_level_is_refused_rather_than_defaulted(self):
        with pytest.raises(EvidenceError):
            gate_level("PROBABLY_FINE")

    def test_a_command_success_cannot_claim_runtime_evidence(self):
        # The exact false pass this module exists to prevent.
        from rqe.models import validation_level_at_least

        level = gate_level(COMMAND_SUCCESS)
        assert not (validation_level_at_least(level, "RUNTIME_VALIDATED"))

    def test_an_e2e_verdict_carries_e2e_evidence(self):
        record = as_evidence(
            Verdict("purchase", E2E_SUCCESS, observed={"balance": 40}),
            probe="shop", category="economy")
        assert record.validation_level == "E2E_VALIDATED"
        assert record.status == "PASS"
        assert record.conclusive
        assert record.details["balance"] == 40

    def test_a_blocked_instrument_is_inconclusive_and_not_a_failure(self):
        # A NOT_VALIDATED verdict describes the harness. Recording it as FAIL
        # is how an agent goes and debugs a purchase handler that works.
        record = as_evidence(
            not_validated("interact", blocked_by="plugin prompt path",
                          remedy="use the client relay"),
            probe="shop", category="economy")
        assert record.validation_level == "NOT_VALIDATED"
        assert record.status == "WARN"
        assert not (record.conclusive)
        assert record.details["blockedBy"] == "plugin prompt path"

    def test_an_observed_failure_is_conclusive_and_says_so(self):
        record = as_evidence(
            Verdict("purchase", FAILED, observed={"balance": 0},
                    reason="the balance did not move"),
            probe="shop", category="economy")
        assert record.status == "FAIL"
        # A failure that was *seen* is a measurement of the product, not of
        # the harness -- and the gate has to be able to tell those apart.
        assert record.conclusive

    def test_the_level_it_observed_survives_into_the_record(self):
        record = as_evidence(
            Verdict("spawn", BEHAVIOR_SUCCESS, observed={"seen": True}),
            probe="actor", category="gameplay")
        assert record.details["evidenceLevel"] == BEHAVIOR_SUCCESS


# ------------------------------------------------------- fixture is not a measurement


_FIXTURE_PROBES = {
    "performance_budget",
    "memory_growth",
    "instance_growth",
    "duplicate_connections",
    "ground_support",
    "spawn_support",
    "spawn_clearance",
    "collision_overlap",
    "floating_objects",
    "buried_objects",
    "ui_visibility",
    "ui_overflow",
    "card_gallery",
    "button_interaction",
    "path_exists",
    "objective_reachable",
    "floor_progression",
    "door_clearance",
    "stairs_validity",
    "interaction_distance",
    "camera_obstruction",
    "remote_security",
    "runtime_error",
    "persistence",
    "multiplayer_isolation",
    "asset_security",
    "visual_quality",
    "visual_snapshot_bundle",
}


def _passing_fixture():
    """The historical false pass: a hand-written state file with healthy numbers."""

    from types import SimpleNamespace

    return SimpleNamespace(fixture={
        "geometry": {
            "groundSupport": {
                "maxGap": 1.5,
                "samples": [{"supported": True, "gap": 0.2}],
            },
            "overlaps": [],
            "floating": [],
            "buried": [],
            "doors": [{"name": "MineGate", "clearance": 4.0, "required": 3.0}],
            "stairs": [{"name": "PlotSteps", "valid": True}],
        },
        "spawn": {"supported": True, "clearance": True},
        "ui": {
            "visualScore": 0.92,
            "elements": [
                {"name": "CurrencyLabel", "visible": True},
                {"name": "CardCollectionPanel", "visible": True},
            ],
            "mobile": {"elements": [{"name": "CurrencyLabel", "withinViewport": True}]},
        },
        "validation": {
            "cardGalleryResponsive": True,
            "purchaseButtonResponsive": True,
            "pathExists": True,
            "objectiveReachable": True,
            "floorPurchasePromptResponsive": True,
            "cameraObstructions": [],
            "interactions": [{"name": "PurchasePrompt", "reachable": True}],
        },
        "network": {"rateLimits": True},
        "performance": {
            "frameMs": 12.4,
            "workspaceInstances": 184,
            "memoryGrowthMb": 1.8,
            "maxMemoryGrowthMb": 5,
            "assetPartCount": 46,
        },
    })


_HEALTHY_RUNTIME = {
    "instanceGrowth": 0,
    "duplicateConnections": 0,
    "consoleErrors": 0,
    "invalidPayloadRejected": True,
    "persistencePass": True,
    "multiplayerIsolation": True,
}

_HEALTHY_STATIC = {
    "serverPurchaseDistanceGuard": True,
    "suspiciousScripts": [],
    "assetManifestIssues": [],
    "visualAssetIssues": [],
    "visualSnapshotIssues": [],
}


def test_fixture_and_headless_literals_cannot_pass_a_probe():
    """Healthy fixture numbers and headless zeros used to come back PASS."""

    from types import SimpleNamespace

    from rqe.probes import run_probes
    from rqe.scoring import score_evidence

    evidence = run_probes(_passing_fixture(), _HEALTHY_RUNTIME, _HEALTHY_STATIC)
    seen = set()
    for item in evidence:
        if item.probe not in _FIXTURE_PROBES:
            continue
        seen.add(item.probe)
        assert item.status != "PASS", item.probe
        assert item.source == "headless-runtime"
        assert item.validation_level == "NOT_VALIDATED"
        assert item.conclusive is False
    assert seen == _FIXTURE_PROBES

    budget = next(item for item in evidence if item.probe == "performance_budget")
    assert budget.details["frameMs"] == 12.4
    assert budget.status == "WARN"

    scores, _, allowed, reasons = score_evidence(evidence)
    for category in ("performance", "geometry", "ui"):
        assert scores[category] == 0.0
        assert f"{category} has no Studio measurement" in reasons
    assert allowed is False

    capture = next(item for item in evidence if item.probe == "studio_runtime_capture")
    assert capture.status != "PASS"
    explicit = run_probes(
        SimpleNamespace(fixture={}),
        {},
        {"studioRuntime": {"status": "PASS"}},
    )
    assert next(item for item in explicit if item.probe == "studio_runtime_capture").status == "PASS"


def test_missing_keys_and_empty_lists_stay_unmeasured():
    """all([]) and a missing camera or console-error key used to pass or fail closed."""

    from types import SimpleNamespace

    from rqe.probes import run_probes

    evidence = run_probes(SimpleNamespace(fixture={
        "geometry": {"doors": [], "stairs": []},
        "validation": {"interactions": []},
    }), {}, {})
    for probe in (
        "door_clearance",
        "stairs_validity",
        "interaction_distance",
        "camera_obstruction",
        "runtime_error",
        "asset_security",
        "visual_quality",
        "visual_snapshot_bundle",
        "spawn_clearance",
        "path_exists",
        "persistence",
    ):
        item = next(candidate for candidate in evidence if candidate.probe == probe)
        assert item.status == "WARN", probe
        assert item.conclusive is False


def test_a_recorded_defect_fails_only_that_probe():
    from types import SimpleNamespace

    from rqe.probes import run_probes

    evidence = run_probes(SimpleNamespace(fixture={
        "spawn": {"clearance": False},
        "validation": {
            "pathExists": False,
            "objectiveReachable": False,
            "floorPurchasePromptResponsive": False,
            "cameraObstructions": ["wall"],
            "interactions": [{"name": "PurchasePrompt", "reachable": False}],
        },
        "geometry": {
            "doors": [{"name": "MineGate", "clearance": 1.0, "required": 3.0}],
            "stairs": [{"name": "PlotSteps", "valid": False}],
        },
        "performance": {"assetPartCount": 900},
        "ui": {"visualScore": 0.2},
        "network": {"rateLimits": False},
    }), {
        "consoleErrors": 2,
        "persistencePass": False,
        "multiplayerIsolation": False,
        "invalidPayloadRejected": False,
    }, {
        "suspiciousScripts": [{"file": "Bad.lua"}],
        "visualSnapshotIssues": ["missing"],
        "serverPurchaseDistanceGuard": False,
    })
    expected = {
        "spawn_clearance",
        "path_exists",
        "objective_reachable",
        "floor_progression",
        "door_clearance",
        "stairs_validity",
        "interaction_distance",
        "camera_obstruction",
        "remote_security",
        "runtime_error",
        "persistence",
        "multiplayer_isolation",
        "asset_security",
        "visual_quality",
        "visual_snapshot_bundle",
    }
    for probe in expected:
        item = next(candidate for candidate in evidence if candidate.probe == probe)
        assert item.status == "FAIL", probe
        assert item.conclusive is False
    # A probe with no recorded defect in this fixture stays unmeasured.
    assert next(item for item in evidence if item.probe == "floating_objects").status == "WARN"


def test_a_fixture_defect_still_fails_the_diagnostic_without_scoring():
    from types import SimpleNamespace

    from rqe.probes import run_probes
    from rqe.scoring import score_evidence

    evidence = run_probes(SimpleNamespace(fixture={
        "performance": {"frameMs": 40, "workspaceInstances": 10},
        "geometry": {"floating": ["TestRock"], "overlaps": [{"a": "A", "b": "B"}]},
        "ui": {"elements": [{"name": "CurrencyLabel", "visible": False}]},
    }), {"instanceGrowth": 4}, {})
    assert next(item for item in evidence if item.probe == "performance_budget").status == "FAIL"
    assert next(item for item in evidence if item.probe == "floating_objects").status == "FAIL"
    assert next(item for item in evidence if item.probe == "collision_overlap").status == "FAIL"
    assert next(item for item in evidence if item.probe == "ui_visibility").status == "FAIL"
    assert next(item for item in evidence if item.probe == "instance_growth").status == "FAIL"

    scores, _, allowed, _ = score_evidence(evidence)
    assert scores["performance"] == 0.0
    assert scores["geometry"] == 0.0
    assert scores["ui"] == 0.0
    assert allowed is False


def test_raising_the_validation_level_does_not_launder_a_fixture_source():
    from rqe.models import Evidence
    from rqe.scoring import score_evidence

    def _pass(source: str, level: str) -> Evidence:
        return Evidence(
            id="probe.performance_budget",
            probe="performance_budget",
            category="performance",
            status="PASS",
            severity="major",
            message="performance is within budget",
            source=source,
            validation_level=level,
            details={"frameMs": 12.4},
        )

    for source, level in (
        ("fixture", "RUNTIME_VALIDATED"),
        ("headless-runtime", "RUNTIME_VALIDATED"),
        ("luau-runtime", "STATICALLY_VALIDATED"),
        ("studio-bridge", "NOT_VALIDATED"),
    ):
        scores, _, allowed, _ = score_evidence([_pass(source, level)])
        assert scores["performance"] == 0.0, (source, level)
        assert allowed is False

    scores, _, _, _ = score_evidence([_pass("studio-bridge", "RUNTIME_VALIDATED")])
    assert scores["performance"] == 100.0

