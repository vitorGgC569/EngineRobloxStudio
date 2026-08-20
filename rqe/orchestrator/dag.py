"""Dependency graph and readiness rules for orchestration tasks."""

from __future__ import annotations

from collections.abc import Iterable, Mapping

from .models import TaskSpec, TaskStatus


class TaskGraphError(ValueError):
    pass


_FAILED_DEPENDENCY_STATES = {
    TaskStatus.FAILED,
    TaskStatus.BLOCKED,
    TaskStatus.UNSUPPORTED,
    TaskStatus.UNCERTAIN,
    TaskStatus.CANCELLED,
}


class TaskGraph:
    """Validated acyclic task graph.

    Missing status records are treated as PENDING.  This is fail-closed: a
    dependent task cannot become ready because its prerequisite disappeared
    from a process-local status dictionary.
    """

    def __init__(self, tasks: Iterable[TaskSpec]) -> None:
        self._tasks: dict[str, TaskSpec] = {}
        for task in tasks:
            if task.id in self._tasks:
                raise TaskGraphError(f"duplicate task id: {task.id}")
            self._tasks[task.id] = task
        if not self._tasks:
            raise TaskGraphError("task graph must not be empty")
        for task in self._tasks.values():
            missing = sorted(set(task.blocked_by) - set(self._tasks))
            if missing:
                raise TaskGraphError(f"task {task.id!r} has missing dependencies: {', '.join(missing)}")
        self._assert_acyclic()

    @property
    def tasks(self) -> tuple[TaskSpec, ...]:
        return tuple(self._tasks[key] for key in sorted(self._tasks))

    def _assert_acyclic(self) -> None:
        visiting: set[str] = set()
        visited: set[str] = set()

        def visit(task_id: str, trail: tuple[str, ...]) -> None:
            if task_id in visited:
                return
            if task_id in visiting:
                cycle = " -> ".join((*trail, task_id))
                raise TaskGraphError(f"task dependency cycle: {cycle}")
            visiting.add(task_id)
            for dependency in self._tasks[task_id].blocked_by:
                visit(dependency, (*trail, task_id))
            visiting.remove(task_id)
            visited.add(task_id)

        for task_id in sorted(self._tasks):
            visit(task_id, ())

    @staticmethod
    def _status(statuses: Mapping[str, TaskStatus], task_id: str) -> TaskStatus:
        value = statuses.get(task_id, TaskStatus.PENDING)
        if not isinstance(value, TaskStatus):
            raise TaskGraphError(f"invalid status for task {task_id!r}: {value!r}")
        return value

    def ready_tasks(self, statuses: Mapping[str, TaskStatus]) -> tuple[TaskSpec, ...]:
        ready: list[TaskSpec] = []
        for task in self.tasks:
            if self._status(statuses, task.id) is not TaskStatus.PENDING:
                continue
            if all(self._status(statuses, dependency) is TaskStatus.SUCCEEDED for dependency in task.blocked_by):
                ready.append(task)
        return tuple(ready)

    def blocked_by_failure(self, statuses: Mapping[str, TaskStatus]) -> dict[str, tuple[str, ...]]:
        blocked: dict[str, tuple[str, ...]] = {}
        for task in self.tasks:
            if self._status(statuses, task.id) is not TaskStatus.PENDING:
                continue
            failures = tuple(
                dependency
                for dependency in task.blocked_by
                if self._status(statuses, dependency) in _FAILED_DEPENDENCY_STATES
            )
            if failures:
                blocked[task.id] = failures
        return blocked
