"""`forge find`: the command CLAUDE.md tells every agent to run first.

It had no tests, and the relevance model at its centre did not do what its own
docstring said. Three of the four camelCase examples in that docstring were
false, in the direction that matters: searching for "hold a weapon in the hand"
could never match `RightHand` inside `Rig.grip` -- and preventing exactly that
rewrite is the reason the module exists.

So the word splitter is pinned example by example, and the two queries this
repository has a written history of getting wrong are pinned as rankings.
"""

from __future__ import annotations

import unittest

from forge.cli.find import (
    COVERAGE_FLOOR,
    FUNCTION_CAP,
    SHELF_TITLES,
    _count,
    _coverage,
    _covered,
    _words,
    render,
    search,
)


class WordSplittingTests(unittest.TestCase):
    """Every example in the comment on `_WORD`, asserted rather than claimed."""

    CASES = {
        "DailyRewardCalendar": ("daily", "reward", "calendar"),
        "RightHand": ("right", "hand"),
        "dailySeed": ("daily", "seed"),
        "HandGenerator": ("hand", "generator"),
        "Handler": ("handler",),
    }

    def test_camel_case_comes_apart_into_the_words_somebody_typed(self):
        for identifier, expected in self.CASES.items():
            with self.subTest(identifier=identifier):
                self.assertEqual(_words(identifier), expected)

    def test_hand_matches_a_hand_and_not_a_handler(self):
        # The four claims the old regular expression made. It got one right.
        self.assertEqual(_covered(["hand"], "RightHand"), 1)
        self.assertEqual(_covered(["hand"], "HandGenerator"), 1)
        self.assertEqual(_covered(["hand"], "hand.CFrame"), 1)
        self.assertEqual(_covered(["hand"], "Handler"), 0)
        self.assertEqual(_covered(["hand"], "RebirthHandler"), 0)

    def test_punctuation_and_underscores_are_word_breaks(self):
        self.assertEqual(_words("net_event.fire"), ("net", "event", "fire"))

    def test_counting_is_positions_and_covering_is_distinct_words(self):
        text = "daily daily reward"
        self.assertEqual(_count(["daily", "reward"], text), 3)
        self.assertEqual(_covered(["daily", "reward"], text), 2)


class CoverageTests(unittest.TestCase):
    def test_answering_the_whole_query_scores_full(self):
        self.assertEqual(_coverage(["a", "b"], "a b"), 1.0)

    def test_answering_none_of_it_falls_to_the_floor_not_to_zero(self):
        # `Rig.grip` is the right answer to "weld a weapon into the hand" on the
        # strength of one word, so a zero multiplier would be wrong.
        self.assertEqual(_coverage(["x", "y"], "nothing"), COVERAGE_FLOOR)

    def test_more_of_the_query_always_scores_higher(self):
        one = _coverage(["a", "b", "c", "d"], "a")
        three = _coverage(["a", "b", "c", "d"], "a b c")
        self.assertLess(one, three)

    def test_an_empty_query_does_not_divide_by_zero(self):
        self.assertEqual(_coverage([], "anything"), 1.0)


class RankingTests(unittest.TestCase):
    """The two queries with a written history of ranking wrongly."""

    def _engine_names(self, query, limit=8):
        return [hit.name for hit in search(query, limit=limit).get("engine", [])]

    def test_the_module_named_after_the_query_comes_first(self):
        # `Core.Clock` used to win this, on two function names containing
        # "daily" and "day", over a module literally called
        # DailyRewardCalendar.
        names = self._engine_names("daily login reward calendar")
        self.assertEqual(names[0], "DailyRewardCalendar")

    def test_the_hand_query_surfaces_what_was_rewritten_by_hand(self):
        # CLAUDE.md's own story: `Rig.grip`, `Camera.Viewmodel` and a joint
        # poser were all written again by hand. All three must be reachable
        # from the sentence somebody would actually type.
        names = self._engine_names("hold a weapon in the hand")
        for wanted in ("Rig", "Viewmodel", "Weapon"):
            self.assertIn(wanted, names)

    def test_a_weak_signal_cannot_accumulate_past_a_strong_one(self):
        self.assertLessEqual(FUNCTION_CAP, 100)


class ShelfTests(unittest.TestCase):
    """All four shelves, because two of them were unreachable from one door."""

    def test_the_second_library_is_searched_too(self):
        # 19 of the 45 games here are written against roblox/lib, and it was
        # not in the corpus: an agent asking whether an economy existed was
        # shown Forge.Economy and never told about GameKit.Economy.
        results = search("economy currency wallet balance")
        self.assertIn("library", results)
        names = [hit.name for hit in results["library"]]
        self.assertTrue(any(name.startswith("GameKit") for name in names), names)

    def test_the_engine_is_searched_too(self):
        results = search("economy currency wallet balance")
        self.assertIn("engine", results)

    def test_kits_are_searched_and_named(self):
        results = search("zombie survival infected")
        self.assertIn("kits", results)
        self.assertIn("infected", [hit.name for hit in results["kits"]])

    def test_every_shelf_that_can_be_returned_has_a_title(self):
        # A shelf with no title renders as a KeyError in front of the user.
        produced = set()
        for query in ("economy currency wallet", "zombie survival infected",
                      "daily login reward calendar", "weapon hand grip"):
            produced.update(search(query))
        self.assertTrue(produced)
        self.assertTrue(produced <= set(SHELF_TITLES), produced - set(SHELF_TITLES))

    def test_a_query_matching_nothing_says_so_plainly(self):
        text = render("zzzqqqxxx", search("zzzqqqxxx"))
        self.assertIn("nothing matches", text)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
