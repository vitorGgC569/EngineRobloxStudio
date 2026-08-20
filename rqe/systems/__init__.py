"""The system composer: assemble a game's systems instead of writing them."""

from .composer import (
    SYSTEMS,
    Composition,
    CompositionError,
    SystemSpec,
    catalogue,
    compose,
    compose_and_verify,
    verify,
)

__all__ = [
    "SYSTEMS", "Composition", "CompositionError", "SystemSpec",
    "catalogue", "compose", "compose_and_verify", "verify",
]
