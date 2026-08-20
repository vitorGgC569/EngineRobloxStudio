"""Scene-level critique: does a capture look like a game or a test map."""

from .critic import (
    CALIBRATION,
    PRODUCTION_SCORE,
    SceneCritique,
    SceneCriticError,
    critique_scene,
    gates,
)

__all__ = [
    "CALIBRATION", "PRODUCTION_SCORE", "SceneCritique", "SceneCriticError",
    "critique_scene", "gates",
]
