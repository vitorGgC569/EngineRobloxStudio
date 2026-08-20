"""The tool surface an agent actually drives.

These check the parts that live in Python: the vocabulary, the guide, and the
refusals. What happens inside Studio is proven in Studio -- there is no fixture
here pretending to be a DataModel, because a fixture that agrees with itself is
the failure mode this project has hit most often.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from rqe.mcp.tools import build_server


@pytest.fixture(scope="module")
def server():
    return build_server(Path(__file__).resolve().parent.parent)


def test_every_family_the_guide_lists_actually_exists(server):
    """The map may not name a road that is not there."""

    from rqe.mcp.guide_tools import FAMILIES

    present = {name.split("_")[0] for name in server.tools}
    missing = sorted(set(FAMILIES) - present)
    assert not missing, f"guide describes families with no tools: {missing}"


def test_every_family_that_exists_is_described(server):
    """And it may not leave a road off the map."""

    guide = server.tools["rqe_guide"].handler({})
    undescribed = [
        name for name, entry in guide["families"].items()
        if entry["does"] == "(undescribed)"
    ]
    assert not undescribed, f"undescribed families: {undescribed}"


def test_guide_routes_name_real_tools(server):
    """A route that names a tool nobody can call is worse than no route."""

    from rqe.mcp.guide_tools import ROUTES

    for route in ROUTES:
        for step in route["steps"]:
            for token in step.split(" --")[0].replace(",", " ").split():
                if token.endswith("_*") or token not in server.tools:
                    # Prose in a step is fine; a token that *looks* like a tool
                    # and is not one is the thing worth catching.
                    if "_" in token and token.split("_")[0] in {
                        name.split("_")[0] for name in server.tools
                    }:
                        raise AssertionError(
                            f"{route['goal']}: no tool {token!r}")
                    continue


def test_every_family_appears_in_a_route(server):
    """The regression that made this test necessary.

    The inventory is generated from the live registry and cannot drift. The
    routes are written by hand, and after one long session of adding families
    31 of 55 had no route at all -- so an agent reading the guide never learned
    that the world could be made touchable, or that Blender was reachable.

    A map that stops covering the territory is worse than no map, because it is
    still believed.
    """

    from rqe.mcp.guide_tools import ROUTES

    covered: set[str] = set()
    for route in ROUTES:
        for step in route["steps"]:
            for token in step.split(" --")[0].replace(",", " ").split():
                # Single-word tools are families of one -- `run`, `logs`,
                # `compile`, `place`. Requiring an underscore silently skipped
                # them and let four families fall off the map unnoticed.
                covered.add(token.split("_")[0] if "_" in token else token)

    families = {name.split("_")[0] for name in server.tools}
    missing = sorted(families - covered)
    assert not missing, (
        f"{len(missing)} families are unreachable from any route: {missing}. "
        "Add them to a route in guide_tools.ROUTES.")


def test_movement_effects_are_in_the_vocabulary():
    from rqe.gameplay import vocabulary

    effects = vocabulary()["effects"]
    for name in ("chase", "flee", "patrol", "halt"):
        assert name in effects, f"{name} missing from the rule vocabulary"
        assert effects[name]["capability"] == "movement"


def test_patrol_demands_points():
    """A patrol with one point is a creature standing still, spelled oddly."""

    from rqe.gameplay import from_dicts, problems

    rule = from_dicts([{
        "id": "walk", "when": {"kind": "timer", "every": 5},
        "then": [{"kind": "patrol", "who": "Sentry"}],
    }])[0]
    assert any("points" in problem for problem in problems(rule, currencies=[], cues=[]))


def test_pursuit_start_refuses_a_patrol_with_no_route(server):
    result = server.tools["pursuit_start"].handler(
        {"who": "Sentry", "mode": "patrol", "points": [[0, 0, 0]]})
    assert result["ok"] is False
    assert "two points" in result["error"]


def test_pursuit_start_refuses_an_unknown_mode(server):
    result = server.tools["pursuit_start"].handler({"who": "Sentry", "mode": "stalk"})
    assert result["ok"] is False


def test_ui_compose_refuses_a_blank_screen(server):
    result = server.tools["ui_compose"].handler({"screen": {"name": "Empty"}})
    assert result["ok"] is False
    assert "blank" in result["error"]


def test_place_publish_explains_that_it_cannot_create_an_experience(server):
    """The limit is real, so the message has to carry the remedy."""

    result = server.tools["place_publish"].handler({"gameId": "last-vigil"})
    assert result["published"] is False
    assert "create.roblox.com" in result["why"]


def test_place_publish_saves_rather_than_releases_by_default(server):
    """`release` is a word you have to say, not a default you fall into."""

    import inspect

    from rqe.mcp import place_tools

    source = inspect.getsource(place_tools)
    assert 'release = bool(arguments.get("release"))' in source
    assert "published=release" in source


# -- terrain, motion and the look ---------------------------------------------


def test_terrain_refuses_a_material_it_does_not_offer(server):
    """The refusal has to carry the list, or the caller is guessing."""

    result = server.tools["terrain_sculpt"].handler({"material": "Marzipan"})
    assert result["ok"] is False
    assert "Grass" in result["have"]


def test_terrain_paint_checks_both_ends(server):
    result = server.tools["terrain_paint"].handler({"from": "Grass", "to": "Cheese"})
    assert result["ok"] is False


def test_ground_materials_exclude_air(server):
    """`Air` is a terrain material and never what a caller means by ground.

    Offering it would let `terrain_sculpt` build an invisible world that reports
    success -- the worst failure this surface could have.
    """

    from rqe.mcp.world_craft_tools import GROUND_MATERIALS

    assert "Air" not in GROUND_MATERIALS


def test_lighting_grade_refuses_an_empty_call(server):
    """Setting nothing and reporting success would read as "the look is applied"."""

    result = server.tools["lighting_grade"].handler({})
    assert result["ok"] is False
    assert "haze" in result["error"]


def test_haze_is_capped_the_way_art_direction_caps_it():
    """Past a third of the frame, haze stops reading as air and reads as a fault."""

    import inspect

    from rqe.mcp import world_craft_tools

    source = inspect.getsource(world_craft_tools)
    assert "min(max(haze, 0.0), 0.35)" in source


# -- acoustics, shipping and money --------------------------------------------


def test_acoustics_refuses_a_place_with_no_zones(server):
    """Zero zones is one space everywhere, which is what it already was."""

    result = server.tools["acoustics_install"].handler({"zones": []})
    assert result["ok"] is False


def test_monetize_refuses_a_duplicated_id(server):
    """One id cannot be two things; the collision is silent at runtime."""

    result = server.tools["monetize_check"].handler({
        "passes": [{"id": 5, "name": "Lantern"}],
        "products": [{"id": 5, "name": "Oil", "grants": "one oil"}],
    })
    assert result["ok"] is False
    assert any("used by both" in problem for problem in result["problems"])


def test_monetize_refuses_a_product_that_grants_nothing(server):
    """A product with no grant charges the player and delivers nothing."""

    result = server.tools["monetize_check"].handler({
        "products": [{"id": 7, "name": "Oil"}],
    })
    assert result["ok"] is False
    assert any("grants" in problem for problem in result["problems"])


def test_monetize_rejects_a_non_integer_id(server):
    result = server.tools["monetize_check"].handler({
        "products": [{"id": "seven", "name": "Oil", "grants": "oil"}],
    })
    assert result["ok"] is False


def test_ship_settings_probes_rather_than_assumes():
    """Roblox removed the streaming radius properties.

    A hardcoded property name raises `not a valid member of Workspace` instead
    of degrading, and this engine's property set shifts between versions -- so
    availability has to be discovered at the call.
    """

    import inspect

    from rqe.mcp import world_craft_tools

    source = inspect.getsource(world_craft_tools.register_world_craft_tools)
    assert "candidates" in source
    assert "unavailable" in source


# -- a world you can touch ----------------------------------------------------


def test_zero_is_not_the_same_as_absent():
    """`arguments.get(k) or default` silently discards a legitimate zero.

    Measured before the fix: `interact_attach` asked for `upper: 0` -- a door
    that closes flush -- and reported `upper: 90`. Lua would have done the right
    thing with the same expression, which is exactly why it survived reading.
    """

    from rqe.mcp.interact_tools import _int, _num

    assert _num({"upper": 0}, "upper", 90) == 0.0
    assert _num({}, "upper", 90) == 90.0
    assert _int({"seed": 0}, "seed", 7) == 0
    assert _int({}, "seed", 7) == 7


def test_no_tool_module_still_defaults_through_or():
    """The pattern is gone from every module written for this surface.

    Checked against the parsed tree rather than the text: the first version was
    a regex, and it matched the sentence in `_num`'s own docstring explaining
    the bug. It also missed the one real survivor, because that default was an
    expression rather than a literal.
    """

    import ast
    from pathlib import Path

    root = Path(__file__).resolve().parent.parent / "rqe" / "mcp"
    offenders: list[str] = []
    for name in ("staging_tools", "authoring_tools", "world_craft_tools",
                 "interact_tools"):
        path = root / f"{name}.py"
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            # float(<anything> or <anything>) / int(...) -- the shape that
            # swallows a zero, whatever the default happens to be.
            if not isinstance(node, ast.Call):
                continue
            if not isinstance(node.func, ast.Name) or node.func.id not in ("float", "int"):
                continue
            if not node.args:
                continue
            argument = node.args[0]
            if isinstance(argument, ast.BoolOp) and isinstance(argument.op, ast.Or):
                offenders.append(f"{name}.py:{node.lineno}")

    assert not offenders, f"falsy-zero defaults still at {offenders}"


def test_badges_must_say_what_earns_them(server):
    """A badge nothing can award is a badge nobody gets."""

    result = server.tools["badge_check"].handler(
        {"badges": [{"id": 9, "name": "First Dawn"}]})
    assert result["ok"] is False
    assert any("earns it" in problem for problem in result["problems"])


def test_badge_ids_cannot_collide(server):
    result = server.tools["badge_check"].handler({"badges": [
        {"id": 9, "name": "A", "earnedFor": "x"},
        {"id": 9, "name": "B", "earnedFor": "y"},
    ]})
    assert result["ok"] is False


def test_text_declare_refuses_an_empty_table(server):
    result = server.tools["text_declare"].handler({"phrases": {}})
    assert result["ok"] is False


# -- chat, where the failure mode is moderation -------------------------------


def test_chat_command_names_carry_no_slash(server):
    """The installer adds it; a name with one produces `//kick`, which never fires."""

    result = server.tools["chat_commands"].handler(
        {"commands": [{"name": "/kick", "does": "remove a player"}]})
    assert result["ok"] is False
    assert any("slash" in problem for problem in result["problems"])


def test_two_commands_cannot_answer_to_one_word(server):
    result = server.tools["chat_commands"].handler({"commands": [
        {"name": "vote", "alias": "v", "does": "start a vote"},
        {"name": "v", "does": "something else"},
    ]})
    assert result["ok"] is False
    assert any("/v" in problem for problem in result["problems"])


def test_the_filtering_requirement_is_stated_where_it_is_needed(server):
    """It is moderation policy, not a style note, and games are taken down for it."""

    result = server.tools["chat_commands"].handler(
        {"commands": [{"name": "say", "does": "echo a message"}]})
    assert "filter" in result["note"].lower()


def test_display_is_the_only_path_for_player_text():
    """`Chat.filter` returns nil on failure, so "show it anyway" is unreachable."""

    from pathlib import Path

    source = (Path(__file__).resolve().parent.parent
              / "roblox" / "lib" / "GameKit" / "Chat.lua").read_text(encoding="utf-8")
    assert "showing nothing rather than raw text" in source
    # And the legacy-chat trap: TextChatCommand parents cleanly and never fires.
    assert "never fires there" in source


# -- a world that moves -------------------------------------------------------


def test_a_joint_needs_two_parts(server):
    result = server.tools["physics_join"].handler(
        {"kind": "rope", "a": "Workspace.Beam"})
    assert result["ok"] is False
    assert "two parts" in result["error"]


def test_an_unknown_joint_names_the_ones_that_exist(server):
    result = server.tools["physics_join"].handler(
        {"kind": "magnet", "a": "Workspace.A", "b": "Workspace.B"})
    assert result["ok"] is False
    for known in ("rope", "spring", "socket", "slider"):
        assert known in result["error"]


def test_forces_are_one_ended_and_not_reported_as_broken():
    """The diagnostic must not cry wolf on every push.

    `VectorForce` is a Constraint with only `Attachment0` -- a push has
    somewhere to act, not two things to join. The first version of
    `Physics.report` flagged every one of them as having an unattached end,
    which is worse than having no diagnostic: it trains you to ignore the list
    that exists to catch real silent failures.
    """

    from pathlib import Path

    source = (Path(__file__).resolve().parent.parent
              / "roblox" / "lib" / "WorldKit" / "Physics.lua").read_text(encoding="utf-8")
    assert "oneEnded" in source
    assert 'item:IsA("VectorForce")' in source


def test_ragdoll_says_when_there_was_no_rig_to_fold():
    """Zero joints converted is a finding, not a success.

    A model of loose parts has no Motor6D to replace, so `ragdoll` does nothing
    and would otherwise report cleanly -- which reads as "the body is ragdolled"
    when it is a rigid prop lying where it stood.
    """

    from pathlib import Path

    source = (Path(__file__).resolve().parent.parent
              / "roblox" / "lib" / "WorldKit" / "Physics.lua").read_text(encoding="utf-8")
    assert "no Motor6D joints found" in source


# -- policy and reach, where the failure mode is legal -------------------------


def test_an_ungated_loot_box_is_refused(server):
    """Roblox decides per player whether paid random items may be shown."""

    result = server.tools["policy_check"].handler(
        {"features": [{"name": "Ember Crate", "kind": "randomPaidItems"}]})
    assert result["ok"] is False
    assert any("mayShowRandomPaidItems" in problem for problem in result["problems"])


def test_a_gated_feature_passes(server):
    result = server.tools["policy_check"].handler(
        {"features": [{"name": "Discord", "kind": "externalLinks", "gated": True}]})
    assert result["ok"] is True


def test_an_unknown_gate_names_the_ones_that_exist(server):
    result = server.tools["policy_check"].handler(
        {"features": [{"name": "Swap", "kind": "barter"}]})
    assert result["ok"] is False
    for known in ("randomPaidItems", "externalLinks", "trading"):
        assert known in result["problems"][0]


def test_an_unreadable_policy_denies_rather_than_allows():
    """An outage must not silently switch compliance off for everybody.

    Defaulting to permissive means the one moment the service is down is the
    moment every restriction lifts, which is the worst possible failure
    direction for a rule that is enforced.
    """

    from pathlib import Path

    source = (Path(__file__).resolve().parent.parent
              / "roblox" / "lib" / "GameKit" / "Reach.lua").read_text(encoding="utf-8")
    assert "assuming the restrictive default" in source
    assert "return DENIED" in source


def test_memorystore_demands_a_lifetime():
    """Entries expire. A caller who does not choose one has not understood that.

    That is how an inventory ends up in a MemoryStore and quietly disappears --
    expiry is not an error, so nothing reports the loss.
    """

    from pathlib import Path

    source = (Path(__file__).resolve().parent.parent
              / "roblox" / "lib" / "GameKit" / "Reach.lua").read_text(encoding="utf-8")
    assert "choose a lifetime in seconds" in source
    assert "use a DataStore" in source
