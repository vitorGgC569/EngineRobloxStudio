"""Behavioural specs for the modules mined from the licensed projects.

Executed as real Luau through the pinned runtime, not asserted against source.
Every one of these caught something the compiler did not: `TransactionJournal`
reached for `HttpService` while its own header claimed to be pure, and running
it said so in one line.

The cases chosen are the ones where being wrong is silent — a hold committed
twice, an achievement awarded twice, a cap that raises instead of limits, a
replication rule that defaults open. Those do not throw; they just quietly cost
somebody something.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestBoot(unittest.TestCase):
    def test_awaiting_something_already_signalled_returns_at_once(self) -> None:
        """The whole reason this is a latch and not a BindableEvent."""
        out = _run([FORGE / "Core"], """
            local Boot = Require("Boot")
            Boot.signal("world")
            assert(Boot.await("world", 1), "a signalled latch must return true")
            print('{"instant":true}')
        """)
        assert "instant" in out

    def test_signalling_twice_is_a_no_op(self) -> None:
        out = _run([FORGE / "Core"], """
            local Boot = Require("Boot")
            assert(Boot.signal("a") == true, "first signal is new")
            assert(Boot.signal("a") == false, "second signal must not re-fire")
            print('{"ok":true}')
        """)
        assert "ok" in out

    def test_a_missing_producer_is_reported_rather_than_raced(self) -> None:
        out = _run([FORGE / "Core"], """
            local Boot = Require("Boot")
            Boot.declare("props", { producedBy = "Scatter", requires = { "terrain" } })
            local problems = Boot.validate()
            assert(#problems == 1, "expected one problem, got " .. #problems)
            print(problems[1])
        """)
        assert "terrain" in out

    def test_a_cycle_is_found(self) -> None:
        out = _run([FORGE / "Core"], """
            local Boot = Require("Boot")
            Boot.declare("a", { producedBy = "A", requires = { "b" } })
            Boot.declare("b", { producedBy = "B", requires = { "a" } })
            local problems = Boot.validate()
            local cycles = 0
            for _, problem in problems do
                if string.find(problem, "cycle") then cycles += 1 end
            end
            assert(cycles > 0, "a cycle must be reported")
            print('{"cycle":true}')
        """)
        assert "cycle" in out


class TestClock(unittest.TestCase):
    def test_days_are_utc_and_stable(self) -> None:
        out = _run([FORGE / "Core"], """
            local Clock = Require("Clock")
            assert(Clock.dayNumber(86400 * 3) == 3, "day three")
            assert(Clock.dayStart(86400 * 3 + 500) == 86400 * 3, "day start")
            print('{"ok":true}')
        """)
        assert "ok" in out

    def test_the_daily_seed_is_the_same_all_day_and_different_tomorrow(self) -> None:
        """The property that lets every server derive the same shop."""
        out = _run([FORGE / "Core"], """
            local Clock = Require("Clock")
            local morning = Clock.dailySeed("shop", 86400 * 10 + 60)
            local evening = Clock.dailySeed("shop", 86400 * 10 + 80000)
            local tomorrow = Clock.dailySeed("shop", 86400 * 11 + 60)
            assert(morning == evening, "same day must give the same seed")
            assert(morning ~= tomorrow, "a new day must give a new seed")
            print('{"stable":true}')
        """)
        assert "stable" in out

    def test_different_salts_do_not_rotate_in_lockstep(self) -> None:
        out = _run([FORGE / "Core"], """
            local Clock = Require("Clock")
            local a = Clock.dailySeed("shop", 86400 * 10)
            local b = Clock.dailySeed("shops", 86400 * 10)
            assert(a ~= b, "a one-letter difference must not collide")
            print('{"distinct":true}')
        """)
        assert "distinct" in out

    def test_a_nil_expiry_is_permanent_not_expired(self) -> None:
        """Treating nil as expired silently deletes everything with no deadline."""
        out = _run([FORGE / "Core"], """
            local Clock = Require("Clock")
            assert(Clock.hasExpired(nil) == false, "nil must not be expired")
            assert(Clock.remaining(nil) == math.huge, "nil has no end")
            print('{"permanent":true}')
        """)
        assert "permanent" in out


class TestTransactionJournal(unittest.TestCase):
    def test_a_pending_hold_survives_and_a_committed_one_does_not_replay(self) -> None:
        out = _run([FORGE / "Save"], """
            local Journal = Require("TransactionJournal")
            local hold = Journal.open("trade", "7", { "sword" })
            assert(#Journal.pendingFor("7") == 1, "a pending hold is owed back")
            assert(Journal.commit(hold) == true, "first commit lands")
            assert(#Journal.pendingFor("7") == 0, "a committed hold is not owed")
            assert(Journal.commit(hold) == false, "a second commit must not re-settle")
            print('{"exactlyOnce":true}')
        """)
        assert "exactlyOnce" in out

    def test_ids_are_unique_so_reconciliation_can_dedup(self) -> None:
        out = _run([FORGE / "Save"], """
            local Journal = Require("TransactionJournal")
            local seen = {}
            for _ = 1, 200 do
                local hold = Journal.open("trade", "7", {})
                assert(seen[hold.holdId] == nil, "duplicate hold id: " .. hold.holdId)
                seen[hold.holdId] = true
            end
            print('{"unique":true}')
        """)
        assert "unique" in out

    def test_it_runs_with_no_roblox_services_at_all(self) -> None:
        """The header claims pure. This is what makes the claim testable."""
        out = _run([FORGE / "Save"], """
            local Journal = Require("TransactionJournal")
            Journal.open("x", "1", {})
            print('{"pure":true}')
        """)
        assert "pure" in out


class TestModifierPipeline(unittest.TestCase):
    def test_stages_run_in_order_and_a_cap_limits_rather_than_raises(self) -> None:
        out = _run([FORGE / "Progression"], """
            local Pipeline = Require("ModifierPipeline")
            Pipeline.define("payout", { "bonus", { "event", "multiply" }, { "cap", "cap" } })
            Pipeline.provide("payout", "bonus", function() return { amount = 50, label = "pass" } end)
            Pipeline.provide("payout", "event", function() return { amount = 2, label = "weekend" } end)
            Pipeline.provide("payout", "cap", function() return { amount = 250, label = "daily" } end)
            local total = Pipeline.resolve("payout", 100)
            assert(total == 250, "expected 250, got " .. tostring(total))

            -- A cap must never raise a value that is already under it.
            local small = Pipeline.resolve("payout", 1)
            assert(small == 102, "a cap must not raise: " .. tostring(small))
            print('{"ordered":true}')
        """)
        assert "ordered" in out

    def test_every_contribution_is_labelled(self) -> None:
        """The audit trail is the reason this exists rather than StatsDeriver."""
        out = _run([FORGE / "Progression"], """
            local Pipeline = Require("ModifierPipeline")
            Pipeline.define("dmg", { "gear" })
            Pipeline.provide("dmg", "gear", function() return { amount = 7, label = "sword" } end)
            local _, steps = Pipeline.resolve("dmg", 10)
            assert(#steps == 1 and steps[1].label == "sword", "the step must name its source")
            assert(steps[1].before == 10 and steps[1].after == 17, "before and after")
            print('{"audited":true}')
        """)
        assert "audited" in out

    def test_a_broken_provider_costs_its_own_bonus_and_nothing_else(self) -> None:
        out = _run([FORGE / "Progression"], """
            local Pipeline = Require("ModifierPipeline")
            Pipeline.define("dmg", { "gear" })
            Pipeline.provide("dmg", "gear", function() error("guild service is down") end)
            Pipeline.provide("dmg", "gear", function() return { amount = 5, label = "sword" } end)
            local total = Pipeline.resolve("dmg", 10)
            assert(total == 15, "a failed provider must not take the payout down")
            print('{"isolated":true}')
        """)
        assert "isolated" in out


class TestAchievements(unittest.TestCase):
    def test_tiers_are_awarded_once_and_never_again(self) -> None:
        out = _run([FORGE / "Progression"], """
            local Achievements = Require("Achievements")
            Achievements.define("slayer", { stat = "kills", tiers = { 10, 100, 1000 } })
            local profile = { kills = 150 }

            local first = Achievements.evaluate(profile)
            assert(#first == 2, "150 kills clears two tiers, got " .. #first)
            local second = Achievements.evaluate(profile)
            assert(#second == 0, "a second pass must award nothing")
            print('{"onceEver":true}')
        """)
        assert "onceEver" in out

    def test_an_achievement_added_later_fires_retroactively(self) -> None:
        """The veterans must not be the only players who never get it."""
        out = _run([FORGE / "Progression"], """
            local Achievements = Require("Achievements")
            local profile = { kills = 5000 }
            Achievements.define("veteran", { stat = "kills", target = 1000 })
            local awarded = Achievements.evaluate(profile)
            assert(#awarded == 1, "an existing counter must qualify at once")
            print('{"retroactive":true}')
        """)
        assert "retroactive" in out

    def test_a_higher_tier_is_not_skipped_past_a_missing_one(self) -> None:
        out = _run([FORGE / "Progression"], """
            local Achievements = Require("Achievements")
            Achievements.define("rich", { stat = "coins", tiers = { 100, 1000 } })
            local profile = { coins = 500 }
            local awarded = Achievements.evaluate(profile)
            assert(#awarded == 1 and awarded[1].tier == 1, "only tier one is earned")
            print('{"noSkip":true}')
        """)
        assert "noSkip" in out


class TestGlobalEffects(unittest.TestCase):
    def test_two_doublers_give_four_times(self) -> None:
        out = _run([FORGE / "LiveOps", FORGE / "Core"], """
            local Effects = Require("GlobalEffects")
            Effects.define("weekend", { coin = 2 })
            Effects.define("boss", { coin = 2 })
            Effects.apply("weekend", 60)
            Effects.apply("boss", 60)
            assert(Effects.aggregate("coin") == 4, "doublers multiply")
            print('{"stacked":true}')
        """)
        assert "stacked" in out

    def test_an_unaffected_axis_is_neutral_rather_than_absent(self) -> None:
        """So a caller can multiply unconditionally without checking."""
        out = _run([FORGE / "LiveOps", FORGE / "Core"], """
            local Effects = Require("GlobalEffects")
            assert(Effects.aggregate("xp") == 1, "an untouched multiplicative axis is 1")
            Effects.addsUp("luck")
            assert(Effects.aggregate("luck") == 0, "an untouched additive axis is 0")
            print('{"neutral":true}')
        """)
        assert "neutral" in out

    def test_reapplying_extends_rather_than_stacking_a_second_copy(self) -> None:
        out = _run([FORGE / "LiveOps", FORGE / "Core"], """
            local Effects = Require("GlobalEffects")
            Effects.define("weekend", { coin = 2 })
            Effects.apply("weekend", 60)
            Effects.apply("weekend", 60)
            assert(Effects.aggregate("coin") == 2, "two presses must not double the event")
            print('{"extended":true}')
        """)
        assert "extended" in out


class TestAreas(unittest.TestCase):
    def test_a_locked_area_says_why(self) -> None:
        out = _run([FORGE / "World", FORGE / "Core"], """
            local Areas = Require("Areas")
            Areas.define("hub", { safe = true })
            Areas.define("deep", { requires = { level = 12 } })
            Areas.satisfies = function() return false end
            local allowed, reason = Areas.mayEnter({}, "deep")
            assert(allowed == false, "must be refused")
            assert(string.find(reason, "level"), "the reason must name the requirement")
            print(reason)
        """)
        assert "level" in out

    def test_a_game_with_no_safe_area_says_so(self) -> None:
        """A configuration mistake whose symptom is a player falling for ever."""
        out = _run([FORGE / "World", FORGE / "Core"], """
            local Areas = Require("Areas")
            Areas.define("deep", {})
            assert(Areas.describe().hasNowhereSafe == true, "must be flagged")
            print('{"flagged":true}')
        """)
        assert "flagged" in out


class TestAutoTarget(unittest.TestCase):
    def test_facing_beats_distance(self) -> None:
        """The single weighting that makes combat feel like it obeys you."""
        out = _run([FORGE / "Combat"], """
            local AutoTarget = Require("AutoTarget")
            local from = CFrame.new(Vector3.new(0, 0, 0))
            local ahead = { instance = "ahead", position = from.LookVector * 20 }
            local beside = { instance = "beside", position = Vector3.new(6, 0, 0) }
            local picked = AutoTarget.pick(from, { beside, ahead }, { range = 40, arc = 150 })
            assert(picked == "ahead", "picked " .. tostring(picked))
            print('{"facing":true}')
        """)
        assert "facing" in out

    def test_anything_outside_the_arc_is_not_a_target(self) -> None:
        out = _run([FORGE / "Combat"], """
            local AutoTarget = Require("AutoTarget")
            local from = CFrame.new(Vector3.new(0, 0, 0))
            local behind = { instance = "behind", position = from.LookVector * -10 }
            local picked = AutoTarget.pick(from, { behind }, { range = 40, arc = 90 })
            assert(picked == nil, "a target behind you is not a target")
            print('{"arc":true}')
        """)
        assert "arc" in out


class TestStore(unittest.TestCase):
    def test_a_reducer_owns_its_slice_and_subscribers_hear_changes(self) -> None:
        out = _run([FORGE / "State", FORGE / "Core"], """
            local Store = Require("Store")
            Store.reducer("score", function(state, action)
                if action.type == "scored" then return (state or 0) + action.points end
                return state or 0
            end)
            Store.dispatch({ type = "scored", points = 10 })
            Store.dispatch({ type = "scored", points = 5 })
            assert(Store.get("score") == 15, "got " .. tostring(Store.get("score")))
            print('{"reduced":true}')
        """)
        assert "reduced" in out

    def test_a_thunk_can_dispatch_several_actions(self) -> None:
        out = _run([FORGE / "State", FORGE / "Core"], """
            local Store = Require("Store")
            Store.reducer("n", function(state, action)
                if action.type == "inc" then return (state or 0) + 1 end
                return state or 0
            end)
            Store.dispatch(function(dispatch)
                dispatch({ type = "inc" })
                dispatch({ type = "inc" })
            end)
            assert(Store.get("n") == 2, "got " .. tostring(Store.get("n")))
            print('{"thunk":true}')
        """)
        assert "thunk" in out


class TestReplication(unittest.TestCase):
    def test_an_action_with_no_rule_is_withheld(self) -> None:
        """The default that decides whether forgetting a rule leaks everything."""
        out = _run([FORGE / "State", FORGE / "Core"], """
            local Replication = Require("Replication")
            assert(Replication.openByDefault == false, "must default closed")
            assert(Replication.mayReceive({ type = "secret" }, {}) == false, "withheld")
            print('{"closed":true}')
        """)
        assert "closed" in out

    def test_a_rule_that_errors_withholds_rather_than_opens(self) -> None:
        out = _run([FORGE / "State", FORGE / "Core"], """
            local Replication = Require("Replication")
            Replication.rule("inventory", function() error("broken") end)
            assert(Replication.mayReceive({ type = "inventory" }, {}) == false,
                "a broken filter must not become an open door")
            print('{"failsClosed":true}')
        """)
        assert "failsClosed" in out


class TestMissionInstance(unittest.TestCase):
    def test_objectives_advance_in_order_and_the_run_closes_when_done(self) -> None:
        out = _run([FORGE / "Match", FORGE / "Core"], """
            local Mission = Require("MissionInstance")
            Mission.define("crypt", { objectives = { "door", "boss" } })
            local run = Mission.open("crypt")
            assert(Mission.advance(run, "boss") == false, "cannot skip an objective")
            assert(Mission.advance(run, "door") == true, "the current objective advances")
            assert(Mission.advance(run, "boss") == true, "then the next one")
            assert(run.state == "closed", "clearing the last objective closes the run")
            print('{"ordered":true}')
        """)
        assert "ordered" in out


if __name__ == "__main__":
    unittest.main()
