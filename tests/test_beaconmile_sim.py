"""Beaconmile's shift rules, run as Luau.

The scenarios in the game's Smoke module only execute inside Studio. These
are the same rules through the pinned runtime, so a broken take, feed, or
tick fails here without a playtest.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "games" / "beaconmile" / "src" / "shared"


def _run(body: str) -> str:
    return run_or_raise(ROOT, libraries=[SHARED], body=body).stdout


class BeaconmileSimTests(unittest.TestCase):
    def test_one_take_fills_the_hands_and_a_second_is_refused(self) -> None:
        out = _run("""
            local Sim = Require("Sim")
            local Config = Require("Config")
            local profile = Sim.newProfile()
            assert(Sim.takeCoal(profile) == true, "a new profile could not take coal")
            assert(profile.carried == 1, "a take did not pick up one coal")
            assert(Sim.takeCoal(profile) ~= true, "a second take was accepted")
            assert(profile.carried == Config.carryMax, "a refused take changed the load")
            print('{"take":true}')
        """)
        self.assertIn("take", out)

    def test_feeding_bend_spends_the_coal_and_lengthens_that_beacon(self) -> None:
        out = _run("""
            local Sim = Require("Sim")
            local Config = Require("Config")
            local profile = Sim.newProfile()
            assert(Sim.takeCoal(profile) == true, "take")
            local before = profile.beacons.bend
            assert(Sim.feed(profile, "bend") == true, "feed")
            assert(profile.carried == 0, "coal remained")
            local grown = math.min(before + Config.beacon.feedSeconds, Config.beacon.burnCap)
            assert(profile.beacons.bend == grown, "bend did not gain the configured feed")
            assert(profile.beacons.bend > before, "bend did not get longer")
            print('{"feed":true}')
        """)
        self.assertIn("feed", out)

    def test_a_full_beacon_does_not_take_the_coal(self) -> None:
        out = _run("""
            local Sim = Require("Sim")
            local Config = Require("Config")
            local profile = Sim.newProfile()
            assert(Sim.takeCoal(profile) == true, "take")
            profile.beacons.bend = Config.beacon.burnCap
            local carried = profile.carried
            assert(Sim.feed(profile, "bend") ~= true, "a full beacon accepted coal")
            assert(profile.carried == carried, "a full beacon spent coal")
            assert(profile.beacons.bend == Config.beacon.burnCap, "a refused feed changed the cap")
            print('{"capped":true}')
        """)
        self.assertIn("capped", out)

    def test_an_unknown_beacon_keeps_the_coal(self) -> None:
        out = _run("""
            local Sim = Require("Sim")
            local profile = Sim.newProfile()
            assert(Sim.takeCoal(profile) == true, "take")
            local carried = profile.carried
            local bend = profile.beacons.bend
            assert(Sim.feed(profile, "nope") ~= true, "unknown beacon accepted coal")
            assert(profile.carried == carried, "refused feed spent coal")
            assert(profile.beacons.bend == bend, "refused feed changed bend")
            print('{"kept":true}')
        """)
        self.assertIn("kept", out)

    def test_emptying_a_beacon_loses_and_a_lit_shift_wins(self) -> None:
        out = _run("""
            local Sim = Require("Sim")
            local Config = Require("Config")
            local lost = Sim.newProfile()
            local longest = 0
            for _, remaining in lost.beacons do
                if remaining > longest then
                    longest = remaining
                end
            end
            Sim.tick(lost, longest)
            assert(lost.outcome == "lost", "emptying a beacon did not lose the shift")

            local won = Sim.newProfile()
            for id, remaining in won.beacons do
                won.beacons[id] = remaining + Config.shiftSeconds
            end
            Sim.tick(won, Config.shiftSeconds)
            assert(won.outcome == "won", "a lit shift was not won")
            for _, remaining in won.beacons do
                assert(remaining > 0, "a beacon went out during the winning tick")
            end
            print('{"shift":true}')
        """)
        self.assertIn("shift", out)

    def test_a_step_past_the_clock_does_not_burn_fuel_after_the_win(self) -> None:
        out = _run("""
            local Sim = Require("Sim")
            local Config = Require("Config")
            local profile = Sim.newProfile()
            profile.elapsed = Config.shiftSeconds - 0.1
            for id in profile.beacons do
                profile.beacons[id] = 0.2
            end
            Sim.tick(profile, 0.25)
            assert(profile.outcome == "won", "the shift should end while the beacons are still lit")
            for _, remaining in profile.beacons do
                assert(remaining > 0, "fuel after the finish line was burned")
            end
            print('{"finish":true}')
        """)
        self.assertIn("finish", out)

    def test_a_finished_shift_can_start_again(self) -> None:
        out = _run("""
            local Sim = Require("Sim")
            local profile = Sim.newProfile()
            profile.outcome = "lost"
            profile.carried = 1
            profile.elapsed = 50
            profile.beacons.bend = 0
            Sim.restart(profile)
            assert(profile.outcome == "running", "restart did not reopen the shift")
            assert(profile.carried == 0, "restart kept the coal")
            assert(profile.elapsed == 0, "restart kept the clock")
            assert(profile.beacons.bend > 0, "restart left a dead beacon")
            assert(Sim.takeCoal(profile) == true, "a restarted shift refused coal")
            print('{"restart":true}')
        """)
        self.assertIn("restart", out)

    def test_reopen_refuses_a_shift_that_is_still_running(self) -> None:
        out = _run("""
            local Sim = Require("Sim")
            local profile = Sim.newProfile()
            profile.elapsed = 12
            profile.carried = 1
            assert(Sim.reopen(profile) ~= true, "a live shift was reopened")
            assert(profile.elapsed == 12, "a refused reopen reset the clock")
            assert(profile.carried == 1, "a refused reopen dropped the coal")
            profile.outcome = "won"
            assert(Sim.reopen(profile) == true, "a finished shift did not reopen")
            assert(profile.outcome == "running", "reopen left the old outcome")
            assert(profile.elapsed == 0, "reopen kept the clock")
            assert(profile.carried == 0, "reopen kept the coal")
            print('{"reopen":true}')
        """)
        self.assertIn("reopen", out)
