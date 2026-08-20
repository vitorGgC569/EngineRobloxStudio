"""The economy designer: session targets in, curves out.

`Progression.pacing` already answers the forward question -- given a cost ladder
and an income rate, how long does each tier take. That leaves the designer doing
the hard half by hand: guessing costs, running the simulation, reading the times,
adjusting, repeating. It converges eventually and the numbers that come out are
whichever ones the guesser got tired at.

This solves the inverse. A designer states what the *play* should feel like --
the first upgrade in 45 seconds, the ladder finished in 90 minutes -- and the
curve is derived from it.

The arithmetic is small and worth stating plainly, including the part that was
wrong first. `Progression` treats a tier's cost as a **cumulative threshold**,
not a price: `remaining = tier.cost - spent`, so what a player actually pays for
tier `i` is the *difference* between consecutive costs. Income compounds over
owned tiers, so the rate entering tier `i` is `base * m^(i-1)`. Then:

    paid_i = cost_i - cost_(i-1)
    t_i    = paid_i / (base * m^(i-1))

Asking for the times to be geometric with ratio `k` makes the *differences*
geometric with ratio `r = k * m`, and the costs their running sum:

    paid_i = (t_1 * base) * r^(i-1)
    cost_i = paid_1 * (r^i - 1) / (r - 1)
    total  = t_1 * (k^N - 1) / (k - 1)

so fixing `t_1`, `total` and `N` fixes `k`. `k` comes out of a bisection rather
than a formula because the sum is not invertible in closed form, and bisection
on a monotone function lands inside a second on a 90-minute ladder.

The first version of this file made the *costs* geometric instead of the
differences, which is the natural mistake and produces a ladder whose second
tier is quicker than its first. Nothing about the solver could have revealed
that; the verification below did, on its first run.

**Nothing here is trusted on its own.** Every solution is handed to the shipped
`Progression` module through the Luau harness and the resulting times are
compared against the targets that produced them. A solver that agreed with
itself would be a second implementation of pacing, drifting from the one the
game runs; checking against the real module is what makes the output a
measurement rather than a claim.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class EconomyError(ValueError):
    """The targets cannot be met, and the report says why."""


#: A ladder whose steps shrink is one where the last tier is cheaper in play
#: time than the first, which reads as the game running out rather than opening
#: up. Ratios at or below this are refused before any solving happens.
MIN_STEP_RATIO = 1.0

#: Above this, each tier takes more than three times the last. Players read that
#: as a paywall whether or not one exists.
MAX_STEP_RATIO = 3.0

#: How close the verification has to land. Pacing is derived from float
#: arithmetic on both sides and the Luau module rounds differently, so an exact
#: match would fail on noise rather than on error.
VERIFY_TOLERANCE = 0.02


@dataclass(frozen=True)
class Targets:
    """What the session should feel like, in the designer's own terms."""

    tiers: int
    first_tier_seconds: float
    #: When the ladder should be finished. The document's "prestige: 90 min".
    total_minutes: float
    income_multiplier: float = 1.0
    base_income_per_second: float = 1.0

    def __post_init__(self) -> None:
        if self.tiers < 2:
            raise EconomyError("a ladder needs at least two tiers to have a curve")
        if self.first_tier_seconds <= 0:
            raise EconomyError("the first tier must take a positive amount of time")
        if self.total_minutes <= 0:
            raise EconomyError("the ladder must take a positive amount of time")
        if self.base_income_per_second <= 0:
            raise EconomyError("income must be positive or nothing is ever earned")
        if self.income_multiplier <= 0:
            raise EconomyError("the income multiplier must be positive")

        floor = self.first_tier_seconds * self.tiers / 60.0
        if self.total_minutes < floor:
            # Refused rather than solved into a shrinking ladder. Every tier
            # would have to be quicker than the one before, which is a game that
            # gets easier as it goes.
            raise EconomyError(
                f"{self.tiers} tiers at {self.first_tier_seconds:.0f}s each already exceed "
                f"{self.total_minutes:.0f} minutes; the ladder would have to shrink, which "
                f"reads as the game running out. Raise the total above {floor:.1f} minutes "
                f"or lower the first tier"
            )

    @property
    def total_seconds(self) -> float:
        return self.total_minutes * 60.0


def _solve_ratio(tiers: int, first: float, total: float) -> float:
    """The per-tier time ratio `k` that lands the ladder on its total.

    Bisection on a strictly increasing function of k. Newton would be faster and
    would need a derivative and a starting guess that does not diverge; the
    ladder is at most a few dozen tiers, so faster is not the constraint.
    """

    def elapsed(k: float) -> float:
        if abs(k - 1.0) < 1e-12:
            return first * tiers
        return first * (k ** tiers - 1.0) / (k - 1.0)

    low, high = 1.0, 2.0
    # Grow the bracket rather than assuming one. A steep target -- a long ladder
    # in a short time -- needs a ratio well above any constant somebody guessed.
    while elapsed(high) < total and high < 100.0:
        high *= 1.5
    if elapsed(high) < total:
        raise EconomyError(
            f"no geometric ladder of {tiers} tiers reaches {total / 60:.0f} minutes from a "
            f"{first:.0f}s first tier without each step exceeding 100x the last"
        )

    for _ in range(200):
        middle = (low + high) / 2.0
        if elapsed(middle) < total:
            low = middle
        else:
            high = middle
    return (low + high) / 2.0


