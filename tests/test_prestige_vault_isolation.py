"""Unlock rewards passed to PrestigeVault.new must not stay live.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. Renaming a reward after new, or renaming the table seal
returns, must not change the next unlock.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPrestigeVaultIsolation(unittest.TestCase):
    def test_caller_and_returned_rewards_do_not_rename_the_unlock(self) -> None:
        """The stored final_upgrader stays final_upgrader after either table is renamed."""
        out = _run([FORGE / "Progression"], """
            local PrestigeVault = Require("PrestigeVault")
            local reward = { id = "final_upgrader" }
            local vault = PrestigeVault.new({
                requiredLife = 100,
                milestoneUnlocks = { [10] = { reward } },
            })
            reward.id = "hacked"
            local first = vault:seal({}, 10)
            assert(first.unlocked[1].id == "final_upgrader", "unlock id was " .. tostring(first.unlocked[1].id))
            first.unlocked[1].id = "hacked"
            local second = vault:seal({}, 10)
            assert(second.unlocked[1].id == "final_upgrader", "next unlock id was " .. tostring(second.unlocked[1].id))
            print('{"vault":true}')
        """)
        assert "vault" in out


if __name__ == "__main__":
    unittest.main()
