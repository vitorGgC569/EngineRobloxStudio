"""The economy designer.

The layer's claim is that a designer states how the session should *feel* and
the curve follows. What makes that trustworthy is not the solver -- it is that
every solution is measured against the `Progression` module the game actually
runs, rather than against the solver's own arithmetic.

That check earned its place immediately. The first implementation made the
tier *costs* geometric, which is the natural reading and is wrong: `Progression`
treats cost as a cumulative threshold, so what a player pays is the difference
between consecutive costs. The solver was internally consistent and produced a
ladder whose second tier was quicker than its first. Only the comparison against
the shipped module could show it, and it did, on the first run.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.economy import (
    MAX_STEP_RATIO,
    EconomyError,
    Targets,
    design,
    session_spread,
    solve,
)
from rqe.luau_check import ToolchainUnavailable, ensure_compiler

REPO = Path(__file__).resolve().parents[1]


class TestTargets(unittest.TestCase):
    def test_a_ladder_needs_more_than_one_tier(self):
        with self.assertRaises(EconomyError):
            Targets(tiers=1, first_tier_seconds=45, total_minutes=90)

    def test_impossible_targets_are_refused_with_the_arithmetic(self):
        """Eight tiers at 45s each is already six minutes. Asking for five would
        need every tier quicker than the last, which is a game that gets easier
        as it goes."""

        with self.assertRaises(EconomyError) as caught:
            Targets(tiers=8, first_tier_seconds=45, total_minutes=5)
        self.assertIn("shrink", str(caught.exception))

    def test_zero_income_is_refused(self):
        with self.assertRaises(EconomyError):
            Targets(tiers=8, first_tier_seconds=45, total_minutes=90,
                    base_income_per_second=0)


class TestSolver(unittest.TestCase):
    def test_the_ladder_rises(self):
        result = design(Targets(tiers=8, first_tier_seconds=45, total_minutes=90))
        self.assertEqual(list(result.tier_costs), sorted(result.tier_costs))
        self.assertEqual(list(result.predicted_seconds), sorted(result.predicted_seconds))

    def test_the_first_tier_lands_on_its_target(self):
        result = design(Targets(tiers=8, first_tier_seconds=45, total_minutes=90))
        self.assertAlmostEqual(result.predicted_seconds[0], 45.0, places=4)

    def test_the_total_lands_on_its_target(self):
        result = design(Targets(tiers=10, first_tier_seconds=30, total_minutes=60))
        self.assertAlmostEqual(sum(result.predicted_seconds), 60 * 60, delta=1.0)

    def test_a_curve_too_steep_to_read_as_progress_is_flagged(self):
        """Above three times per tier players read a paywall whether or not one
        exists, so it is reported rather than silently returned."""

        result = design(Targets(tiers=4, first_tier_seconds=10, total_minutes=120))
        self.assertGreater(result.step_ratio, MAX_STEP_RATIO)
        self.assertTrue(any("paywall" in problem for problem in result.problems))

    def test_solving_is_deterministic(self):
        targets = Targets(tiers=8, first_tier_seconds=45, total_minutes=90)
        self.assertEqual(design(targets).tier_costs, design(targets).tier_costs)

    def test_costs_are_cumulative_thresholds_not_prices(self):
        """The mistake the verification caught. `Progression` subtracts what the
        player already spent, so the geometric sequence is the differences."""

        result = design(Targets(tiers=6, first_tier_seconds=45, total_minutes=60))
        paid = [result.tier_costs[0]] + [
            result.tier_costs[i] - result.tier_costs[i - 1]
            for i in range(1, len(result.tier_costs))
        ]
        ratios = [paid[i] / paid[i - 1] for i in range(1, len(paid))]
        for ratio in ratios:
            self.assertAlmostEqual(ratio, ratios[0], places=6)


class TestVerificationAgainstTheShippedModule(unittest.TestCase):
    """The property that makes the output a measurement rather than a claim."""

    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(REPO)
        except ToolchainUnavailable as exc:
            raise unittest.SkipTest(f"no Luau toolchain: {exc}") from exc

    def test_the_solved_ladder_measures_what_was_asked(self):
        targets = Targets(tiers=8, first_tier_seconds=45, total_minutes=90,
                          income_multiplier=1.15)
        result = solve(REPO, targets)
        self.assertTrue(result.ok, result.problems)
        self.assertLess(result.verified["driftFromTarget"], 0.02)
        self.assertAlmostEqual(result.verified["totalMinutes"], 90.0, delta=2.0)

    def test_the_measured_steps_match_the_predicted_ones(self):
        """If these diverge, the solver has become a second implementation of
        pacing and the two will drift."""

        result = solve(REPO, Targets(tiers=6, first_tier_seconds=30, total_minutes=45,
                                     income_multiplier=1.2))
        for predicted, measured in zip(result.predicted_seconds, result.verified["stepSeconds"]):
            self.assertAlmostEqual(predicted, measured, delta=max(1.0, predicted * 0.02))

    def test_the_measured_ladder_never_shrinks(self):
        """The exact defect the first implementation shipped: a second tier
        quicker than the first."""

        result = solve(REPO, Targets(tiers=8, first_tier_seconds=45, total_minutes=90,
                                     income_multiplier=1.15))
        steps = result.verified["stepSeconds"]
        self.assertEqual(steps, sorted(steps))

    def test_the_verification_names_its_source(self):
        result = solve(REPO, Targets(tiers=5, first_tier_seconds=20, total_minutes=20))
        self.assertIn("Progression.lua", result.verified["source"])

    def test_an_income_multiplier_changes_the_costs_but_not_the_times(self):
        """The multiplier is how fast income compounds, so the same felt pacing
        needs steeper costs. If the times moved, the solver would be ignoring
        it."""

        flat = solve(REPO, Targets(tiers=6, first_tier_seconds=30, total_minutes=45,
                                   income_multiplier=1.0))
        steep = solve(REPO, Targets(tiers=6, first_tier_seconds=30, total_minutes=45,
                                    income_multiplier=1.4))
        self.assertGreater(steep.tier_costs[-1], flat.tier_costs[-1])
        self.assertAlmostEqual(
            flat.verified["totalMinutes"], steep.verified["totalMinutes"], delta=1.0)


class TestSessionSpread(unittest.TestCase):
    def test_the_spread_is_reported_rather_than_the_average(self):
        """A ladder tuned so the average player reaches tier 5 puts a quarter of
        players somewhere else, and the tail is what a first session is judged
        on."""

        result = design(Targets(tiers=10, first_tier_seconds=20, total_minutes=40))
        spread = session_spread(result, session_minutes=10)
        self.assertIn("p10", spread["tiersReached"])
        self.assertIn("p90", spread["tiersReached"])
        self.assertLessEqual(spread["tiersReached"]["p10"], spread["tiersReached"]["p90"])

    def test_a_longer_session_reaches_further(self):
        result = design(Targets(tiers=12, first_tier_seconds=20, total_minutes=60))
        short = session_spread(result, session_minutes=5)["tiersReached"]["median"]
        long = session_spread(result, session_minutes=30)["tiersReached"]["median"]
        self.assertGreater(long, short)

    def test_the_spread_is_deterministic(self):
        """Sampled with an RNG, two runs of one curve would differ and a changed
        spread could not be attributed to a change anybody made."""

        result = design(Targets(tiers=8, first_tier_seconds=30, total_minutes=45))
        first = session_spread(result, session_minutes=12)
        second = session_spread(result, session_minutes=12)
        self.assertEqual(first["distribution"], second["distribution"])

    def test_a_session_with_no_length_is_refused(self):
        result = design(Targets(tiers=8, first_tier_seconds=30, total_minutes=45))
        with self.assertRaises(EconomyError):
            session_spread(result, session_minutes=0)


if __name__ == "__main__":
    unittest.main()
