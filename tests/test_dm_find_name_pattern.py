"""dm.find must reject a malformed namePattern before it touches the tree.

A namePattern of "(" is a legal schema string, and string.match throws
"malformed pattern" on it. That has to be E_BAD_PARAMS naming the field, not
a crash halfway through the candidates. Nil still means no name filter. The
walk itself must not pcall the match and skip the instance.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA_MODEL = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "DataModel.lua"


def _find(source: str) -> str:
    start = source.index("function DataModelCommands.find")
    end = source.index("return DataModelCommands")
    return source[start:end]


def test_dm_find_validates_name_pattern_before_candidates() -> None:
    source = DATA_MODEL.read_text(encoding="utf-8")
    find = _find(source)

    assert "local Errors = require(script.Parent.Parent.Errors)" in source
    assert 'Errors.raise(Errors.BAD_PARAMS, "namePattern is not a valid Luau pattern")' in find

    validation = find.index('string.match("", namePattern)')
    candidates = find.index("local candidates")
    assert validation < candidates
    assert "string.match(instance.Name, namePattern)" not in find
    assert "pcall(function()" in find[find.index("if namePattern ~= nil"):validation]
