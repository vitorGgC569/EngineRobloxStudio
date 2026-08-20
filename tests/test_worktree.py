"""Unit tests for GitWorktreeManager."""

import unittest
from pathlib import Path
from rqe.orchestrator.worktree import GitWorktreeManager, AgentWorktree


class TestGitWorktreeManager(unittest.TestCase):
    def setUp(self):
        self.root = Path(".").resolve()
        self.manager = GitWorktreeManager(self.root)

    def test_current_commit_resolves(self):
        commit = self.manager.current_commit()
        self.assertTrue(len(commit) >= 7)

    def test_worktree_creation_and_removal(self):
        agent_id = "test-agent-wt-01"
        try:
            wt = self.manager.create_worktree(agent_id)
            self.assertIsInstance(wt, AgentWorktree)
            self.assertEqual(wt.agent_id, agent_id)
            self.assertTrue(wt.path.exists())
            self.assertEqual(wt.base_commit, self.manager.current_commit())
        finally:
            removed = self.manager.remove_worktree(
                self.root / ".tmp" / "worktrees" / agent_id,
                delete_branch=f"agent/{agent_id}",
                force=True,
            )
            self.assertTrue(removed)


if __name__ == "__main__":
    unittest.main()
