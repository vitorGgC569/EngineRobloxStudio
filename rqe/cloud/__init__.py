"""Roblox-hosted execution: the engine's backend that needs no local machine.

The bridge drives one Studio on one desktop. This package drives Roblox's own
infrastructure instead, which is what makes CI, parallel runs and the two-games
generality proof possible at the same time rather than one after another.
"""

from .luau_execution import (
    CloudConfig,
    LuauExecutionClient,
    LuauExecutionError,
    TaskResult,
    TaskState,
)
from .open_cloud import CloudResult, OpenCloudClient, Outcome, summarise

__all__ = [
    "CloudConfig",
    "CloudResult",
    "OpenCloudClient",
    "Outcome",
    "summarise",
    "LuauExecutionClient",
    "LuauExecutionError",
    "TaskResult",
    "TaskState",
]
