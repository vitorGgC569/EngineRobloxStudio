"""Git Worktree isolation manager for multi-agent execution.

Provides clean, isolated repository checkouts per agent task to avoid
file contention and workspace mutation conflicts during concurrent agent runs.
"""

from __future__ import annotations

import logging
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

LOGGER = logging.getLogger("rqe.orchestrator.worktree")


class WorktreeError(RuntimeError):
    """Raised when a Git worktree operation fails."""


@dataclass(frozen=True)
class AgentWorktree:
    agent_id: str
    branch: str
    path: Path
    base_commit: str

    def to_dict(self) -> dict[str, str]:
        return {
            "agentId": self.agent_id,
            "branch": self.branch,
            "path": str(self.path),
            "baseCommit": self.base_commit,
        }


class GitWorktreeManager:
    """Manages creation, execution, and cleanup of isolated Git worktrees."""

    def __init__(self, repo_root: Path | str) -> None:
        self.repo_root = Path(repo_root).resolve()

    def _run_git(self, *args: str, cwd: Path | None = None) -> str:
        cmd = ["git", *args]
        try:
            res = subprocess.run(
                cmd,
                cwd=str(cwd or self.repo_root),
                capture_output=True,
                text=True,
                check=False,
                encoding="utf-8",
                errors="replace",
            )
        except Exception as exc:
            raise WorktreeError(f"git command failed to launch: {' '.join(cmd)}: {exc}") from exc

        if res.returncode != 0:
            raise WorktreeError(
                f"git {' '.join(args)} failed (exit {res.returncode}):\n{res.stderr.strip()}"
            )
        return res.stdout.strip()

    def current_commit(self) -> str:
        return self._run_git("rev-parse", "HEAD")

    def create_worktree(
        self,
        agent_id: str,
        *,
        branch: str | None = None,
        target_dir: Path | None = None,
    ) -> AgentWorktree:
        """Create an isolated worktree and branch for an agent."""
        base_commit = self.current_commit()
        branch_name = branch or f"agent/{agent_id}"
        worktree_path = target_dir or (self.repo_root / ".tmp" / "worktrees" / agent_id)
        worktree_path.parent.mkdir(parents=True, exist_ok=True)

        # Ensure target dir is empty before adding worktree
        if worktree_path.exists():
            self.remove_worktree(worktree_path, force=True)

        self._run_git("worktree", "add", "-b", branch_name, str(worktree_path), "HEAD")
        return AgentWorktree(
            agent_id=agent_id,
            branch=branch_name,
            path=worktree_path,
            base_commit=base_commit,
        )

    def remove_worktree(
        self,
        worktree_path: Path | str,
        *,
        delete_branch: str | None = None,
        force: bool = True,
    ) -> bool:
        """Remove a worktree and prune Git metadata."""
        path = Path(worktree_path).resolve()
        try:
            flags = ["--force"] if force else []
            self._run_git("worktree", "remove", *flags, str(path))
        except WorktreeError as exc:
            LOGGER.warning("Could not cleanly remove worktree %s: %s", path, exc)
            self._run_git("worktree", "prune")

        if delete_branch:
            try:
                self._run_git("branch", "-D", delete_branch)
            except WorktreeError:
                pass
        return True


def worktree_for_agent(
    repo_root: Path | str,
    agent_id: str,
) -> Iterator[AgentWorktree]:
    """Context manager for temporary isolated agent worktree execution."""
    manager = GitWorktreeManager(repo_root)
    worktree = manager.create_worktree(agent_id)
    try:
        yield worktree
    finally:
        manager.remove_worktree(worktree.path, delete_branch=worktree.branch, force=True)
