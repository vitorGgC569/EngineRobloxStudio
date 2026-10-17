"""Exercise the real Luau limiter used by low-frequency gameplay remotes."""
import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]


class FractionalRateTests(unittest.TestCase):
    def test_fractional_rate_refills_a_whole_token_and_isolates_players(self):
        result = run_or_raise(ROOT, libraries=["forge/luau/Forge/Core"], body="""
            local now=0
            os={clock=function() return now end}
            local Sched=Require("Sched")
            local allow=Sched.bucket(.5)
            assert(allow("alice"), "first request is permanently blocked")
            assert(not allow("alice"), "burst escaped limiter")
            assert(allow("bob"), "player buckets are shared")
            now=1.9
            assert(not allow("alice"), "request admitted before two seconds")
            now=2
            assert(allow("alice"), "fractional refill never reached one token")
            assert(not allow("alice"), "refilled token was not consumed")
            now=100
            assert(allow("alice") and not allow("alice"), "idle time increased burst capacity")
            print("fractional rate passed")
        """)
        self.assertIn("fractional rate passed", result.stdout)