@dataclass
class EconomyDesign:
    """A solved economy, and how far it landed from what was asked."""

    targets: Targets
    tier_costs: tuple[float, ...]
    cost_ratio: float
    step_ratio: float
    predicted_seconds: tuple[float, ...] = ()
    verified: dict[str, Any] = field(default_factory=dict)
    problems: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.problems

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "ok": self.ok,
            "targets": {
                "tiers": self.targets.tiers,
                "firstTierSeconds": self.targets.first_tier_seconds,
                "totalMinutes": self.targets.total_minutes,
                "incomeMultiplier": self.targets.income_multiplier,
                "baseIncomePerSecond": self.targets.base_income_per_second,
            },
            "tierCosts": [round(cost, 2) for cost in self.tier_costs],
            "costRatio": round(self.cost_ratio, 4),
            "stepRatio": round(self.step_ratio, 4),
            "predictedSeconds": [round(value, 2) for value in self.predicted_seconds],
            "verified": self.verified,
            "problems": list(self.problems),
            "note": (
                "the costs are solved from the targets; the times are then measured by "
                "running the shipped Progression module, not by trusting the solver"
            ),
        }

    def summary(self) -> str:
        lines = [
            f"{'OK' if self.ok else 'PROBLEMS'}  {self.targets.tiers} tiers, "
            f"first {self.targets.first_tier_seconds:.0f}s, "
            f"total {self.targets.total_minutes:.0f}min, "
            f"each step {self.step_ratio:.2f}x the last"
        ]
        if self.verified:
            lines.append(
                f"  verified against Progression: total "
                f"{self.verified.get('totalSeconds', 0) / 60:.1f}min"
                f" (asked {self.targets.total_minutes:.1f}min)"
            )
        for problem in self.problems:
            lines.append(f"  problem: {problem}")
        return "\n".join(lines)


def design(targets: Targets) -> EconomyDesign:
    """Solve the cost ladder. No simulation yet -- see `verify`."""

    step_ratio = _solve_ratio(
        targets.tiers, targets.first_tier_seconds, targets.total_seconds
    )
    cost_ratio = step_ratio * targets.income_multiplier

    # Costs are cumulative thresholds, so the geometric sequence is what the
    # player *pays* at each tier and the costs are its running sum. Making the
    # costs themselves geometric is the natural mistake and yields a second tier
    # quicker than the first.
    first_paid = targets.first_tier_seconds * targets.base_income_per_second
    costs: list[float] = []
    running = 0.0
    for index in range(targets.tiers):
        running += first_paid * (cost_ratio ** index)
        costs.append(running)
    costs = tuple(costs)
    predicted = tuple(
        targets.first_tier_seconds * (step_ratio ** index) for index in range(targets.tiers)
    )

    problems: list[str] = []
    if step_ratio > MAX_STEP_RATIO:
        problems.append(
            f"each tier takes {step_ratio:.2f}x the one before it; above {MAX_STEP_RATIO:.0f}x "
            "players read the curve as a paywall whether or not one exists. Add tiers, or "
            "raise the first-tier time"
        )
    if step_ratio <= MIN_STEP_RATIO:
        problems.append(
            f"each tier takes {step_ratio:.2f}x the one before it, so the ladder does not "
            "open up; the last tier is no more of an achievement than the first"
        )

    return EconomyDesign(
        targets=targets, tier_costs=costs, cost_ratio=cost_ratio,
        step_ratio=step_ratio, predicted_seconds=predicted, problems=problems,
    )


