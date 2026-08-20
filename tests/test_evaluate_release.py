"""Fail-closed boundaries of the producer's lightweight candidate verdict."""

from __future__ import annotations

from types import SimpleNamespace

from rqe.evaluate import (
    Evaluation,
    Finding,
    NEEDS_RUNTIME,
    REQUIRED_STATIC_CHECKS,
    compare_to_previous,
    record_evaluation_baseline,
    release_verdict,
)


BUILD = {
    "ok": True,
    "compiles": True,
    "buildId": "a" * 64,
    "placeSha256": "b" * 64,
    "source": {"sha256": "c" * 64},
}
PRODUCTION = {
    "assets": {"ok": True, "productionReady": True},
    "geometry": {"ok": True, "planned": 1, "approved": 1},
}


def _evaluation():
    return Evaluation("probe", checked=list(REQUIRED_STATIC_CHECKS))


def _runtime(**overrides):
    payload = {
        "source": "studio-bridge",
        "satisfied": list(NEEDS_RUNTIME),
        "identity": {
            "buildId": BUILD["buildId"],
            "placeSha256": BUILD["placeSha256"],
            "sourceSha256": BUILD["source"]["sha256"],
        },
    }
    payload.update(overrides)
    return payload


def test_a_list_of_runtime_passes_without_build_identity_is_not_a_candidate():
    result = release_verdict(
        _evaluation(),
        {"ok": True, "introduced": []},
        build=BUILD,
        runtime={"source": "studio-bridge", "satisfied": list(NEEDS_RUNTIME)},
        production=PRODUCTION,
    )

    assert result["status"] == "BLOCKED"
    assert "runtime evidence has no exact build identity" in result["blockers"]


def test_fixture_or_other_runtime_sources_cannot_satisfy_the_gate():
    result = release_verdict(
        _evaluation(),
        {"ok": True, "introduced": []},
        build=BUILD,
        runtime=_runtime(source="headless-runtime"),
        production=PRODUCTION,
    )

    assert result["status"] == "BLOCKED"
    assert "runtime evidence was not measured by studio-bridge" in result["blockers"]


def test_runtime_must_name_the_exact_source_and_place_it_observed():
    runtime = _runtime()
    runtime["identity"] = {**runtime["identity"], "placeSha256": "d" * 64}
    result = release_verdict(
        _evaluation(),
        {"ok": True, "introduced": []},
        build=BUILD,
        runtime=runtime,
        production=PRODUCTION,
    )

    assert result["status"] == "BLOCKED"
    assert "runtime placeSha256 does not match the release build" in result["blockers"]


def test_only_complete_hash_bound_studio_evidence_reaches_candidate_status():
    result = release_verdict(
        _evaluation(),
        {"ok": True, "introduced": []},
        build=BUILD,
        runtime=_runtime(),
        production=PRODUCTION,
    )

    assert result["status"] == "RELEASE_CANDIDATE"
    assert result["blockers"] == []


def test_unavailable_static_checks_and_inconclusive_regression_are_blockers():
    evaluation = Evaluation("probe", unavailable=["Luau harness unavailable"])
    result = release_verdict(
        evaluation,
        {"ok": False, "blocked": "baseline is unreadable"},
        build=BUILD,
        runtime=_runtime(),
        production=PRODUCTION,
    )

    assert result["status"] == "BLOCKED"
    assert "static evaluation unavailable: Luau harness unavailable" in result["blockers"]
    assert "regression comparison failed: baseline is unreadable" in result["blockers"]


def test_empty_static_evaluation_and_unready_assets_never_form_a_candidate():
    result = release_verdict(
        Evaluation("probe"),
        {"ok": True, "introduced": []},
        build=BUILD,
        runtime=_runtime(),
        production={
            "assets": {"ok": True},
            "geometry": {"ok": True, "planned": 2, "approved": 1},
        },
    )

    assert result["status"] == "BLOCKED"
    assert "static evaluation did not cover: system resolution" in result["blockers"]
    assert "the asset plan has no approved, integrated production-asset receipt" in result["blockers"]
    assert "not every planned Blender mesh is approved for import" in result["blockers"]


def test_regression_compares_all_findings_and_only_candidate_promotion_writes_baseline(
    tmp_path,
):
    model = SimpleNamespace(id="probe")
    evaluation = Evaluation(
        "probe",
        findings=[
            Finding("same-rule", "major", "first occurrence"),
            Finding("same-rule", "blocking", "second occurrence"),
        ],
        checked=list(REQUIRED_STATIC_CHECKS),
    )
    path = tmp_path / "games/probe/.evaluation.json"

    comparison = compare_to_previous(tmp_path, model, evaluation)
    assert comparison["firstRun"] is True
    assert len(comparison["introduced"]) == 2
    assert not path.exists(), "a comparison is not permission to promote the current run"

    receipt = record_evaluation_baseline(
        tmp_path,
        model,
        evaluation,
        build=BUILD,
        runtime=_runtime(),
    )
    assert receipt["buildId"] == BUILD["buildId"]
    accepted = path.read_bytes()
    repeated = compare_to_previous(tmp_path, model, evaluation)
    assert repeated["introduced"] == []
    assert len(repeated["carried"]) == 2

    failed_candidate = Evaluation(
        "probe",
        findings=[Finding("new-defect", "blocking", "must not become normal")],
        checked=list(REQUIRED_STATIC_CHECKS),
    )
    changed = compare_to_previous(tmp_path, model, failed_candidate)
    assert changed["ok"] is False
    assert path.read_bytes() == accepted
