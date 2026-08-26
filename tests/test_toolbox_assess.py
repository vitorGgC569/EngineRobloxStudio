"""The filter that decides which Creator Store results are worth opening.

`search` talks to Roblox and is not exercised here; `assess` is pure and holds
every judgement that matters, including the one that keeps executable code out
of a game.
"""

from __future__ import annotations

import unittest

from rqe.assets.toolbox import TRIANGLE_BUDGET, assess


def candidate(**overrides) -> dict:
    """A result that passes everything, so each test changes one thing."""
    base = {
        "id": 1, "name": "crate", "triangles": 900, "meshes": 1,
        "hasScripts": False, "scripts": 0, "tools": 0, "audio": 0,
        "free": True, "endorsed": False, "verified": False,
        "upVotes": 0, "downVotes": 0, "approval": 0,
    }
    base.update(overrides)
    return base


class AssessCase(unittest.TestCase):
    def test_a_clean_model_passes(self) -> None:
        self.assertEqual(assess(candidate())["verdict"], "ok")

    # -------------------------------------------------------------- scripts
    def test_scripts_are_refused_by_default(self) -> None:
        """The oldest attack on the platform: a model that works, and a
        `require(assetId)` inside it that pulls code after review."""
        verdict = assess(candidate(hasScripts=True, scripts=3))
        self.assertEqual(verdict["verdict"], "reject")
        self.assertIn("contains scripts", verdict["reasons"])

    def test_a_script_count_alone_is_enough_to_refuse(self) -> None:
        """`hasScripts` and `instanceCounts.script` disagree on some assets;
        either one saying yes has to be enough."""
        self.assertEqual(assess(candidate(hasScripts=False, scripts=2))["verdict"], "reject")

    def test_allowing_scripts_demands_review_rather_than_approving(self) -> None:
        verdict = assess(candidate(hasScripts=True, scripts=1), allow_scripts=True)
        self.assertEqual(verdict["verdict"], "review-scripts")
        self.assertEqual(verdict["reasons"], [])
        self.assertTrue(verdict["warnings"])

    def test_score_can_never_overrule_a_refusal(self) -> None:
        """A scoring system that could outvote the security gate would."""
        loaded = candidate(hasScripts=True, endorsed=True, verified=True,
                           upVotes=5000, downVotes=0, approval=100)
        verdict = assess(loaded)
        self.assertEqual(verdict["verdict"], "reject")
        self.assertGreater(verdict["score"], 4)

    # ------------------------------------------------------------ triangles
    def test_the_budget_follows_the_role(self) -> None:
        """The same rock is fine as a hero prop and not as scatter."""
        rock = candidate(triangles=5_000)
        self.assertEqual(assess(rock, role="hero")["verdict"], "ok")
        self.assertEqual(assess(rock, role="scatter")["verdict"], "reject")

    def test_a_rejection_names_the_numbers(self) -> None:
        verdict = assess(candidate(triangles=9_000), role="prop")
        self.assertIn("9000", verdict["reasons"][0])
        self.assertIn(str(TRIANGLE_BUDGET["prop"]), verdict["reasons"][0])

    def test_an_explicit_budget_overrides_the_role(self) -> None:
        self.assertEqual(
            assess(candidate(triangles=9_000), role="prop", triangles=20_000)["verdict"], "ok")

    def test_no_geometry_is_a_warning_not_a_refusal(self) -> None:
        """Part-built models are legitimate, and look exactly like empty ones."""
        verdict = assess(candidate(triangles=0, meshes=0))
        self.assertEqual(verdict["verdict"], "review")
        self.assertTrue(any("no mesh" in w for w in verdict["warnings"]))

    # ---------------------------------------------------------------- votes
    def test_no_votes_is_no_signal_rather_than_zero_approval(self) -> None:
        """Roblox reports 0% for an unvoted asset. Treating that as disapproval
        rejects everything new and everything niche."""
        unvoted = candidate(upVotes=0, downVotes=0, approval=0)
        self.assertEqual(assess(unvoted, approval=80)["verdict"], "ok")

    def test_a_poor_record_is_refused_once_there_is_one(self) -> None:
        disliked = candidate(upVotes=10, downVotes=90, approval=10)
        self.assertEqual(assess(disliked, approval=80)["verdict"], "reject")

    def test_approval_is_only_checked_when_asked_for(self) -> None:
        self.assertEqual(
            assess(candidate(upVotes=10, downVotes=90, approval=10))["verdict"], "ok")

    # --------------------------------------------------------------- others
    def test_paid_models_are_refused(self) -> None:
        self.assertIn("not free", assess(candidate(free=False))["reasons"])

    def test_tools_and_audio_are_flagged(self) -> None:
        self.assertEqual(assess(candidate(tools=1))["verdict"], "review")
        self.assertTrue(any("audio" in w for w in assess(candidate(audio=2))["warnings"]))

    # --------------------------------------------------------------- score
    def test_endorsement_outranks_a_verified_badge(self) -> None:
        endorsed = assess(candidate(endorsed=True))["score"]
        verified = assess(candidate(verified=True))["score"]
        self.assertGreater(endorsed, verified)

    def test_a_wide_margin_beats_a_perfect_handful(self) -> None:
        """100% of three votes must not outrank 92% of four hundred."""
        few = assess(candidate(upVotes=3, downVotes=0, approval=100))["score"]
        many = assess(candidate(upVotes=368, downVotes=32, approval=92))["score"]
        self.assertGreater(many, few)

    def test_cheaper_geometry_breaks_a_tie_but_no_more(self) -> None:
        cheap = assess(candidate(triangles=200))["score"]
        dear = assess(candidate(triangles=5_900))["score"]
        self.assertGreater(cheap, dear)
        # ...and never enough to outweigh the crowd.
        popular = assess(candidate(triangles=5_900, upVotes=400, downVotes=0,
                                   approval=100))["score"]
        self.assertGreater(popular, cheap)


if __name__ == "__main__":
    unittest.main()
