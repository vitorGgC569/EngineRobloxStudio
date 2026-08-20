"""World authoring and scene composition: describe it, let the engine build it."""

from .authoring import (
    KNOWN_KINDS,
    Landmark,
    PlanResult,
    Region,
    Route,
    WorldSpec,
    WorldSpecError,
    load_spec,
    plan,
)
from .composition import (
    CompositionError,
    Placement,
    Plan,
    align,
    merge,
    optimize,
    place,
    replace,
    scatter,
    seed_for,
    variant,
    variant_spread,
)

__all__ = [
    "KNOWN_KINDS", "Landmark", "PlanResult", "Region", "Route",
    "WorldSpec", "WorldSpecError", "load_spec", "plan",
    "CompositionError", "Placement", "Plan", "align", "merge", "optimize",
    "place", "replace", "scatter", "seed_for", "variant", "variant_spread",
]
