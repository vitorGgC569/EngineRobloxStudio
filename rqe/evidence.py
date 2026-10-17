"""What a passing command actually proves.

Three different claims wear the same word. A command can be accepted, a
behaviour can occur, and a game can change -- and a harness that reports one
while meaning another produces confident nonsense.

    COMMAND_SUCCESS   the instrument accepted the call and did not error
    BEHAVIOR_SUCCESS  the effect the command names was observed happening
    E2E_SUCCESS       the game changed: state moved, a resource was spent, a
                      thing exists that did not exist before

The fourth outcome is the one this module exists for:

    NOT_VALIDATED     the instrument cannot tell. Not a pass, not a failure of
                      the product -- a failure of the measurement.

**Why the fourth matters more than the other three.** `actor.interact` calls
`ProximityPrompt:InputHoldBegin` from the plugin's DataModel, where it is
accepted and can never fire `Triggered`. The primitive reports this correctly:
`success = false, reason = "prompt_did_not_fire"`. It is honest and it is
useless, because that sentence describes the game and the fault is in the
instrument -- an agent reading it goes and debugs a purchase handler that works.

Measured, in this repository, on the same prompt in the same session: the
plugin path returned `prompt_did_not_fire`; the client relay returned
`triggered: true` and the game's own counter went from absent to
`RQEPlayed_purchase: 1`. Same prompt, same player, same second. One of those
two answers was about the game and the other was about the wire.

So a verdict carries what it observed and how, and an instrument that cannot
observe says so instead of blaming the product.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable


#: The instrument took the call. Proves the wire works and nothing else.
COMMAND_SUCCESS = "COMMAND_SUCCESS"
#: The named effect was seen: the signal fired, the character arrived.
BEHAVIOR_SUCCESS = "BEHAVIOR_SUCCESS"
#: The game moved. State changed, a resource was spent, something now exists.
E2E_SUCCESS = "E2E_SUCCESS"
#: The product did not do the thing, and the instrument could see that clearly.
FAILED = "FAILED"
#: The instrument could not tell. Never a pass.
NOT_VALIDATED = "NOT_VALIDATED"

#: Strongest first. A claim is only as good as the weakest evidence under it.
LADDER = (E2E_SUCCESS, BEHAVIOR_SUCCESS, COMMAND_SUCCESS)

PASSING = frozenset({COMMAND_SUCCESS, BEHAVIOR_SUCCESS, E2E_SUCCESS})


class EvidenceError(ValueError):
    """A verdict was constructed that claims more than it can support."""


@dataclass
class Verdict:
    """One claim, with what backs it.

    `level` is what this proves. `observed` is what was actually seen -- named,
    so a reader can disagree. `blocked_by` names the instrument when the answer
    is NOT_VALIDATED, because "we could not tell" is only useful with "because".
    """

    action: str
    level: str
    observed: dict[str, Any] = field(default_factory=dict)
    reason: str = ""
    blocked_by: str = ""
    remedy: str = ""

    def __post_init__(self) -> None:
        if self.level == NOT_VALIDATED and not (self.blocked_by or self.reason):
            raise EvidenceError(
                f"{self.action}: NOT_VALIDATED without naming what blocked it. "
                "An unexplained non-answer is indistinguishable from a shrug, "
                "and a caller will read it as a failure of the product"
            )
        if self.level in (BEHAVIOR_SUCCESS, E2E_SUCCESS) and not self.observed:
            raise EvidenceError(
                f"{self.action}: claims {self.level} with nothing observed. "
                "That is the exact shape of the false pass this module exists "
                "to prevent -- a command that returned cleanly is "
                f"{COMMAND_SUCCESS}, no more"
            )

    @property
    def passed(self) -> bool:
        return self.level in PASSING

    @property
    def trustworthy(self) -> bool:
        """Whether this verdict says anything about the *product*.

        A NOT_VALIDATED says something about the harness. A COMMAND_SUCCESS says
        the wire works. Neither is evidence a game does what it should.
        """

        return self.level in (BEHAVIOR_SUCCESS, E2E_SUCCESS, FAILED)

    def to_dict(self) -> dict[str, Any]:
        return {
            "action": self.action,
            "level": self.level,
            "passed": self.passed,
            "trustworthy": self.trustworthy,
            "observed": self.observed,
            "reason": self.reason,
            "blockedBy": self.blocked_by,
            "remedy": self.remedy,
        }


#: How this ladder maps onto the one the release gate actually reads.
#:
#: There are two of them, and that is the finding rather than the design.
#: `rqe/models.py` carries NOT_VALIDATED -> STATICALLY_VALIDATED ->
#: RUNTIME_VALIDATED -> VISUALLY_VALIDATED -> E2E_VALIDATED, and every probe,
#: every artifact and the gate itself speak it. This module carries
#: COMMAND / BEHAVIOR / E2E / NOT_VALIDATED, and until now its only importer
#: was its own unit test -- the module that names the project's central idea
#: was wired to nothing.
#:
#: The two are not redundant. `models` grades *how a claim was measured*;
#: this grades *what the measurement observed*. A capture is
#: VISUALLY_VALIDATED and says nothing about whether the game changed; a
#: verdict is E2E_SUCCESS and says nothing about whether a human looked. So
#: they are kept and the relationship is stated, rather than one being deleted
#: and its distinction lost.
#:
#: The mapping is deliberately conservative: a verdict never claims a level
#: above what its own evidence supports, and NOT_VALIDATED maps to
#: NOT_VALIDATED, which the gate refuses.
GATE_LEVELS: dict[str, str] = {
    NOT_VALIDATED: "NOT_VALIDATED",
    FAILED: "RUNTIME_VALIDATED",
    COMMAND_SUCCESS: "STATICALLY_VALIDATED",
    BEHAVIOR_SUCCESS: "RUNTIME_VALIDATED",
    E2E_SUCCESS: "E2E_VALIDATED",
}


def gate_level(level: str) -> str:
    """The `rqe.models` validation level a verdict at `level` can support.

    `FAILED` maps to RUNTIME_VALIDATED rather than to nothing, because a
    failure that was *observed* is a real measurement of the product -- the
    gate needs to be able to record it as such, and the alternative is a
    refusal that reads as "we did not look".
    """

    try:
        return GATE_LEVELS[level]
    except KeyError:
        raise EvidenceError(f"unknown evidence level: {level}") from None


def as_evidence(verdict: Verdict, *, probe: str, category: str,
                severity: str = "major", source: str = "game-agent-bridge",
                run_id: str = "", build_hash: str = ""):
    """One verdict, as the `Evidence` record the release gate consumes.

    This is the seam that was missing. `evidence.py` described the distinction
    the whole engine is built on -- a command that was accepted is not a
    behaviour that was seen is not a game that changed -- and nothing could
    carry that distinction into the gate, so it was written down and never
    enforced.

    `conclusive` is the load-bearing field: a NOT_VALIDATED verdict is a
    failure of the *instrument*, and marking it inconclusive is what stops the
    gate reporting it as a failure of the product.
    """

    from .models import Evidence

    level = gate_level(verdict.level)
    if verdict.level == NOT_VALIDATED:
        status = "WARN"
    elif verdict.passed:
        status = "PASS"
    else:
        status = "FAIL"

    details = dict(verdict.observed)
    if verdict.blocked_by:
        details["blockedBy"] = verdict.blocked_by
    if verdict.remedy:
        details["remedy"] = verdict.remedy
    details["evidenceLevel"] = verdict.level

    return Evidence(
        id=f"{probe}.{verdict.action}",
        probe=probe,
        category=category,
        status=status,
        severity=severity,
        message=verdict.reason or verdict.action,
        source=source,
        validation_level=level,
        details=details,
        run_id=run_id or None,
        build_hash=build_hash or None,
        conclusive=verdict.level != NOT_VALIDATED,
    )


def not_validated(action: str, *, blocked_by: str, remedy: str = "") -> Verdict:
    """The instrument cannot answer. Say so, and name it."""

    return Verdict(action=action, level=NOT_VALIDATED, blocked_by=blocked_by,
                   reason=f"the instrument could not observe this: {blocked_by}",
                   remedy=remedy)


def from_bridge(action: str, payload: dict[str, Any], *,
                effect_keys: Iterable[str] = ()) -> Verdict:
    """Read a bridge response without believing more than it says.

    `effect_keys` are the fields whose presence means the effect was *seen*
    rather than merely requested -- `triggered`, `reached`, `touched`. A payload
    with `success: true` and none of them earns COMMAND_SUCCESS and nothing
    more, which is the demotion that stops a wire test reading as a game test.
    """

    if not isinstance(payload, dict):
        return not_validated(action, blocked_by="the command returned no object")

    # An instrument that named its own limitation is never a product verdict.
    reason = str(payload.get("reason") or "")
    if payload.get("requiresRealPlayer") is True:
        return not_validated(
            action,
            blocked_by="this command needs a Player and the session has none",
            remedy="start Play Solo; RunService:Run gives physics but no Player",
        )

    observed = {key: payload[key] for key in effect_keys
                if key in payload and payload[key] not in (None, False)}

    if payload.get("success") is True:
        if observed:
            return Verdict(action, BEHAVIOR_SUCCESS, observed=observed)
        return Verdict(
            action, COMMAND_SUCCESS,
            reason="the call was accepted; no effect field came back with it, "
                   "so this proves the wire and not the game",
        )

    if payload.get("success") is False:
        return Verdict(action, FAILED, observed=observed, reason=reason)

    return not_validated(
        action,
        blocked_by="the response carries no success field",
        remedy="give the primitive an observed effect to report, or have it "
               "return NOT_VALIDATED itself",
    )


def promote(verdict: Verdict, *, state_before: Any, state_after: Any,
            what: str, expect: str = "changed",
            probe_proven: bool = False) -> Verdict:
    """Raise a behaviour claim to end-to-end, if the game moved *the right way*.

    The step almost nothing does. A prompt that fires is a behaviour; a prompt
    that fires and leaves the player poorer is the game working.

    `expect` is why this takes a direction. The first version promoted on any
    difference, and the first live run it judged returned E2E_SUCCESS on a
    purchase where cash went from 20 to **49** -- income had accrued during the
    round trip and outran the price. Every field said the game worked. Nothing
    had been bought.

    "Something changed" is not "the thing happened", and on a live game with a
    clock running, something is always changing.
    """

    if verdict.level not in (BEHAVIOR_SUCCESS, COMMAND_SUCCESS):
        return verdict

    def refuse(why: str) -> Verdict:
        return Verdict(
            action=verdict.action, level=FAILED, observed=verdict.observed,
            reason=why)

    if state_before == state_after:
        # An unmoved probe is ambiguous, and the ambiguity is the whole point.
        #
        # It means either the game did nothing, or the probe cannot see what the
        # game did. Measured here: two purchases were called FAILED on "towers
        # 29 -> 29" while the game had built four towers -- the pad renames each
        # one to its catalogue id, so a count of models named "Tower" could
        # never move. The probe was blind and the verdict blamed the product,
        # which is exactly what `actor.interact` used to do.
        #
        # So a caller must attest that the probe has been seen to move. Without
        # that the answer is NOT_VALIDATED, because "I looked and saw nothing"
        # is only evidence when you can show you would have seen something.
        if not probe_proven:
            return not_validated(
                verdict.action,
                blocked_by=f"{what} did not move, and this probe has not been "
                           "shown capable of moving",
                remedy="exercise the probe against a known-positive case first, "
                       "then pass probe_proven=True; or probe the specific thing "
                       "the action creates rather than a shared counter")
        return refuse(
            f"{what} did not change ({state_before!r}); the effect fired and "
            "the game did not move, which is a no-op wearing a pass")

    if expect in ("decreased", "increased"):
        try:
            moved_down = float(state_after) < float(state_before)
        except (TypeError, ValueError):
            return not_validated(
                verdict.action,
                blocked_by=f"{what} is not a number, so {expect!r} cannot be checked",
                remedy="use expect='changed', or compare a numeric field")
        wrong = moved_down if expect == "increased" else not moved_down
        if wrong:
            return refuse(
                f"{what} went {state_before!r} -> {state_after!r}, which is not "
                f"{expect}. On a live game with a clock running something is "
                "always changing, so a bare difference proves nothing")

    observed = dict(verdict.observed)
    observed[what] = {"before": state_before, "after": state_after,
                      "expected": expect}
    return Verdict(action=verdict.action, level=E2E_SUCCESS, observed=observed)


def summarise(verdicts: Iterable[Verdict]) -> dict[str, Any]:
    """What a run proved, separated from what it merely attempted."""

    items = list(verdicts)
    counts: dict[str, int] = {}
    for verdict in items:
        counts[verdict.level] = counts.get(verdict.level, 0) + 1
    untrustworthy = [v.action for v in items if not v.trustworthy]
    return {
        "schemaVersion": 1,
        "total": len(items),
        "levels": counts,
        "provesSomethingAboutTheProduct": sum(1 for v in items if v.trustworthy),
        "instrumentCouldNotTell": [v.action for v in items
                                   if v.level == NOT_VALIDATED],
        "wireOnly": [v.action for v in items if v.level == COMMAND_SUCCESS],
        "note": (
            "COMMAND_SUCCESS proves the bridge, not the game. A run whose "
            "passes are mostly wire-level has tested itself"
        ) if untrustworthy else "every verdict here observed a real effect",
    }
