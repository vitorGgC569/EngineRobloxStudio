"""A NaN obtainable count must not produce NaN luck.

`obtainable <= 0` is false for NaN, so the function divides by NaN and
the result is NaN. A full collection of 1 out of 1 with bonus 1 still
returns 2.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLuckNanObtainable(unittest.TestCase):
    def test_nan_obtainable_returns_one_and_a_full_collection_returns_two(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Luck = Require("Luck")
            local nan = Luck.fromCompletion(1, 0/0, 1)
            assert(nan == 1, "nan obtainable must return 1, got " .. tostring(nan))
            local full = Luck.fromCompletion(1, 1, 1)
            assert(full == 2, "full collection must return 2, got " .. tostring(full))
            print('{"obtainable":true}')
        """)
        assert "obtainable" in out


if __name__ == "__main__":
    unittest.main()
