"""RQE Studio Bridge: a real, bidirectional channel to a live Roblox Studio.

The hub is the only component allowed to claim RUNTIME evidence. Everything it
returns originates from a command that a Studio plugin actually executed against
a real DataModel, correlated by id and stamped with the Studio context it ran in.
"""

from .protocol import (
    PROTOCOL_VERSION,
    BridgeError,
    Command,
    ErrorCode,
    Response,
    new_command_id,
    new_session_id,
)

__all__ = [
    "PROTOCOL_VERSION",
    "BridgeError",
    "Command",
    "ErrorCode",
    "Response",
    "new_command_id",
    "new_session_id",
]
