"""Sourcing: reuse before generate, with the licence decided first."""

from .registry import (
    AUTHORED_ROLES,
    LICENCES,
    SOURCEABLE_ROLES,
    STRUCTURAL_ROLES,
    SOURCES,
    Decision,
    SourcingError,
    attributions,
    decide,
    policy,
    sources_for,
)
from .resolver import (
    SEMANTIC_CUES,
    SourceBinding,
    SourceResolution,
    resolve_plan_sources,
)

__all__ = [
    "AUTHORED_ROLES", "LICENCES", "SOURCEABLE_ROLES", "STRUCTURAL_ROLES", "SOURCES",
    "Decision", "SourcingError", "attributions", "decide", "policy",
    "sources_for", "SEMANTIC_CUES", "SourceBinding", "SourceResolution",
    "resolve_plan_sources",
]