def verify(root: Path, design_result: EconomyDesign, *, policy: dict[str, Any] | None = None,
           timeout: float = 60.0) -> EconomyDesign:
    """Run the solved ladder through the shipped `Progression` module.

    The solver's own arithmetic is not evidence. What the game will do is what
    the game's own code says it will do, so the curve goes through the Luau the
    experience actually runs and the answer comes back measured.
    """

    from ..luau_harness import HarnessError, run

    body = """
    local Progression = Require("Progression")
    local tiers = {}
    for index, cost in ipairs(COSTS) do
        table.insert(tiers, {
            id = "t" .. index, index = index, displayName = "T" .. index,
            cost = cost, currency = "cash", incomeMultiplier = MULTIPLIER,
        })
    end
    local ladder = Progression.define(tiers)
    local report = Progression.pacing(ladder, INCOME)
    local steps = {}
    for _, step in ipairs(report.steps) do
        table.insert(steps, string.format("%.4f", step.secondsFromPrevious))
    end
    local problems = {}
    for _, problem in ipairs(Progression.pacingProblems(report, POLICY)) do
        table.insert(problems, string.format("%q", problem))
    end
    print(string.format(
        '{"totalSeconds":%.4f,"worstRatio":%.4f,"steps":[%s],"problems":[%s]}',
        report.totalSeconds, report.worstRatio,
        table.concat(steps, ","), table.concat(problems, ",")))
    """
    try:
        result = run(
            root,
            libraries=["roblox/lib/GameKit"],
            body=body,
            data={
                "COSTS": [round(cost, 6) for cost in design_result.tier_costs],
                "INCOME": design_result.targets.base_income_per_second,
                "MULTIPLIER": design_result.targets.income_multiplier,
                "POLICY": policy or {},
            },
            timeout=timeout,
        )
    except HarnessError as exc:
        raise EconomyError(f"the ladder could not be verified: {exc}") from exc

    if not result.ok:
        raise EconomyError(
            "Progression rejected the solved ladder:\n"
            + (result.stderr.strip() or "no output")
        )

    lines = result.json_lines()
    if not lines:
        raise EconomyError("verification produced no report")
    measured = lines[-1]

    problems = list(design_result.problems)
    measured_total = float(measured.get("totalSeconds", 0.0))
    asked = design_result.targets.total_seconds
    drift = abs(measured_total - asked) / asked if asked else 1.0
    if drift > VERIFY_TOLERANCE:
        # The solver and the shipped module disagree. Reported rather than
        # smoothed: it means one of them is wrong about the game's own
        # arithmetic, and shipping the curve anyway would bake in whichever.
        problems.append(
            f"the solved ladder measures {measured_total / 60:.1f} minutes against the "
            f"{design_result.targets.total_minutes:.1f} asked ({drift:.1%} off); the solver "
            "and the shipped Progression module do not agree"
        )
    problems.extend(str(item) for item in (measured.get("problems") or []))

    design_result.verified = {
        "totalSeconds": round(measured_total, 2),
        "totalMinutes": round(measured_total / 60.0, 2),
        "worstRatio": measured.get("worstRatio"),
        "stepSeconds": [round(float(v), 2) for v in (measured.get("steps") or [])],
        "driftFromTarget": round(drift, 4),
        "source": "roblox/lib/GameKit/Progression.lua, through the headless harness",
    }
    design_result.problems = problems
    return design_result


def solve(root: Path, targets: Targets, *, policy: dict[str, Any] | None = None) -> EconomyDesign:
    """Solve and verify in one call. The normal entry point."""

    return verify(root, design(targets), policy=policy)


# ------------------------------------------------------------- variance


#: How much faster an efficient player is than an average one, and how much
#: slower a distracted one is. Not fitted to anything -- these are the bounds a
#: designer should be shown, so the curve is judged on the spread it produces
#: rather than on the single number the average hides.
EFFICIENCY_BAND = (0.75, 1.6)


def session_spread(design_result: EconomyDesign, *, session_minutes: float,
                   samples: int = 10_000) -> dict[str, Any]:
    """Where players actually get to in one session, across efficiencies.

    A ladder tuned so the *average* player reaches tier 5 puts a quarter of
    players somewhere else entirely, and the tail is what a first session is
    judged on. Deterministic rather than sampled with an RNG: efficiencies are
    swept evenly across the band, so two runs of the same curve give the same
    answer and a changed spread is a change somebody made.
    """

    if session_minutes <= 0:
        raise EconomyError("a session must have positive length")
    if samples < 2:
        raise EconomyError("a spread needs at least two samples")

    low, high = EFFICIENCY_BAND
    budget = session_minutes * 60.0
    reached: list[int] = []
    for index in range(samples):
        efficiency = low + (high - low) * (index / (samples - 1))
        spent = 0.0
        tier = 0
        for seconds in design_result.predicted_seconds:
            spent += seconds / efficiency
            if spent > budget:
                break
            tier += 1
        reached.append(tier)

    reached.sort()
    def percentile(fraction: float) -> int:
        return reached[min(int(len(reached) * fraction), len(reached) - 1)]

    histogram: dict[int, int] = {}
    for tier in reached:
        histogram[tier] = histogram.get(tier, 0) + 1

    return {
        "schemaVersion": 1,
        "sessionMinutes": session_minutes,
        "samples": samples,
        "efficiencyBand": list(EFFICIENCY_BAND),
        "tiersReached": {
            "p10": percentile(0.10),
            "median": percentile(0.50),
            "p90": percentile(0.90),
            "min": reached[0],
            "max": reached[-1],
        },
        "distribution": {str(tier): count for tier, count in sorted(histogram.items())},
        "note": (
            "efficiencies swept evenly rather than sampled randomly, so the same curve "
            "always gives the same spread and a change is a change somebody made"
        ),
    }
