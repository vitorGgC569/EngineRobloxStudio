"""A lottery entry must have a name.

`add` stores any id, including the empty string, and `roll` can then
return an entry with no name. Only a non-empty string may be inserted.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryEmptyId(unittest.TestCase):
    def test_empty_id_is_refused_and_a_named_entry_still_rolls(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local lottery = Lottery.new()
            local ok = pcall(function()
                lottery:add("", { weight = 1 })
            end)
            assert(ok == false, "empty id must be refused")
            lottery:add("common", { weight = 1 })
            local rolled = lottery:roll(function()
                return 0
            end, {})
            assert(rolled == "common", "roll must return common, got " .. tostring(rolled))
            print('{"id":true}')
        """)
        assert "id" in out


if __name__ == "__main__":
    unittest.main()
