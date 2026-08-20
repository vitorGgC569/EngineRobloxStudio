"""Behaviour as data: what a rule may say, and what it may not.

The refusals matter more than the acceptances. A rule that spends a currency
the economy never declared reads perfectly and fails on the one path nobody
tested, and the whole point of validating before install is to turn that into
an authoring-time error.
"""

from __future__ import annotations

import pytest

from rqe.gameplay import (
    CONDITIONS,
    EFFECTS,
    TRIGGERS,
    RuleError,
    compile_rules,
    from_dicts,
    problems,
    vocabulary,
)
from rqe.mcp.gameplay_tools import _lua


def rule(**overrides):
    base = {
        "id": "probe",
        "when": {"kind": "prompt", "target": "Pad_1"},
        "then": [{"kind": "play", "cue": "purchase"}],
    }
    base.update(overrides)
    return from_dicts([base])[0]


# ------------------------------------------------------------------ vocabulary


def test_the_vocabulary_names_what_each_entry_needs():
    document = vocabulary()
    for family in ("triggers", "conditions", "effects"):
        assert document[family]
        for name, spec in document[family].items():
            assert "note" in spec, name


def test_every_effect_names_a_capability():
    for name, spec in EFFECTS.items():
        assert spec.get("capability"), name


# -------------------------------------------------------------------- accepted


def test_a_coherent_rule_compiles():
    plan = compile_rules([rule()], currencies=["cash"], cues=["purchase"])
    assert plan["rules"][0]["id"] == "probe"
    assert plan["capabilities"] == ["audio"]


def test_conditions_and_effects_declare_their_capabilities():
    built = rule(
        require=[{"kind": "currency", "name": "cash", "atLeast": 10}],
        then=[{"kind": "spend", "currency": "cash", "amount": 10},
              {"kind": "play", "cue": "purchase"}],
    )
    plan = compile_rules([built], currencies=["cash"], cues=["purchase"])
    assert set(plan["capabilities"]) == {"audio", "economy"}


# -------------------------------------------------------------------- refused


def test_a_currency_the_game_does_not_have_is_refused():
    built = rule(then=[{"kind": "spend", "currency": "gold", "amount": 1}])
    found = problems(built, currencies=["cash"])
    assert any("gold" in item and "cash" in item for item in found)


def test_a_cue_the_game_does_not_have_is_refused():
    found = problems(rule(), cues=["confirm"])
    assert any("purchase" in item for item in found)


def test_a_player_effect_under_a_subjectless_trigger_is_refused():
    """The failure a shape check alone would miss.

    `timer` has no player, so spending from one is incoherent -- and at runtime
    it would simply never fire, which looks like a design choice.
    """

    built = rule(when={"kind": "timer", "seconds": 5},
                 then=[{"kind": "spend", "currency": "cash", "amount": 1}])
    found = problems(built, currencies=["cash"])
    assert any("has none" in item for item in found)


def test_a_rule_with_no_effect_is_refused():
    assert any("does nothing" in item for item in problems(rule(then=[])))


def test_an_unknown_trigger_names_the_known_ones():
    found = problems(rule(when={"kind": "telepathy"}))
    assert found and "unknown trigger" in found[0]


def test_a_trigger_missing_its_field_is_refused():
    assert any("needs 'target'" in item for item in problems(rule(when={"kind": "prompt"})))


def test_the_whole_set_is_refused_not_the_bad_rule():
    """Half-installed behaviour looks like a design choice."""

    good = rule(id="good")
    bad = rule(id="bad", then=[{"kind": "spend", "currency": "gold", "amount": 1}])
    with pytest.raises(RuleError, match="bad:"):
        compile_rules([good, bad], currencies=["cash"], cues=["purchase"])


def test_duplicate_ids_are_refused():
    with pytest.raises(RuleError, match="duplicate rule id"):
        compile_rules([rule(), rule()], currencies=["cash"], cues=["purchase"])


# ------------------------------------------------------------------ lua output


def test_lua_is_lua_and_not_json():
    """The bug this encoder exists for.

    `json.dumps` produced `[{"id": ...}]`, and the place answered with a parse
    error: JSON arrays open with `[` and separate keys with `:`. Lua takes
    neither.
    """

    out = _lua([{"id": "a", "then": [{"kind": "play"}]}])
    assert out.startswith("{{")
    assert '"id"' not in out
    assert "id=" in out


def test_lua_keywords_are_indexed_not_written_as_fields():
    out = _lua({"then": 1, "require": 2, "kind": 3})
    assert '["then"]=' in out
    assert '["require"]=' in out
    assert "kind=" in out


def test_lua_escapes_quotes_and_newlines():
    out = _lua({"message": 'a "quoted" line' + chr(10) + "next"})
    assert chr(92) + chr(34) in out
    assert chr(92) + "n" in out
