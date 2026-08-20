"""The art direction stage, and the two critic metrics it exposed as broken.

The tests that matter here are the ones about *value*: hue is allowed to differ
per game and any of it is defensible, but if the luminance ladder drifts between
keys then "value structure is not a style choice" stops being true and the whole
module is decoration.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from rqe.art import direct, key_for, problems, solve, value_profile
from rqe.art.direction import (
    DEFAULT_KEY,
    HAZE_CEILING,
    KEYS,
    OUTDOOR_AMBIENT_CEILING,
    ROLE_FAMILY,
    SUN_ELEVATION_CEILING,
    VALUE_LADDER,
    WEIGHTED_MEAN_CEILING,
    ArtDirectionError,
    _sun_elevation,
)
from rqe.tokens import relative_luminance

ROOT = Path(__file__).resolve().parents[1]
BASE = json.loads((ROOT / "tokens" / "brickfarm.json").read_text(encoding="utf-8"))


# ------------------------------------------------------------------ selection


@pytest.mark.parametrize("brief,expected", [
    ("Horror ritual numa abadia assombrada por peregrinos sem rosto", "vigil"),
    ("A faceless ghost stalks a haunted cemetery at night", "vigil"),
    ("Tower defense medieval: ondas de inimigos, torres com upgrades", "siege"),
    ("A castle under siege by knights", "siege"),
    ("Farm tycoon: plant, harvest, sell, upgrade your plots", "grove"),
    ("Neon cyber runner aboard a space station", "circuit"),
    ("Dungeon crawler through volcanic ruins", "ember"),
])
def test_key_comes_from_the_brief(brief, expected):
    assert key_for(brief).name == expected


def test_an_unmatched_brief_gets_the_sober_default():
    assert key_for("A game about something").name == DEFAULT_KEY


def test_plurals_match_but_substrings_do_not():
    # "castles" is how a brief is written; "ruinable" is not a volcano.
    assert key_for("Defend the castles").name == "siege"
    assert key_for("A ruinable interface for farmhands").name != "ember"


def test_accents_do_not_change_the_key():
    assert key_for("Defesa de torres num castelo medieval").name == "siege"


def test_horror_identity_beats_the_generic_tower_defence_key():
    brief = (
        "Tower defense de terror nas ruinas de uma abadia durante a noite; "
        "defenda o sino contra peregrinos sem rosto"
    )
    assert key_for(brief).name == "vigil"


def test_horror_key_removes_the_farm_material_from_dominant_ground():
    document = direct(BASE, game_id="vigil", brief="horror numa abadia")
    roles = document["palette"]["roles"]
    assert roles["ground"]["material"] == "Slate"
    assert roles["groundAlt"]["material"] == "Ground"
    assert roles["pathPrimary"]["material"] == "Cobblestone"


# ---------------------------------------------------------------------- value


def test_the_value_ladder_places_every_role_the_base_set_declares():
    assert set(BASE["palette"]["roles"]) <= set(VALUE_LADDER)


def test_every_key_covers_every_role_family():
    families = set(ROLE_FAMILY.values())
    for key in KEYS:
        assert families <= set(key.hues), f"{key.name} is missing {families - set(key.hues)}"


def test_solve_lands_on_the_luminance_it_was_asked_for():
    for target in VALUE_LADDER.values():
        for hue in (0.0, 104.0, 212.0, 300.0):
            srgb = solve(hue, 0.3, target)
            assert relative_luminance(srgb) == pytest.approx(target, abs=0.01)


def test_value_structure_is_identical_across_keys():
    """The invariant the module exists to hold.

    Two games may be any two colours. They may not be two different lighting
    plans, because the plan is what makes a frame read as a place -- and a key
    that quietly flattens its own ladder would pass every other test here.
    """

    derived = {
        key.name: direct(BASE, game_id="g", brief="", key=key.name)
        for key in KEYS
    }
    for role in BASE["palette"]["roles"]:
        measured = [
            relative_luminance(document["palette"]["roles"][role]["srgb"])
            for document in derived.values()
        ]
        assert max(measured) - min(measured) < 0.02, f"{role} drifts between keys"
        assert measured[0] == pytest.approx(VALUE_LADDER[role], abs=0.02)


def test_keys_actually_look_different():
    siege = direct(BASE, game_id="g", brief="", key="siege")
    circuit = direct(BASE, game_id="g", brief="", key="circuit")
    differing = [
        role for role in BASE["palette"]["roles"]
        if siege["palette"]["roles"][role]["srgb"] != circuit["palette"]["roles"][role]["srgb"]
    ]
    assert len(differing) > len(BASE["palette"]["roles"]) // 2


# --------------------------------------------------------------- the findings


def test_the_base_set_is_caught_by_the_check_built_from_it():
    """The regression this module was written for.

    `tokens/brickfarm.json` is a good token set that every game inherited by
    accident. It fails on exactly two things: a coverage-weighted mean of 0.365,
    and a midday sun with the ambient lifted under it. If this test ever passes
    silently, the checks have stopped checking.
    """

    found = problems(BASE)
    assert any("weighted mean" in problem for problem in found)
    assert any("ambient" in problem for problem in found)


def test_farm_noon_is_the_flat_sun_the_module_replaces():
    lighting = BASE["moods"]["farm-noon"]["lighting"]
    elevation = _sun_elevation(lighting["clockTime"], lighting["geographicLatitude"])
    assert elevation > SUN_ELEVATION_CEILING
    assert relative_luminance(lighting["outdoorAmbient"]) > OUTDOOR_AMBIENT_CEILING


@pytest.mark.parametrize("key", [key.name for key in KEYS])
def test_every_derived_set_meets_its_own_standard(key):
    document = direct(BASE, game_id="game", brief="", key=key)
    assert problems(document) == []
    profile = value_profile(document)
    assert profile.weighted_mean < WEIGHTED_MEAN_CEILING
    assert profile.hue_families <= int(document["palette"]["harmony"]["maxHueFamilies"])


@pytest.mark.parametrize("key", [key.name for key in KEYS])
def test_every_derived_set_has_a_playable_daylight_mood(key):
    document = direct(BASE, game_id="game", brief="", key=key)
    day = document["moods"][f"{key}-day"]["lighting"]
    elevation = _sun_elevation(day["clockTime"], day["geographicLatitude"])
    assert 20.0 <= elevation <= SUN_ELEVATION_CEILING


def test_an_unknown_key_is_refused_by_name():
    with pytest.raises(ArtDirectionError, match="unknown art key"):
        direct(BASE, game_id="game", brief="", key="pastel")


def test_a_role_with_no_declared_value_is_refused():
    """A base set carrying a role the ladder does not place must not pass.

    Silently keeping the base colour for it is how one game's art direction
    leaks into every other game's, one role at a time.
    """

    mutated = json.loads(json.dumps(BASE))
    mutated["palette"]["roles"]["glow"] = dict(mutated["palette"]["roles"]["accentGold"])
    with pytest.raises(ArtDirectionError, match="value ladder does not place"):
        direct(mutated, game_id="game", brief="")


# ---------------------------------------------------------- provenance, files


def test_a_derived_set_never_cites_itself():
    document = direct(BASE, game_id="game", brief="", key="siege")
    assert document["provenance"]["derivation"] == "art-direction-decision"
    assert "brickfarm" in document["provenance"]["note"]


def test_a_derived_set_loads_through_the_real_loader(tmp_path):
    """Schema and semantics, not just the module's own opinion of itself."""

    from rqe.tokens import load_token_set

    (tmp_path / "schemas").mkdir()
    (tmp_path / "schemas" / "design-tokens.v1.schema.json").write_text(
        (ROOT / "schemas" / "design-tokens.v1.schema.json").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    (tmp_path / "tokens").mkdir()
    document = direct(BASE, game_id="game", brief="Medieval siege")
    document["$schema"] = "../schemas/design-tokens.v1.schema.json"
    (tmp_path / "tokens" / "game.json").write_text(json.dumps(document), encoding="utf-8")

    tokens = load_token_set(tmp_path, "tokens/game.json")
    assert tokens.data["tokenSetId"] == "game-siege"


def test_ergonomics_survive_the_re_key():
    """Scale, type and motion are not style and must not be re-decided."""

    document = direct(BASE, game_id="game", brief="Medieval siege")
    for section in ("scale", "spacing", "typography", "motion", "cameras", "audio"):
        assert document[section] == BASE[section]


# ---------------------------------------------------------------- atmosphere


@pytest.mark.parametrize("key", [key.name for key in KEYS])
def test_no_mood_hides_the_far_half_of_the_map(key):
    """Air thick enough to read as depth at 30 studs erases the map at 300.

    An aerial capture under the first values -- density 0.34, haze 1.9 -- came
    back with 2 distinct hues and a luminance spread of 23.4, and the scene
    critic called it greybox. It was right: past the middle distance the world
    really had become one flat blue.
    """

    document = direct(BASE, game_id="game", brief="", key=key)
    for name, mood in document["moods"].items():
        atmosphere = mood["atmosphere"]
        thickness = atmosphere["density"] * atmosphere["haze"]
        assert thickness <= HAZE_CEILING, f"{name} is {thickness:.2f} thick"


def test_the_base_set_is_hazier_than_any_derived_one():
    """The regression: brickfarm's moods are what the ceiling was set against."""

    worst = max(
        mood["atmosphere"]["density"] * mood["atmosphere"]["haze"]
        for mood in BASE["moods"].values()
    )
    assert worst > HAZE_CEILING
    assert any("density x haze" in problem for problem in problems(BASE))


def test_the_daylight_mood_is_the_clearest_one():
    """Gameplay is played through the least air. Hero shots may have more."""

    document = direct(BASE, game_id="game", brief="", key="siege")
    def thickness(name):
        atmosphere = document["moods"][name]["atmosphere"]
        return atmosphere["density"] * atmosphere["haze"]

    assert thickness("siege-day") < thickness("siege-golden")
    assert thickness("siege-day") < thickness("siege-overcast")
