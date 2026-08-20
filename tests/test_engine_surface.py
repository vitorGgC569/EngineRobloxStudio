"""The programming surface: knowing, writing, placing, escaping.

These check the half of the platform that helps somebody program rather than the
half that builds things for them. What happens inside Studio is proven in
Studio; what is checked here is the part that lives in Python — the index, the
refusals, and the guarantee that nothing blocks.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from rqe import sdkindex
from rqe.mcp.tools import build_server

REPO = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def server():
    return build_server(REPO)


# -- knowing what exists ------------------------------------------------------


def test_a_signature_comes_from_the_source():
    """Guessing cost four failed round trips in one day."""

    found = sdkindex.signature(REPO, "Threat.build")
    assert found["found"] is True
    names = [param["name"] for param in found["parameters"]]
    assert names[:2] == ["parent", "tokens"]
    assert "Threat.build(" in found["signature"]


def test_an_unknown_name_offers_candidates():
    found = sdkindex.signature(REPO, "Palette.theme")
    assert found["found"] is False
    assert "sdk_search" in found["hint"]


def test_search_finds_by_intent_not_by_name():
    """`Zone.new` has neither 'trigger' nor 'volume' in its name."""

    matches = sdkindex.search(REPO, "how do I make a trigger zone")["matches"]
    assert matches, "the search found nothing at all"
    assert any(match["name"].startswith("Zone") for match in matches[:3])


def test_search_answers_in_portuguese():
    """The doc comments are English; the person asking may not be.

    Before this, `como faco uma zona de gatilho` returned `Life.health` and
    `Physics.ragdoll` — confident nonsense that reads exactly like an answer.
    """

    matches = sdkindex.search(REPO, "como faco uma zona de gatilho")["matches"]
    assert any(match["name"].startswith("Zone") for match in matches[:3]), (
        f"Portuguese search returned {[m['name'] for m in matches[:3]]}")


def test_accents_do_not_change_the_answer():
    """`posicao` and `posição` are the same question."""

    plain = sdkindex.search(REPO, "esculpir terreno")["matches"]
    accented = sdkindex.search(REPO, "esculpir terrenó")["matches"]
    assert [m["name"] for m in plain[:3]] == [m["name"] for m in accented[:3]]


def test_the_whole_library_is_indexed():
    surface = sdkindex.surface(REPO)
    assert surface["functions"] > 300
    for module in ("Signal", "Trove", "Timer", "Zone", "Spatial", "Events", "Actions"):
        assert module in surface["modules"], f"{module} is not indexed"


def test_source_hands_back_code_to_copy():
    """When a library function does not fit, taking it is the intended move."""

    found = sdkindex.source(REPO, "Core.Zone")
    assert found["found"] is True
    assert "function Zone" in found["source"]


# -- the skeletons and patterns ------------------------------------------------


def test_every_skeleton_is_a_readable_file(server):
    listing = server.tools["sdk_skeleton"].handler({})
    assert listing["skeletons"], "no skeletons at all"
    for name in listing["skeletons"]:
        one = server.tools["sdk_skeleton"].handler({"name": name})
        assert one["lines"] > 40, f"{name} is too short to be a starting point"
        assert "--- " in one["source"], f"{name} explains nothing"


def test_patterns_carry_their_source(server):
    listing = server.tools["pattern"].handler({})
    assert listing["patterns"]
    for name in listing["patterns"]:
        one = server.tools["pattern"].handler({"name": name})
        assert one["source"].strip(), f"{name} has no code"
        assert one["why"], f"{name} does not say what it avoids"


# -- nothing blocks --------------------------------------------------------------


def test_raw_luau_reaches_every_context():
    """The escape hatch is only an escape hatch if it is reachable from anywhere."""

    import json

    schema = json.loads((REPO / "schemas/bridge-commands.v1.json").read_text(encoding="utf-8"))
    commands = schema["commands"] if isinstance(schema, dict) and "commands" in schema else schema
    entries = commands.items() if isinstance(commands, dict) else [
        (c.get("method"), c) for c in commands
    ]
    for method, spec in entries:
        if method == "bridge.exec":
            assert set(spec["contexts"]) == {"edit", "run", "server", "client"}
            return
    raise AssertionError("bridge.exec is not in the command schema")


def test_rule_validation_is_advice_not_a_gate(server):
    """A caller who knows something the validator does not must be able to proceed."""

    import inspect

    from rqe.mcp import gameplay_tools

    source = inspect.getsource(gameplay_tools)
    assert 'arguments.get("force") is not True' in source
    assert "this is advice" in source


def test_a_screen_can_be_built_against_advice(server):
    import inspect

    from rqe.mcp import authoring_tools

    assert "force" in inspect.getsource(authoring_tools.register_authoring_tools)


def test_the_backend_router_never_overrides_the_caller():
    """A recommendation that cannot be ignored is a rule wearing a friendlier word."""

    from rqe.geometry.brief import choose_backend

    import inspect

    source = inspect.getsource(choose_backend)
    assert "The caller wins, always" in source


# -- the loop this exists to close --------------------------------------------------


def test_writing_compiles_before_it_writes(server):
    """A module written with a syntax error fails at require time naming nothing."""

    import inspect

    from rqe.mcp import engine_tools

    source = inspect.getsource(engine_tools.register_programming_tools)
    assert "code.compile" in source
    assert "not written; fix the syntax" in source


def test_reload_admits_what_it_cannot_do():
    """Anything already holding the old table keeps it, and that must be said."""

    lua = (REPO / "apps/studio-plugin/src/Commands/Code.lua").read_text(encoding="utf-8")
    assert "still holds it" in lua
    # Asserted on a phrase that fits one line. Flattening the file does not
    # help: every wrapped comment carries its own `--` into the joined text, so
    # a sentence spanning two lines is never contiguous either way.
    assert "invalidate Roblox" in lua
