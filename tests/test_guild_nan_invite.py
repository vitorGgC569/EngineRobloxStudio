"""A NaN user id must not join a guild.

`members[0/0]` is never found on the next lookup because NaN is not equal
to itself, so invite would add a member exile cannot see.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestGuildNanInvite(unittest.TestCase):
    def test_nan_id_does_not_join_and_a_real_id_does(self) -> None:
        out = _run([FORGE / "Social"], """
            local GuildModel = Require("GuildModel")
            local guild = GuildModel.new()
            local state = GuildModel.create("North")
            state.members[1] = 3
            local nanResult = guild:invite(state, 1, 0/0)
            assert(nanResult == nil, "nan invite must return nil")
            assert(state.members[1] == 3, "leader rank must stay 3, got " .. tostring(state.members[1]))
            local ok = guild:invite(state, 1, 9)
            assert(ok ~= nil and ok.members[9] == 1, "invite 9 must return member rank 1, got " .. tostring(ok and ok.members[9]))
            print('{"invite":true}')
        """)
        assert "invite" in out


if __name__ == "__main__":
    unittest.main()
