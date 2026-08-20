"""Game Agent Bridge: observations, actions, memory and evidence."""

from .core import GameAgentBridge
from .adapters import HeadlessGameAdapter, StudioGameAdapter

__all__ = ["GameAgentBridge", "HeadlessGameAdapter", "StudioGameAdapter"]

