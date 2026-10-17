"""Quest definitions must stay sealed after register.

Executed as real Luau through the pinned runtime. A shallow clone keeps the
stages array and each objective shared with the caller, so raising a goal
after register quietly changes how many events finish the quest.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestQuestEngineIsolation(unittest.TestCase):
    def test_a_later_goal_edit_does_not_rewrite_the_quest(self) -> None:
        out = _run([FORGE / "Progression"], """
            local QuestEngine = Require("QuestEngine")
            local engine = QuestEngine.new()
            local objective = { kind = "count", targetTag = "ore", goal = 2 }
            local def = {
                id = "mine",
                stages = { { objective = objective } },
            }
            engine:register(def)
            objective.goal = 99
            local state = engine:start("mine")
            assert(state, "start")
            engine:reportEvent(state, "ore", true)
            engine:reportEvent(state, "ore", true)
            assert(state.done == true, "two ore events must finish the registered goal of 2")

            engine:get("mine").stages[1].objective.goal = 99
            local again = engine:start("mine")
            assert(again, "fresh start")
            engine:reportEvent(again, "ore", true)
            engine:reportEvent(again, "ore", true)
            assert(again.done == true, "editing get() must not raise the stored goal")
            print('{"quest":true}')
        """)
        self.assertIn("quest", out)


if __name__ == "__main__":
    unittest.main()
