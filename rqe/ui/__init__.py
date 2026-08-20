"""Screen templates: a named arrangement that survives a phone, a notch and an empty list."""

from .screens import (
    DEVICES,
    MIN_TEXT_SIZE,
    OPTIONAL_STATES,
    REQUIRED_STATES,
    TEMPLATES,
    TOUCH_TARGET_MINIMUM,
    Device,
    Element,
    Layout,
    Rect,
    ScreenError,
    ScreenTemplate,
    catalogue,
    compose,
    compose_matrix,
    screens_for,
)

__all__ = [
    "DEVICES", "MIN_TEXT_SIZE", "OPTIONAL_STATES", "REQUIRED_STATES", "TEMPLATES",
    "TOUCH_TARGET_MINIMUM", "Device", "Element", "Layout", "Rect", "ScreenError",
    "ScreenTemplate", "catalogue", "compose", "compose_matrix", "screens_for",
]
