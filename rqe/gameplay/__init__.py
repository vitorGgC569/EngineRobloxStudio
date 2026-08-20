"""Behaviour composed as data, so it can be authored a rule at a time."""

from .rules import (
    CONDITIONS,
    EFFECTS,
    TRIGGERS,
    Rule,
    RuleError,
    compile_rules,
    from_dicts,
    problems,
    vocabulary,
)

__all__ = [
    "CONDITIONS", "EFFECTS", "TRIGGERS", "Rule", "RuleError",
    "compile_rules", "from_dicts", "problems", "vocabulary",
]
