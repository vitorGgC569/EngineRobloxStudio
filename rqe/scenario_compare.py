"""Compare two scenario runs, so a scenario becomes a regression instrument.

A scenario that only ever reports PASS or FAIL is a test. One whose runs can be
compared is an instrument: it says *which* step changed verdict, which is the
difference between "something broke" and "step 4 stopped finding the prompt".

Two comparisons matter and they are not the same question:

**Did the verdict change?** A step that passed and now fails is a regression. A
step that failed and now passes is a fix, and reporting it is how a repair loop
knows it worked rather than assuming.

**Did the shape change?** A scenario whose steps were edited between runs is not
comparable at all, and treating it as comparable produces a regression report
about a step that no longer exists. That is checked first and refuses everything
else.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence


class ScenarioCompareError(ValueError):
    """The two runs cannot be compared."""


@dataclass(frozen=True)
class StepDelta:
    index: int
    kind: str
    before: str
    after: str

    @property
    def kind_of_change(self) -> str:
        if self.before == self.after:
            return "unchanged"
        if self.before == "PASS":
            return "regression"
        if self.after == "PASS":
            return "fix"
        return "changed"

    def to_dict(self) -> dict[str, Any]:
        return {
            "index": self.index,
            "kind": self.kind,
            "before": self.before,
            "after": self.after,
            "change": self.kind_of_change,
        }


@dataclass
class ScenarioComparison:
    comparable: bool
    scenario: str
    before_status: str
    after_status: str
    deltas: list[StepDelta] = field(default_factory=list)
    incomparable_reason: str | None = None

    @property
    def regressions(self) -> list[StepDelta]:
        return [item for item in self.deltas if item.kind_of_change == "regression"]

    @property
    def fixes(self) -> list[StepDelta]:
        return [item for item in self.deltas if item.kind_of_change == "fix"]

    @property
    def changed(self) -> list[StepDelta]:
        return [item for item in self.deltas if item.kind_of_change != "unchanged"]

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "comparable": self.comparable,
            "incomparableReason": self.incomparable_reason,
            "scenario": self.scenario,
            "beforeStatus": self.before_status,
            "afterStatus": self.after_status,
            "steps": len(self.deltas),
            "regressions": [item.to_dict() for item in self.regressions],
            "fixes": [item.to_dict() for item in self.fixes],
            "changed": [item.to_dict() for item in self.changed],
            "regressionCount": len(self.regressions),
            "fixCount": len(self.fixes),
            "identical": self.comparable and not self.changed,
        }

    def summary(self) -> str:
        if not self.comparable:
            return f"incomparable: {self.incomparable_reason}"
        if not self.changed:
            return f"{self.scenario}: identical, {len(self.deltas)} steps unchanged"
        lines = [
            f"{self.scenario}: {len(self.regressions)} regression(s), {len(self.fixes)} fix(es)"
        ]
        for delta in self.changed:
            lines.append(
                f"  step {delta.index} ({delta.kind}): {delta.before} -> {delta.after}"
            )
        return "\n".join(lines)


def _steps(document: Mapping[str, Any]) -> list[dict[str, Any]]:
    steps = document.get("steps")
    if not isinstance(steps, list):
        raise ScenarioCompareError("a scenario result must carry a steps array")
    return [item for item in steps if isinstance(item, dict)]


def _signature(steps: Sequence[Mapping[str, Any]]) -> tuple[str, ...]:
    """What the scenario *did*, ignoring how it went.

    Two runs are only comparable when they executed the same sequence of step
    kinds. Comparing across an edited scenario produces a regression report
    about a step that no longer exists.
    """

    return tuple(str(item.get("kind", "?")) for item in steps)


def compare_results(
    before: Mapping[str, Any],
    after: Mapping[str, Any],
) -> ScenarioComparison:
    """Compare two scenario results step by step."""

    before_steps = _steps(before)
    after_steps = _steps(after)

    scenario = str(after.get("scenario") or before.get("scenario") or "unnamed")
    before_status = str(before.get("status", "UNKNOWN"))
    after_status = str(after.get("status", "UNKNOWN"))

    before_scenario = str(before.get("scenario") or "")
    after_scenario = str(after.get("scenario") or "")
    if before_scenario and after_scenario and before_scenario != after_scenario:
        return ScenarioComparison(
            comparable=False,
            scenario=scenario,
            before_status=before_status,
            after_status=after_status,
            incomparable_reason=(
                f"these are different scenarios: {before_scenario!r} and {after_scenario!r}"
            ),
        )

    if _signature(before_steps) != _signature(after_steps):
        return ScenarioComparison(
            comparable=False,
            scenario=scenario,
            before_status=before_status,
            after_status=after_status,
            incomparable_reason=(
                f"the scenario was edited between runs: {len(before_steps)} steps "
                f"({', '.join(_signature(before_steps)) or 'none'}) became "
                f"{len(after_steps)} ({', '.join(_signature(after_steps)) or 'none'})"
            ),
        )

    deltas = [
        StepDelta(
            index=int(after_step.get("index", position)),
            kind=str(after_step.get("kind", "?")),
            before=str(before_step.get("status", "UNKNOWN")),
            after=str(after_step.get("status", "UNKNOWN")),
        )
        for position, (before_step, after_step) in enumerate(zip(before_steps, after_steps))
    ]

    return ScenarioComparison(
        comparable=True,
        scenario=scenario,
        before_status=before_status,
        after_status=after_status,
        deltas=deltas,
    )


def compare_files(before: Path, after: Path) -> dict[str, Any]:
    """Compare two stored scenario results."""

    for path in (before, after):
        if not Path(path).is_file():
            raise ScenarioCompareError(f"scenario result not found: {path}")

    comparison = compare_results(
        json.loads(Path(before).read_text(encoding="utf-8")),
        json.loads(Path(after).read_text(encoding="utf-8")),
    )
    payload = comparison.to_dict()
    payload["summary"] = comparison.summary()
    payload["before"] = str(before)
    payload["after"] = str(after)
    return payload
