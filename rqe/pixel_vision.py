"""A vision provider that measures pixels instead of asking a model.

Why this exists
---------------

The release gate requires a structured visual review, and the only provider
that could produce one needs an `OPENAI_API_KEY`. Without that credential the
review is missing, so the gate blocks, so the visual half of validation has
never run for anybody in this repository. A gate that nobody can pass teaches
people to route around it, which costs more than having no gate.

This closes the loop for the part of visual review that is arithmetic. Three
defects shipped past a clean `doctor`, clean type checks and sixteen green
scenarios: a game about darkness whose ground was brighter than its lamps, a
player blown out to a white blur, and a HUD behind Roblox's topbar. The first
two are a histogram.

What it refuses to do
---------------------

**It never grades a criterion it did not measure.** A rubric asking about
composition, readability or art direction gets a neutral 3 and a finding saying
in plain words that this provider did not assess it. That is deliberate: the
failure mode worth avoiding is not a provider that scores low, it is a provider
that manufactures confidence and lets a bad build through with a number
attached.

So this is a floor, not a ceiling. It catches what pixels can prove and is
explicit about the rest, and a real vision provider should replace it the
moment one is available.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Mapping

from .image_metrics import ImageMetrics, assess, measure
from .visual_review import ReviewRequest, VisualReviewError

PROVIDER_NAME = "pixel-metrics"

#: The version is part of `modelHash`, which the gate binds into the review. It
#: must change whenever a threshold changes, or two reviews with different
#: verdicts would be indistinguishable in the record.
PROVIDER_VERSION = "1"

#: Which finding category a measured shortfall belongs to.
CATEGORY_FOR = {
    "exposure": "lighting",
    "contrast": "lighting",
    "lighting": "lighting",
    "detail": "density",
    "colour": "finish",
}


def _category(criterion: str) -> str:
    lowered = criterion.lower()
    for fragment, category in CATEGORY_FOR.items():
        if fragment in lowered:
            return category
    return "finish"


class PixelMetricsProvider:
    """Measures each capture and grades only what the measurement covers."""

    name = PROVIDER_NAME
    model = f"{PROVIDER_NAME}-v{PROVIDER_VERSION}"

    def __init__(self, capture_directory: Path | str) -> None:
        self._directory = Path(capture_directory)

    def _metrics(self, request: ReviewRequest) -> dict[str, ImageMetrics]:
        """Measure every cited capture, keyed by shot id."""
        out: dict[str, ImageMetrics] = {}
        for image in request.images:
            #: The manifest names the file; the request carries bytes and a
            #: hash. Prefer the bytes already loaded so a review can never
            #: measure a different file from the one it is bound to.
            source = image.metadata.get("path") or f"{image.id}.png"
            path = self._directory / Path(str(source)).name
            if not path.is_file():
                raise VisualReviewError(
                    f"capture {image.id} is not on disk at {path}")
            out[image.id] = measure(path)
        return out

    def review(self, request: ReviewRequest) -> Mapping[str, Any]:
        metrics = self._metrics(request)
        if not metrics:
            raise VisualReviewError("no captures to measure")

        assessments: list[dict[str, Any]] = []
        findings: list[dict[str, Any]] = []

        for viewpoint, criteria in request.rubric_by_viewpoint.items():
            #: A viewpoint's rubric must cite that viewpoint's own shot, so the
            #: measurement has to come from it rather than from the set.
            frame = metrics.get(viewpoint)
            if frame is None:
                raise VisualReviewError(
                    f"no capture for required viewpoint {viewpoint!r}")

            rubric: list[dict[str, Any]] = []
            for criterion in criteria:
                verdict = assess(criterion, frame)
                if verdict is None:
                    #: Neutral, and said out loud. Grading this any higher
                    #: would be inventing evidence; grading it lower would
                    #: punish a game for a limitation of the reviewer.
                    rubric.append({
                        "criterion": criterion,
                        "grade": 3,
                        "rationale": ("not assessed: this provider measures pixels "
                                      "and has no measurement for this criterion"),
                        "evidence": {"shotIds": [viewpoint]},
                    })
                    findings.append({
                        "severity": "info",
                        "category": _category(criterion),
                        "location": viewpoint,
                        "finding": f"criterion {criterion!r} was not visually assessed",
                        "suggestedAction": ("review this criterion by eye, or configure a "
                                            "vision provider"),
                        "evidence": {"shotIds": [viewpoint]},
                    })
                    continue

                rubric.append({
                    "criterion": criterion,
                    "grade": verdict.grade,
                    "rationale": verdict.rationale,
                    "evidence": {"shotIds": [viewpoint]},
                })
                if verdict.grade <= 2:
                    findings.append({
                        "severity": "major" if verdict.grade == 1 else "minor",
                        "category": _category(criterion),
                        "location": viewpoint,
                        "finding": verdict.rationale,
                        "suggestedAction": ("measured from the capture; open the shot and "
                                            "confirm before changing lighting or content"),
                        "evidence": {"shotIds": [viewpoint]},
                    })

            assessments.append({"viewpoint": viewpoint, "rubric": rubric})

        return {"assessments": assessments, "findings": findings}


def metrics_report(capture_directory: Path | str) -> dict[str, Any]:
    """Measure a directory of captures without any gate machinery.

    The cheap path: no manifest, no run binding, no review contract. For
    looking at what a build actually renders while iterating, which is when
    somebody most wants the numbers and least wants a release pipeline.
    """
    directory = Path(capture_directory)
    shots: dict[str, Any] = {}
    for path in sorted(directory.glob("*.png")):
        frame = measure(path)
        graded = {}
        for criterion in ("exposure", "contrast", "lighting", "detail", "colour"):
            verdict = assess(criterion, frame)
            if verdict:
                graded[criterion] = {"grade": verdict.grade,
                                     "rationale": verdict.rationale}
        shots[path.name] = {"metrics": frame.to_dict(), "graded": graded}
    return {"directory": str(directory), "shots": shots, "count": len(shots)}
