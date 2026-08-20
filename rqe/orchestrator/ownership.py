"""Exclusive write ownership with Windows-safe path comparison."""

from __future__ import annotations

import re
import threading
import unicodedata
from collections.abc import Iterable


_DRIVE_PATH = re.compile(r"^[A-Za-z]:")


def canonical_write_path(value: str) -> str:
    """Return a case-folded repository-relative path.

    Production currently runs on Windows, where path ownership cannot treat
    `Map.lua` and `map.lua` as different files.  Parent traversal and absolute
    paths are rejected before an agent starts rather than resolved after it has
    already written outside its declared scope.
    """

    if not isinstance(value, str) or not value.strip():
        raise ValueError("write path must be a non-empty string")
    raw = value.strip().replace("\\", "/")
    if raw.startswith("/") or raw.startswith("//") or _DRIVE_PATH.match(raw):
        raise ValueError(f"write path must be repository-relative: {value!r}")

    parts: list[str] = []
    for part in raw.split("/"):
        if part in {"", "."}:
            continue
        if part == "..":
            raise ValueError(f"write path may not traverse a parent: {value!r}")
        normalized = unicodedata.normalize("NFC", part).casefold()
        if not normalized:
            raise ValueError(f"write path has an empty component: {value!r}")
        parts.append(normalized)
    if not parts:
        raise ValueError(f"write path resolves to the repository root: {value!r}")
    return "/".join(parts)


def _conflicts(left: str, right: str) -> bool:
    left_parts = left.split("/")
    right_parts = right.split("/")
    shorter = min(len(left_parts), len(right_parts))
    return left_parts[:shorter] == right_parts[:shorter]


class OwnershipConflict(RuntimeError):
    def __init__(self, task_id: str, requested_path: str, owner_id: str, owned_path: str) -> None:
        super().__init__(
            f"task {task_id!r} cannot own {requested_path!r}; "
            f"it conflicts with {owned_path!r} owned by {owner_id!r}"
        )
        self.task_id = task_id
        self.requested_path = requested_path
        self.owner_id = owner_id
        self.owned_path = owned_path


class OwnershipRegistry:
    """Process-local invariant store; a durable adapter can wrap this API."""

    def __init__(self) -> None:
        self._held: dict[str, tuple[str, ...]] = {}
        self._lock = threading.RLock()

    def acquire(self, task_id: str, write_set: Iterable[str]) -> tuple[str, ...]:
        if not isinstance(task_id, str) or not task_id.strip():
            raise ValueError("task id must not be empty")
        requested = tuple(sorted({canonical_write_path(path) for path in write_set}))
        if not requested:
            raise ValueError("implementation task writeSet must not be empty")

        with self._lock:
            previous = self._held.get(task_id)
            if previous is not None:
                if previous == requested:
                    return previous
                raise RuntimeError(f"task {task_id!r} already owns a different writeSet")

            for requested_path in requested:
                for owner_id, owned_paths in self._held.items():
                    for owned_path in owned_paths:
                        if _conflicts(requested_path, owned_path):
                            raise OwnershipConflict(task_id, requested_path, owner_id, owned_path)
            self._held[task_id] = requested
            return requested

    def release(self, task_id: str) -> tuple[str, ...]:
        with self._lock:
            return self._held.pop(task_id, ())

    def snapshot(self) -> dict[str, tuple[str, ...]]:
        with self._lock:
            return dict(self._held)
