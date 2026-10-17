"""Operator-controlled capability gates for dangerous MCP surfaces.

These are deliberately process configuration, never tool arguments.  A model
must not be able to grant itself the authority it is requesting in the same
JSON payload.
"""

from __future__ import annotations

import os

from .server import ToolError


ARBITRARY_CODE_ENV = "RQE_MCP_ALLOW_ARBITRARY_CODE"
PUBLICATION_ENV = "RQE_MCP_ALLOW_PUBLICATION"


def enabled(environment_name: str) -> bool:
    """Accept only an explicit ``1``; misspellings fail closed."""

    return os.environ.get(environment_name, "").strip() == "1"


def require_arbitrary_code() -> None:
    if not enabled(ARBITRARY_CODE_ENV):
        raise ToolError(
            "arbitrary Studio execution is disabled; the operator must start "
            f"the MCP server with {ARBITRARY_CODE_ENV}=1"
        )


def require_publication() -> None:
    if not enabled(PUBLICATION_ENV):
        raise ToolError(
            "external publication is disabled; the operator must start the "
            f"MCP server with {PUBLICATION_ENV}=1"
        )
