"""What a pass is allowed to claim.

Positive, negative and no-op cases for the verdict model. The no-op tests are
the point: a command that returns cleanly while changing nothing is the failure
this whole module exists to catch, and it is the one that looks like success in
every log.
"""

from __future__ import annotations

import pytest

from rqe.evidence import (
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
