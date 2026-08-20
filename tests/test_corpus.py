"""The regression corpus, and the properties that make it worth running.

A corpus can fail silently in a way a single test cannot: by being twenty copies
of one case. Most of what is asserted here is about the corpus itself -- genre
spread, stress spread, no duplicates -- because a corpus that has quietly
collapsed onto one shape passes every change that breaks everything else.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from rqe.corpus import (
    BUILD_MODE,
    BUILD_REQUIRED_STAGES,
    RELEASE_CANDIDATE_MODE,
    RELEASE_CANDIDATE_REQUIRED_STAGES,
    RUNTIME_MODE,
    Brief,
    CorpusError,
    build_one,
    coverage,
    genres,
    load,
    production_genre,
    run,
)
from rqe.evaluate import NEEDS_RUNTIME
from rqe.producer import FAILED, OK, ProductionRun, StageResult

ROOT = Path(__file__).resolve().parents[1]


def _production(
    *,
    overrides: dict[str, StageResult] | None = None,
    release_detail: dict | None = None,
    compiled_genre: str = "tycoon",
) -> ProductionRun:
    """A complete synthetic run for corpus verdict tests.

    These tests are about whether the corpus reads producer evidence honestly,
    not about re-running the whole factory for every refusal shape.
    """

    names = list(dict.fromkeys(
        ("scaffold",) + RELEASE_CANDIDATE_REQUIRED_STAGES
    ))
    results = [StageResult(stage=name, status=OK) for name in names]
    by_name = {result.stage: result for result in results}
    by_name["design"].detail = {"genre": compiled_genre}
    by_name["art"].detail = {"key": "probe", "weightedMean": 0.4}
    by_name["build"].detail = {
        "ok": True,
        "bytes": 100,
        "instances": {"Script": 1, "ModuleScript": 5},
    }
    by_name["release_candidate"].detail = release_detail or {
        "status": "STATICALLY_CLEAN",
        "blockers": [f"not observed on a running game: {item}" for item in NEEDS_RUNTIME],
        "outstanding": list(NEEDS_RUNTIME),
        "observed": [],
    }
    for name, result in (overrides or {}).items():
        by_name[name] = result
    return ProductionRun(
        game_id="probe",
        brief="A corpus probe",
        results=[by_name[name] for name in names],
    )


def test_the_corpus_loads():
    assert len(load(ROOT)) >= 20


def test_every_brief_is_distinct():
    briefs = load(ROOT)
    assert len({brief.id for brief in briefs}) == len(briefs)
    assert len({brief.brief for brief in briefs}) == len(briefs)


def test_the_corpus_is_not_twenty_copies_of_one_genre():
    """The way a corpus fails without failing.

    Twenty briefs that all stress waves and placement is one test written twenty
    times, and it passes every change that breaks the other genres.
    """

    report = coverage(load(ROOT))
    assert report["distinctGenres"] >= 10
    assert max(report["genres"].values()) <= 3


def test_the_corpus_exercises_many_mechanics():
    report = coverage(load(ROOT))
    assert report["distinctStresses"] >= 30


def test_no_genre_family_dominates():
    """Tower defense is where this factory was tuned; it must not be the corpus."""

    report = coverage(load(ROOT))
    td = sum(count for name, count in report["genres"].items()
             if "tower-defense" in name)
    assert td <= 2, "the corpus is drifting back toward its baseline genre"


def test_siegehold_is_marked_as_the_baseline():
    """Named, so nobody mistakes the laboratory for the specification."""

    report = coverage(load(ROOT))
    assert "siegehold" in report["baselines"]


def test_briefs_are_written_as_briefs_not_ids():
    for brief in load(ROOT):
        assert len(brief.brief) > 40, f"{brief.id} has a brief too thin to compile"


def test_a_missing_corpus_is_an_error_not_an_empty_run():
    """Absence of evidence must not read as a clean sweep."""

    with pytest.raises(CorpusError, match="no corpus at"):
        load(ROOT, "corpus/does-not-exist.json")


def test_a_duplicate_id_is_refused(tmp_path):
    import json

    (tmp_path / "corpus").mkdir()
    (tmp_path / "corpus" / "dup.json").write_text(json.dumps({
        "briefs": [
            {"id": "a", "genre": "x", "brief": "one"},
            {"id": "a", "genre": "y", "brief": "two"},
        ]
    }), encoding="utf-8")
    with pytest.raises(CorpusError, match="duplicate corpus id"):
        load(tmp_path, "corpus/dup.json")


def test_an_empty_corpus_is_refused(tmp_path):
    import json

    (tmp_path / "corpus").mkdir()
    (tmp_path / "corpus" / "empty.json").write_text(json.dumps({"briefs": []}),
                                                    encoding="utf-8")
    with pytest.raises(CorpusError, match="declares no briefs"):
        load(tmp_path, "corpus/empty.json")


def test_genres_counts_every_brief():
    briefs = [Brief("a", "tycoon", "x"), Brief("b", "tycoon", "y"),
              Brief("c", "racing", "z")]
    assert genres(briefs) == {"tycoon": 2, "racing": 1}


def test_the_declared_genre_reaches_the_producer_in_its_executable_form():
    brief = Brief("walls", "tower-defense", "Defend walls through enemy waves.")
    production = _production(compiled_genre="tower_defense")

    with patch("rqe.producer.produce", return_value=production) as produce:
        outcome = build_one(ROOT, brief, mode=BUILD_MODE)

    assert outcome.ok, outcome.error
    assert produce.call_args.kwargs["genre"] == "tower_defense"
    assert produce.call_args.kwargs["skip_stages"] == ("geometry",)
    assert outcome.detail["declaredGenre"] == "tower-defense"
    assert outcome.detail["productionGenre"] == "tower_defense"


def test_a_supported_hybrid_uses_its_base_recipe_without_defaulting_to_tycoon():
    assert production_genre("racing-hybrid") == "racing"
    assert production_genre("tower-defense-hybrid") == "tower_defense"


def test_a_producer_that_ignores_the_declared_genre_cannot_pass_the_corpus():
    production = _production(compiled_genre="tycoon")
    with patch("rqe.producer.produce", return_value=production):
        outcome = build_one(
            ROOT,
            Brief("race", "racing", "Race through checkpoints before the timer."),
        )

    assert not outcome.ok
    assert "compiled genre does not match" in outcome.error


def test_an_unsupported_declared_genre_is_a_named_failure_not_a_tycoon_guess():
    brief = Brief("duel", "arena", "Choose a champion and duel for three minutes.")
    with patch("rqe.producer.produce") as produce:
        outcome = build_one(ROOT, brief)

    assert not outcome.ok
    assert "declared corpus genre 'arena' has no production path" in outcome.error
    produce.assert_not_called()


@pytest.mark.parametrize(
    "detail, expected",
    [
        ({"ok": False}, "stage reported ok=false"),
        ({"blocked": "Rojo was unavailable"}, "Rojo was unavailable"),
    ],
)
def test_a_required_stage_cannot_hide_a_refusal_inside_an_ok_status(detail, expected):
    production = _production(overrides={
        "build": StageResult(stage="build", status=OK, detail=detail),
    })
    with patch("rqe.producer.produce", return_value=production):
        outcome = build_one(ROOT, Brief("probe", "tycoon", "Build a farm tycoon."))

    assert not outcome.ok
    assert f"build: {expected}" in outcome.error


def test_a_missing_required_stage_is_not_a_clean_corpus_result():
    production = _production()
    production.results = [item for item in production.results if item.stage != "implement"]
    with patch("rqe.producer.produce", return_value=production):
        outcome = build_one(ROOT, Brief("probe", "tycoon", "Build a farm tycoon."))

    assert not outcome.ok
    assert "implement: stage is absent" in outcome.error


def test_build_mode_ignores_only_work_that_is_explicitly_outside_its_scope():
    production = _production(overrides={
        "geometry": StageResult(
            stage="geometry", status=FAILED, error="Blender is unavailable"
        ),
    })
    with patch("rqe.producer.produce", return_value=production):
        outcome = build_one(
            ROOT, Brief("probe", "tycoon", "Build a farm tycoon."), mode=BUILD_MODE
        )

    assert outcome.ok, outcome.error
    assert outcome.detail["nonRequiredFailures"] == ["geometry"]
    assert "geometry" not in outcome.detail["requiredStages"]


def test_runtime_mode_never_passes_a_statically_clean_unplayed_build():
    with patch("rqe.producer.produce", return_value=_production()) as produce:
        outcome = build_one(
            ROOT, Brief("probe", "tycoon", "Build a farm tycoon."), mode=RUNTIME_MODE
        )

    assert not outcome.ok
    assert produce.call_args.kwargs["skip_stages"] == ()
    assert "runtime not observed" in outcome.error
    assert "did not return RELEASE_CANDIDATE" in outcome.error


def test_runtime_mode_accepts_only_the_complete_runtime_backed_gate_verdict():
    release = {
        "status": "RELEASE_CANDIDATE",
        "blockers": [],
        "outstanding": [],
        "observed": list(NEEDS_RUNTIME),
    }
    with patch("rqe.producer.produce", return_value=_production(release_detail=release)):
        outcome = build_one(
            ROOT, Brief("probe", "tycoon", "Build a farm tycoon."), mode=RUNTIME_MODE
        )

    assert outcome.ok, outcome.error
    assert outcome.detail["runtimeObserved"] == list(NEEDS_RUNTIME)


def test_release_candidate_mode_also_requires_geometry():
    release = {
        "status": "RELEASE_CANDIDATE",
        "blockers": [],
        "outstanding": [],
        "observed": list(NEEDS_RUNTIME),
    }
    production = _production(
        release_detail=release,
        overrides={
            "geometry": StageResult(
                stage="geometry", status=FAILED, error="asset was not built"
            ),
        },
    )
    with patch("rqe.producer.produce", return_value=production):
        outcome = build_one(
            ROOT,
            Brief("probe", "tycoon", "Build a farm tycoon."),
            mode=RELEASE_CANDIDATE_MODE,
        )

    assert not outcome.ok
    assert "geometry: asset was not built" in outcome.error


def test_an_unknown_mode_is_refused_before_a_vacuous_filtered_run():
    with pytest.raises(CorpusError, match="unknown corpus mode"):
        run(ROOT, only=("does-not-exist",), mode="release-ish")


def test_an_unknown_brief_filter_is_not_a_vacuous_clean_sweep():
    with pytest.raises(CorpusError, match="unknown corpus brief id"):
        run(ROOT, only=("does-not-exist",))


def test_the_declared_static_scope_is_stable():
    """Adding a stage must be an explicit decision about corpus semantics."""

    assert BUILD_REQUIRED_STAGES[-2:] == ("implement", "build")
