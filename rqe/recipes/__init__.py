"""Gameplay recipes: a genre stated once, so a game is a configuration of it."""

from .catalogue import (
    RECIPES,
    Recipe,
    RecipeError,
    apply,
    catalogue,
    check,
    conforms,
    recipe_for,
    variants,
)

__all__ = [
    "RECIPES", "Recipe", "RecipeError", "apply", "catalogue",
    "check", "conforms", "recipe_for", "variants",
]
