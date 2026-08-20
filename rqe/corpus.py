"""The regression corpus: twenty briefs the factory must keep serving.

Every quality number this project has produced came from one game. `siegehold`
is where the art direction was tuned, where the scene critic's two calibration
frames came from, and where every threshold was set. That is overfitting with
extra steps: a factory measured on one output learns to make that output.

So the corpus is a versioned file of briefs across genres, and running it asks a
different question from "does siegehold still work". It asks whether a change
that helped one game broke the nineteen it was not looking at.

**What a run checks, in order of what it costs.** The cheap half needs no Studio
and no Blender: every brief must compile to a model, derive an art direction,
plan a world, emit Luau that passes the syntax and misuse guards, and build a
place file. That is the half that runs on every change.

The expensive half -- open the place, play it, drive an interaction, capture and
score -- needs Studio and takes minutes per game. It is opt-in and it is where
`rqe.evidence` matters, because twenty games judged by an instrument that cannot
tell a wire success from a game success produce twenty confident mistakes.

**What this deliberately does not do** is assert a quality score per game. The
scene critic's thresholds were set against two frames of one game and are
honestly labelled aspirational; asserting them across twenty genres would be
enforcing siegehold's taste on a racing game. The corpus checks that each brief
*produces* a game, and records what it measured, so a regression is visible as a
change rather than judged against a number nobody validated.
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


class CorpusError(RuntimeError):
    """The corpus could not be loaded or run."""


DEFAULT_PATH = Path("corpus/briefs.v1.json")

#: The cheap corpus run proves only that the deterministic production package
#: reached a Rojo place.  Runtime and release-candidate modes are opt-in and
#: fail closed on the evidence the producer's gate reports.  Neither mode is an
#: authority for the immutable ``rqe release`` gate.
BUILD_MODE = "build"
RUNTIME_MODE = "runtime"
RELEASE_CANDIDATE_MODE = "release_candidate"
MODES = (BUILD_MODE, RUNTIME_MODE, RELEASE_CANDIDATE_MODE)

# Geometry deliberately is not part of the cheap half: it needs Blender.  The
# evaluate/repair/regression tail is likewise not required to answer the cheap
# corpus question, which is whether each brief still becomes a statically
# validated place.  The dependencies that decide what enters that place are
# required even when the current producer graph happens not to wait on them.
BUILD_REQUIRED_STAGES = (
    "design",
    "art",
    "systems",
    "economy",
    "content",
    "world",
    "interface",
    "assets",
    "plan",
    "implement",
    "build",
)
RUNTIME_REQUIRED_STAGES = BUILD_REQUIRED_STAGES + (
    "evaluate",
    "regression",
    "release_candidate",
)
RELEASE_CANDIDATE_REQUIRED_STAGES = BUILD_REQUIRED_STAGES + (
    "geometry",
    "evaluate",
    "repair",
    "regression",
    "release_candidate",
)


def production_genre(declared: str) -> str:
    """Return the executable genre named by a corpus entry.

    The corpus uses human-facing names (``tower-defense``) and also names
    hybrid families.  The design compiler accepts canonical IR names.  A
    supported hybrid can exercise its base recipe plus the extra mechanics in
    the brief; an unsupported family must fail explicitly instead of silently
    compiling as the compiler's default tycoon.
    """

    from .ir.model import GENRES

    normalised = re.sub(r"[^a-z0-9]+", "_", declared.strip().lower()).strip("_")
    if normalised in GENRES:
        return normalised
    if normalised.endswith("_hybrid"):
        base = normalised.removesuffix("_hybrid")
        if base in GENRES:
            return base
    known = ", ".join(GENRES)
    raise CorpusError(
        f"declared corpus genre {declared!r} has no production path; "
        f"known executable genres: {known}"
    )


def _required_stages(mode: str, *, scaffold: bool) -> tuple[str, ...]:
    if mode == BUILD_MODE:
        required = BUILD_REQUIRED_STAGES
    elif mode == RUNTIME_MODE:
        required = RUNTIME_REQUIRED_STAGES
    elif mode == RELEASE_CANDIDATE_MODE:
        required = RELEASE_CANDIDATE_REQUIRED_STAGES
    else:
        raise CorpusError(
            f"unknown corpus mode {mode!r}; expected one of {', '.join(MODES)}"
        )
    if scaffold:
        return required[:2] + ("scaffold",) + required[2:]
    return required


def _stage_refusal(result: Any | None) -> str:
    """Why a required stage did not succeed, including data verdicts.

    The producer now promotes ``ok=false`` and ``blocked`` to a failed outer
    status, but corpus reports may also come from older runs or test adapters.
    Inspecting both layers here prevents a normal function return from becoming
    evidence that its work succeeded.
    """

    if result is None:
        return "stage is absent from the production run"
    if result.status not in ("OK", "NOT_APPLICABLE"):
        if result.error:
            return result.error
        if result.blocked_by:
            return f"skipped because {result.blocked_by} did not succeed"
        return f"stage status is {result.status}"

    detail = result.detail if isinstance(result.detail, dict) else {}
    if "blocked" in detail:
        return str(detail.get("blocked") or "stage reported blocked without a reason")
    if "ok" in detail and detail.get("ok") is not True:
        return str(detail.get("error") or "stage reported ok=false")
    return ""


def _runtime_refusals(release: Any | None) -> list[str]:
    """Validate the runtime evidence summarized by the producer gate."""

    from .evaluate import NEEDS_RUNTIME

    if release is None:
        return ["release_candidate: stage is absent from the production run"]
    detail = release.detail if isinstance(release.detail, dict) else {}
    observed = set(detail.get("observed") or ())
    missing = [check for check in NEEDS_RUNTIME if check not in observed]
    refusals = [f"runtime not observed: {check}" for check in missing]
    if detail.get("outstanding"):
        for check in detail["outstanding"]:
            # ``outstanding`` and absence from ``observed`` describe the same
            # missing measurement. Preserve a gate-specific item only when it
            # is not one of the canonical runtime checks.
            if check not in missing:
                refusals.append(f"runtime outstanding: {check}")
    if detail.get("blockers"):
        refusals.extend(f"release blocker: {item}" for item in detail["blockers"])
    if detail.get("status") != "RELEASE_CANDIDATE":
        refusals.append(
            "release_candidate: producer gate did not return RELEASE_CANDIDATE"
        )
    return refusals


@dataclass(frozen=True)
class Brief:
    """One entry, and what it is meant to stress."""

    id: str
    genre: str
    brief: str
    stresses: tuple[str, ...] = ()
    baseline: bool = False


@dataclass
class Outcome:
    """What one brief produced, stage by stage."""

    id: str
    genre: str
    ok: bool
    stages: dict[str, str] = field(default_factory=dict)
    detail: dict[str, Any] = field(default_factory=dict)
    error: str = ""
    seconds: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "genre": self.genre,
            "ok": self.ok,
            "stages": self.stages,
            "detail": self.detail,
            "error": self.error,
            "seconds": round(self.seconds, 2),
        }


def load(root: Path, relative: Path | str = DEFAULT_PATH) -> list[Brief]:
    """Read the corpus, refusing a shape that would silently test less."""

    path = Path(root) / relative
    if not path.is_file():
        raise CorpusError(f"no corpus at {path}")
    document = json.loads(path.read_text(encoding="utf-8"))
    entries = document.get("briefs") or []
    if not entries:
        raise CorpusError(f"{path} declares no briefs")

    seen: set[str] = set()
    briefs: list[Brief] = []
    for entry in entries:
        identifier = str(entry.get("id") or "")
        if not identifier:
            raise CorpusError("a corpus entry has no id")
        if identifier in seen:
            raise CorpusError(f"duplicate corpus id {identifier!r}")
        seen.add(identifier)
        briefs.append(Brief(
            id=identifier,
            genre=str(entry.get("genre") or "unknown"),
            brief=str(entry.get("brief") or ""),
            stresses=tuple(entry.get("stresses") or ()),
            baseline=bool(entry.get("baseline")),
        ))
    return briefs


def genres(briefs: Iterable[Brief]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for brief in briefs:
        counts[brief.genre] = counts.get(brief.genre, 0) + 1
    return counts


def coverage(briefs: Iterable[Brief]) -> dict[str, Any]:
    """What the corpus exercises, so a gap is visible before a run.

    A corpus of twenty briefs that all stress waves and placement is one test
    written twenty times, and it would pass every change that broke everything
    else.
    """

    briefs = list(briefs)
    stresses: dict[str, int] = {}
    for brief in briefs:
        for item in brief.stresses:
            stresses[item] = stresses.get(item, 0) + 1
    return {
        "briefs": len(briefs),
        "genres": genres(briefs),
        "distinctGenres": len(genres(briefs)),
        "stresses": dict(sorted(stresses.items())),
        "distinctStresses": len(stresses),
        "baselines": [brief.id for brief in briefs if brief.baseline],
    }


def build_one(
    root: Path,
    brief: Brief,
    *,
    scaffold: bool = True,
    mode: str = BUILD_MODE,
) -> Outcome:
    """Produce one brief and report every stage verdict.

    Failures are captured rather than raised: a corpus run that stops at the
    first broken genre tells you about one game, which is the situation the
    corpus exists to end.
    """

    from .producer import produce

    started = time.monotonic()
    detail: dict[str, Any] = {
        "mode": mode,
        "declaredGenre": brief.genre,
    }
    try:
        required = _required_stages(mode, scaffold=scaffold)
        executable_genre = production_genre(brief.genre)
        detail["productionGenre"] = executable_genre
        if executable_genre != brief.genre:
            detail["genreProjection"] = "canonical-or-supported-base-family"
        run = produce(
            Path(root),
            brief.brief,
            game_id=brief.id,
            genre=executable_genre,
            scaffold=scaffold,
            # The cheap corpus measures deterministic source + Rojo packaging.
            # Geometry is named as omitted, not promoted to success; implement
            # consumes it optionally and the release gate depends on it hard.
            skip_stages=("geometry",) if mode == BUILD_MODE else (),
        )
    except Exception as error:  # noqa: BLE001 - the point is to record, not raise
        return Outcome(id=brief.id, genre=brief.genre, ok=False,
                       detail=detail,
                       error=f"{type(error).__name__}: {error}",
                       seconds=time.monotonic() - started)

    stages = {result.stage: result.status for result in run.results}
    build = run.result("build")
    art = run.result("art")
    design = run.result("design")
    if build is not None and build.detail:
        detail["placeBytes"] = build.detail.get("bytes")
        detail["instances"] = build.detail.get("instances")
    if art is not None and art.detail:
        detail["artKey"] = art.detail.get("key")
        detail["weightedMean"] = art.detail.get("weightedMean")

    refusals: list[str] = []
    for stage in required:
        reason = _stage_refusal(run.result(stage))
        if reason:
            refusals.append(f"{stage}: {reason}")

    compiled_genre = (
        design.detail.get("genre")
        if design is not None and isinstance(design.detail, dict)
        else None
    )
    detail["compiledGenre"] = compiled_genre
    if not _stage_refusal(design) and compiled_genre != executable_genre:
        refusals.append(
            "design: compiled genre does not match the declared executable "
            f"genre ({compiled_genre!r} != {executable_genre!r})"
        )

    if mode in (RUNTIME_MODE, RELEASE_CANDIDATE_MODE):
        refusals.extend(_runtime_refusals(run.result("release_candidate")))

    required_set = set(required)
    non_required_failures = [
        result.stage for result in run.results
        if result.status == "FAILED" and result.stage not in required_set
    ]
    detail["requiredStages"] = list(required)
    detail["refusals"] = refusals
    detail["nonRequiredFailures"] = non_required_failures
    release = run.result("release_candidate")
    if release is not None and release.detail:
        detail["releaseStatus"] = release.detail.get("status")
        detail["runtimeObserved"] = list(release.detail.get("observed") or ())
        detail["runtimeOutstanding"] = list(release.detail.get("outstanding") or ())

    return Outcome(
        id=brief.id, genre=brief.genre,
        ok=not refusals,
        stages=stages, detail=detail,
        error="; ".join(refusals),
        seconds=time.monotonic() - started,
    )


def run(
    root: Path,
    *,
    only: Iterable[str] = (),
    scaffold: bool = True,
    relative: Path | str = DEFAULT_PATH,
    mode: str = BUILD_MODE,
) -> dict[str, Any]:
    """Build every brief and report what changed shape.

    No quality assertion. The scene critic's thresholds came from two frames of
    one game and say so in their own calibration record; applying them to a
    racing game would enforce a siege's taste. What this asserts is that each
    brief still becomes a game.
    """

    # Refuse an invalid mode even for an empty filter. Otherwise a misspelled
    # release run can return a vacuous clean sweep without exercising anything.
    _required_stages(mode, scaffold=scaffold)
    briefs = load(root, relative)
    wanted = set(only)
    if wanted:
        unknown = wanted - {brief.id for brief in briefs}
        if unknown:
            raise CorpusError(
                "unknown corpus brief id(s): " + ", ".join(sorted(unknown))
            )
        briefs = [brief for brief in briefs if brief.id in wanted]

    outcomes = [
        build_one(root, brief, scaffold=scaffold, mode=mode) for brief in briefs
    ]
    failed = [outcome for outcome in outcomes if not outcome.ok]
    built = [
        outcome for outcome in outcomes
        if outcome.stages.get("build") == "OK"
        and not any(
            refusal.startswith("build:")
            for refusal in outcome.detail.get("refusals", ())
        )
    ]
    keys = {outcome.detail.get("artKey") for outcome in outcomes
            if outcome.detail.get("artKey")}

    return {
        "schemaVersion": 1,
        "corpus": str(relative),
        "mode": mode,
        "coverage": coverage(briefs),
        "built": len(built),
        "passed": len(outcomes) - len(failed),
        "failed": [outcome.id for outcome in failed],
        "artKeysUsed": sorted(keys),
        "seconds": round(sum(outcome.seconds for outcome in outcomes), 1),
        "outcomes": [outcome.to_dict() for outcome in outcomes],
        "note": {
            BUILD_MODE: (
                "build-level only: STATICALLY_VALIDATED at best. Runtime, "
                "interaction and visual evidence are not required in this mode"
            ),
            RUNTIME_MODE: (
                "fails closed unless the producer gate records every required "
                "runtime observation; this runner does not itself operate Studio"
            ),
            RELEASE_CANDIDATE_MODE: (
                "requires every production stage plus the producer's runtime-backed "
                "candidate verdict; it does not authorize the immutable rqe release gate"
            ),
        }[mode],
    }
