"""The modular kit: every silhouette must compose into a valid program.

The kit exists so two pieces meet with no gap. That makes snapping and program
validity the two properties worth testing here -- a wall that is 12.3 studs wide
is not slightly wrong, it is unusable, and the error repeats at every join.

Building through Blender is proven separately and in Studio; these are the
checks that must hold on every run.
"""

from __future__ import annotations

import pytest

from rqe.geometry.brief import AssetBrief
from rqe.geometry.programs import ProgramError, program_for
from rqe.geometry.structural import MODULE, SILHOUETTES, _snap


def brief_for(silhouette: str, **overrides) -> AssetBrief:
    fields = dict(
        id=f"kit-{silhouette}", dimensions=(16.0, 12.0, 1.0), style="stone",
        silhouette=silhouette, materials=("dark", "light", "accent"),
        triangle_budget=3000, gameplay_role="structure",
    )
    fields.update(overrides)
    return AssetBrief(**fields)


@pytest.mark.parametrize("silhouette", sorted(SILHOUETTES))
def test_every_silhouette_composes(silhouette):
    program = program_for(brief_for(silhouette))
    assert program["steps"], f"{silhouette} produced no steps"
    assert program["result"], f"{silhouette} names no result"


@pytest.mark.parametrize("silhouette", sorted(SILHOUETTES))
def test_a_join_never_has_one_target(silhouette):
    """The program validator refuses it, and it always means a naming slip."""

    for step in program_for(brief_for(silhouette))["steps"]:
        if step["op"] == "join":
            assert len(step["targets"]) > 1, f"{silhouette} joins one object"


@pytest.mark.parametrize("silhouette", sorted(SILHOUETTES))
def test_the_result_is_a_step_that_was_built(silhouette):
    """A program whose result names nothing exports an empty file."""

    program = program_for(brief_for(silhouette))
    made = {
        step.get("name") for step in program["steps"]
        if step.get("name") is not None
    }
    assert program["result"] in made, (
        f"{silhouette} results in {program['result']!r}, which nothing creates")


def test_an_unknown_silhouette_names_the_ones_that_exist():
    with pytest.raises(ProgramError) as caught:
        program_for(brief_for("dome"))
    message = str(caught.value)
    assert "dome" in message
    for known in ("column", "doorway", "paving"):
        assert known in message


def test_snapping_lands_on_the_module():
    assert _snap(12.3) % MODULE == 0
    assert _snap(0.1) >= 1.0
    assert _snap(16.0) == 16.0


def test_a_wall_is_not_snapped_to_bunker_thickness():
    """Thickness is a material property, not a module.

    Snapping it to 4 studs makes every wall a bunker wall, which is the kind of
    over-application of a good rule that only shows up in a screenshot.
    """

    program = program_for(brief_for("solid", dimensions=(16.0, 12.0, 1.0)))
    panel = next(s for s in program["steps"] if s.get("name") == "panel")
    assert panel["size"][1] < MODULE


# -- the five operations that were missing ------------------------------------


def test_the_blocked_operations_now_exist():
    """Every `Blocked` row in the parts manifest traced back to one of these."""

    from rqe.geometry.program import OPERATIONS

    for op in ("screw", "displace", "sweep", "loopcut", "weld"):
        assert op in OPERATIONS, f"{op} is still missing from the vocabulary"


def test_sweep_is_the_only_new_operation_that_creates():
    """A path through space has no primitive to start from; the rest modify."""

    from rqe.geometry.program import OPERATIONS

    assert OPERATIONS["sweep"]["creates"] is True
    for op in ("screw", "displace", "loopcut", "weld"):
        assert OPERATIONS[op]["creates"] is False


def test_the_interpreter_implements_every_declared_operation():
    """A declared operation with no implementation validates and then fails.

    That is the worst ordering: the program passes review, reaches Blender, and
    dies there -- after the caller has been told it was fine.
    """

    import re
    from pathlib import Path

    from rqe.geometry.program import OPERATIONS

    source = (Path(__file__).resolve().parent.parent
              / "rqe" / "geometry" / "blender" / "build.py").read_text(encoding="utf-8")
    registered = set(re.findall(r'"(\w+)": op_\w+', source))
    missing = sorted(set(OPERATIONS) - registered)
    assert not missing, f"declared but not implemented: {missing}"


def test_sweep_needs_a_path_not_a_point():
    from rqe.geometry.program import OPERATIONS

    assert "points" in OPERATIONS["sweep"]["required"]
