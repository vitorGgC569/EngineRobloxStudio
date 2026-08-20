"""Model Context Protocol, in both directions.

The engine is a **client** of Roblox's built-in Studio MCP server, because that
server has privileges a third-party plugin cannot get -- synthesised input above
all. It is also a **server** to whichever agent is driving it, because a typed
surface only one CLI can reach is a script, not a platform.

The rule that governs the client direction is short and absolute: *wrap, do not
trust*. Nothing a peer returns becomes evidence until it has been re-typed,
stamped with its source, and bound to a run and a build.
"""

from .client import (
    ADOPTED_TOOLS,
    FEDERATED_SOURCE,
    FederatedResult,
    McpClientError,
    StdioPeer,
    StudioMcpClient,
    ToolDescriptor,
)
from .server import EngineMcpServer, Tool, ToolError
from .tools import build_server, register_engine_tools

__all__ = [
    "ADOPTED_TOOLS",
    "EngineMcpServer",
    "FEDERATED_SOURCE",
    "FederatedResult",
    "McpClientError",
    "StdioPeer",
    "StudioMcpClient",
    "Tool",
    "ToolDescriptor",
    "ToolError",
    "build_server",
    "register_engine_tools",
]
