"""Content generation: a whole catalogue, coherently, from a family declaration."""

from .generator import (
    KINDS,
    RARITIES,
    ROLES,
    Catalogue,
    ContentError,
    ContentSchema,
    Entry,
    balance,
    build,
    consistency,
    drop_table,
    from_model,
    generate,
)

__all__ = [
    "KINDS", "RARITIES", "ROLES", "Catalogue", "ContentError", "ContentSchema",
    "Entry", "balance", "build", "consistency", "drop_table", "from_model", "generate",
]
