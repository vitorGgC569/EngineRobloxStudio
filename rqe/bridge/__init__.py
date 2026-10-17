"""Game Agent Bridge: observations, actions, memory and evidence."""

from .core import GameAgentBridge
from .adapters import HeadlessGameAdapter, StudioGameAdapter
from .studio_mcp import (
    FederatedStudioTransport,
    RobloxStudioMcpTransport,
    StdioMcpClient,
)

__all__ = [
    "GameAgentBridge",
    "HeadlessGameAdapter",
    "StudioGameAdapter",
    "StdioMcpClient",
    "RobloxStudioMcpTransport",
    "FederatedStudioTransport",
]

