"""The helm's device conversion is one tested function.

Keys, a gamepad stick and a finger each send a different shape of "go
there"; BoatInput is the only place they are reconciled, so it is the only
place worth testing. The keyboard numbers are a regression surface: the
original helm read W/S/A/D with exact increments, and a boat that suddenly
feels different is a defect, not a polish.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
SHARED = ROOT / "games/tidebound/src/shared"


def _run(body: str) -> str:
    return run_or_raise(ROOT, libraries=[SHARED], body=body).stdout


class TestBoatInput(unittest.TestCase):
    def test_keyboard_keeps_the_original_feel(self) -> None:
        out = _run("""
            local BoatInput = Require("BoatInput")

            local w = BoatInput.fromKeyboard(true, false, false, false)
            assert(w.throttle == 1 and w.steer == 0, "W must be full ahead")
            local s = BoatInput.fromKeyboard(false, true, false, false)
            assert(s.throttle == -0.55 and s.steer == 0, "S must be scaled reverse")
            local ws = BoatInput.fromKeyboard(true, true, false, false)
            --: 1 - 0.55 in doubles is 0.44999999999999996, which is what the
            --: original helm computed too: the legacy feel, ULP and all.
            assert(math.abs(ws.throttle - (1 - 0.55)) < 1e-12,
                "W+S was always ~0.45, got " .. tostring(ws.throttle))
            local a = BoatInput.fromKeyboard(false, false, true, false)
            assert(a.steer == 1 and a.throttle == 0, "A must steer left")
            local d = BoatInput.fromKeyboard(false, false, false, true)
            assert(d.steer == -1 and d.throttle == 0, "D must steer right")
            local ad = BoatInput.fromKeyboard(false, false, true, true)
            assert(ad.steer == 0, "A+D must cancel")
            print('{"keys":"ok"}')
        """)
        assert "keys" in out

    def test_stick_maps_signs_deadzone_and_curve(self) -> None:
        out = _run("""
            local BoatInput = Require("BoatInput")

            --: Gamepad convention: pushing the stick forward reports +Y.
            local up = BoatInput.fromStick(0, 1)
            assert(up.throttle == 1 and up.steer == 0, "stick up must be full ahead")
            local down = BoatInput.fromStick(0, -1)
            assert(down.throttle == -0.55 and down.steer == 0, "stick down is scaled reverse")
            local right = BoatInput.fromStick(1, 0)
            assert(right.steer == -1 and right.throttle == 0,
                "x right-positive must steer -1: positive yaw is left")

            --: Radial deadzone: silent inside the ring, and no jump at the edge.
            local edge = BoatInput.fromStick(BoatInput.DEADZONE, 0)
            assert(edge.throttle == 0 and edge.steer == 0, "the ring's edge must be silent")
            local inside = BoatInput.fromStick(0.1, 0.1)
            assert(inside.throttle == 0 and inside.steer == 0, "inside the ring must be silent")
            local just = BoatInput.fromStick(0.2, 0)
            assert(just.steer < 0 and just.steer > -0.05, "just outside the ring steers gently")

            --: The curve softens the middle without changing the extremes.
            assert(math.abs(BoatInput.curve(0.58) - 0.58 ^ BoatInput.CURVE) < 1e-12,
                "curve is the ramp the helm actually uses")
            assert(BoatInput.curve(0.58) < 0.58, "the curve must soften the middle")
            assert(BoatInput.curve(1) == 1 and BoatInput.curve(0) == 0, "extremes are fixed points")
            assert(BoatInput.curve(-0.5) < 0, "sign is preserved")

            --: Out-of-range input clamps to the edge, not past it.
            local wild = BoatInput.fromStick(1.5, -2)
            local hard = BoatInput.fromStick(1, -1)
            assert(math.abs(wild.throttle - hard.throttle) < 1e-12
                and math.abs(wild.steer - hard.steer) < 1e-12,
                "clamped input must equal the edge exactly")
            local tame = BoatInput.fromStick(0.6, -0.8)
            assert(math.abs(tame.throttle - (-0.8 * BoatInput.REVERSE_SCALE)) < 1e-12,
                "reverse on the stick is scaled like everything backward")

            --: Screen pixels flip to helm axes exactly once, here.
            local dx, dy = BoatInput.stickFromDrag(0, -50, 100)
            assert(dx == 0 and dy == 0.5, "a finger dragged up is ahead")
            local dx2, dy2 = BoatInput.stickFromDrag(30, 40, 100)
            assert(dx2 == 0.3 and dy2 == -0.4, "down and right are astern and starboard")
            local dx3, dy3 = BoatInput.stickFromDrag(400, -400, 100)
            assert(dx3 == 1 and dy3 == 1, "drag beyond the ring clamps to it")
            print('{"stick":"ok"}')
        """)
        assert "stick" in out

    def test_resolve_precedence(self) -> None:
        out = _run("""
            local BoatInput = Require("BoatInput")
            local keys = { forward = true, back = false, left = false, right = false }

            --: A finger that is down is driving, even at the ring's centre --
            --: coasting is a decision and the keys must not override it.
            local coast = BoatInput.resolve({ keys = keys, stick = { x = 1, y = 0 }, touch = { x = 0, y = 0 } })
            assert(coast.throttle == 0 and coast.steer == 0,
                "a touch at the centre must mute both keys and stick")

            --: A deflected stick beats the keys; a resting stick hands the
            --: helm back to them.
            local stick = BoatInput.resolve({ keys = keys, stick = { x = 0, y = 1 } })
            assert(stick.throttle == 1, "stick up must beat W")
            local resting = BoatInput.resolve({ keys = keys, stick = { x = 0.05, y = 0.05 } })
            assert(resting.throttle == 1, "inside the ring the keys answer")

            local nothing = BoatInput.resolve({})
            assert(nothing.throttle == 0 and nothing.steer == 0, "no sources is no motion")

            local touch = BoatInput.resolve({ touch = { x = 0, y = -1 } })
            assert(math.abs(touch.throttle + BoatInput.REVERSE_SCALE) < 1e-12,
                "touch reverse is scaled like every backward")
            print('{"resolve":"ok"}')
        """)
        assert "resolve" in out


if __name__ == "__main__":
    unittest.main()
