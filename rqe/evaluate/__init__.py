"""EVALUATE, REPAIR, REGRESSION, RELEASE_CANDIDATE: the lower half.

The factory could produce a place file and had nothing to say about whether the
game inside it was sound. This closes that, using the SDK's own validators
rather than a second opinion: `Shop.problems`, `Tower.problems`,
`Leaderboard.problems` and `Progression.pacingProblems` executed on the emitted
catalogues through the headless harness.

Reimplementing those rules here would be the familiar failure. The checker would
drift from the code the game runs and then agree with itself while the game
misbehaves -- and the drift would be invisible, because both sides would keep
passing.

**What this cannot see is named, not omitted.** Everything here runs without
Studio, so it knows nothing about whether the place opens, whether the character
stands on anything, or what a frame looks like. Those are listed as outstanding.
A report that enumerates only what it checked reads as a clean bill of health,
and that is how a game ships broken with a green pipeline behind it.

**Repair applies only what is determined.** A price of zero has one sensible fix
and a wave that cannot be cleared has many, so the first is applied and the
second is handed back. A loop that edits design decisions is a loop that quietly
makes a different game.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from ..provenance import sha256_json


#: Checks that need a running game. Listed explicitly so the release verdict can
#: report them as outstanding rather than letting their absence read as success.
NEEDS_RUNTIME = (
    "the place opens in Studio",
    "the character spawns onto solid ground rather than falling",
    "no errors in the first sixty seconds of play",
    "a trustworthy frame of the running game",
    "frame time and memory against the performance budget",
)

# These checks apply to every emitted game.  Optional economy/content validators
# add coverage, but a release candidate that never resolved systems or inspected
# the emitted spawn/world source has not completed even the generic static pass.
REQUIRED_STATIC_CHECKS = (
    "system resolution",
    "spawn and ground",
)


@dataclass(frozen=True)
class Finding:
    """One problem, and whether anything can fix it without a decision."""

    rule: str
    severity: str
    message: str
    #: A fix this module can apply on its own, when there is exactly one.
    repair: dict[str, Any] | None = None

    @property
    def blocking(self) -> bool:
        return self.severity == "blocking"

    def to_dict(self) -> dict[str, Any]:
        payload = {"rule": self.rule, "severity": self.severity, "message": self.message}
        if self.repair is not None:
            payload["repairable"] = True
            payload["repair"] = self.repair
        return payload


@dataclass
class Evaluation:
    game_id: str
    findings: list[Finding] = field(default_factory=list)
    checked: list[str] = field(default_factory=list)
    unavailable: list[str] = field(default_factory=list)

    @property
    def blocking(self) -> list[Finding]:
        return [f for f in self.findings if f.blocking]

    @property
    def ok(self) -> bool:
        return not self.blocking

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "gameId": self.game_id,
            "ok": self.ok,
            "findings": [f.to_dict() for f in self.findings],
            "blocking": len(self.blocking),
            "checked": list(self.checked),
            # Not "passed". These were not run, and the difference is the whole
            # point of listing them.
            "notChecked": list(NEEDS_RUNTIME),
            "unavailable": list(self.unavailable),
        }

    def summary(self) -> str:
        lines = [
            f"{'OK' if self.ok else 'BLOCKED'}  {self.game_id}: "
            f"{len(self.findings)} finding(s), {len(self.blocking)} blocking"
        ]
        for finding in self.findings:
            lines.append(f"  {finding.severity:8s} {finding.rule}: {finding.message}")
        return "\n".join(lines)


def _harness_problems(root: Path, body: str, data: dict[str, Any]) -> tuple[list[str], str]:
    """Run a validator body and return its problems, or why it could not run."""

    from ..luau_harness import HarnessError, run

    try:
        result = run(root, libraries=["roblox/lib/GameKit"], body=body, data=data, timeout=60)
    except HarnessError as exc:
        return [], f"the harness could not run: {exc}"
    if not result.ok:
        return [], (result.stderr.strip().splitlines() or ["the validator failed"])[-1]

    decoded = result.json_lines()
    if not decoded:
        return [], "the validator produced no report"
    payload = decoded[-1]
    if isinstance(payload, dict):
        return list(payload.get("problems") or []), ""
    return [], "the validator produced an unreadable report"


def evaluate_game(root: Path, model: Any, context: dict[str, Any]) -> Evaluation:
    """Run every validator that applies to what this game emitted."""

    evaluation = Evaluation(game_id=model.id)

    # -- progression pacing ----------------------------------------------
    economy = context.get("economy")
    if economy is not None and getattr(economy, "tier_costs", None):
        body = """
        local Progression = Require("Progression")
        local tiers = {}
        for index, cost in ipairs(COSTS) do
            table.insert(tiers, { id = "t" .. index, index = index, displayName = "T" .. index,
                cost = cost, currency = "cash", incomeMultiplier = 1 })
        end
        local report = Progression.pacing(Progression.define(tiers), INCOME)
        local quoted = {}
        for _, problem in ipairs(Progression.pacingProblems(report, {})) do
            table.insert(quoted, string.format("%q", problem))
        end
        print('{"problems":[' .. table.concat(quoted, ",") .. ']}')
        """
        problems, blocked = _harness_problems(root, body, {
            "COSTS": [round(float(c), 2) for c in economy.tier_costs],
            "INCOME": float(getattr(economy, "base_income", 1.0) or 1.0),
        })
        if blocked:
            evaluation.unavailable.append(f"progression pacing: {blocked}")
        else:
            evaluation.checked.append("progression pacing")
            for problem in problems:
                evaluation.findings.append(Finding("pacing", "major", problem))

    # -- the emitted catalogue -------------------------------------------
    catalogue = (context.get("content") or {}).get("catalogue") or {}
    entries = catalogue.get("entries") or []
    if entries:
        evaluation.checked.append("content catalogue")
        priced = [e for e in entries if isinstance(e, dict) and "price" in e]
        free = [e for e in priced if not e.get("price")]
        for entry in free:
            evaluation.findings.append(Finding(
                "catalogue-free-entry", "major",
                f"{entry.get('id', 'an entry')} costs nothing; in a priced catalogue "
                "that is a number somebody forgot rather than a gift",
                repair={"kind": "set-minimum-price", "id": entry.get("id")},
            ))

    # -- systems the game declared but nothing implements -----------------
    composition = context.get("composition")
    planned = list(getattr(composition, "planned", ()) or ())
    if planned:
        evaluation.findings.append(Finding(
            "system-planned", "blocking",
            f"{', '.join(planned)} {'is' if len(planned) == 1 else 'are'} declared by this "
            "game and implemented by nothing; the emitted stub raises on first use",
        ))
    if composition is not None:
        evaluation.checked.append("system resolution")

    # -- the world the player arrives in ----------------------------------
    implementation = context.get("implementation")
    if implementation is not None:
        evaluation.checked.append("spawn and ground")
        sources = getattr(implementation, "files", {})
        if not any("SpawnLocation" in s or "Blockout.build" in s for s in sources.values()):
            evaluation.findings.append(Finding(
                "no-spawn", "blocking",
                "nothing in this game creates a SpawnLocation; the player falls out of "
                "the world at spawn, which reads as a physics bug",
            ))

    return evaluation


def repair_findings(
    root: Path, model: Any, evaluation: Evaluation, context: dict[str, Any]
) -> dict[str, Any]:
    """Apply the findings with exactly one sensible fix."""

    applied: list[dict[str, Any]] = []
    deferred: list[dict[str, Any]] = []

    catalogue = (context.get("content") or {}).get("catalogue") or {}
    entries = catalogue.get("entries") or []
    by_id = {e.get("id"): e for e in entries if isinstance(e, dict)}

    for finding in evaluation.findings:
        if finding.repair is None:
            deferred.append({
                "rule": finding.rule,
                "message": finding.message,
                # Said plainly rather than left blank: the reason it was not
                # repaired is a design decision, not a missing feature.
                "needs": "a decision this loop must not make on its own",
            })
            continue

        repair = finding.repair
        if repair.get("kind") == "set-minimum-price":
            entry = by_id.get(repair.get("id"))
            if entry is None:
                deferred.append({"rule": finding.rule, "message": finding.message,
                                 "needs": "the entry it names is no longer in the catalogue"})
                continue
            # The floor comes from the cheapest priced sibling, so the repair
            # stays inside the economy the designer set rather than inventing a
            # number.
            others = [
                float(e["price"]) for e in entries
                if isinstance(e, dict) and e.get("price") and e.get("id") != entry.get("id")
            ]
            entry["price"] = round(min(others), 2) if others else 1.0
            applied.append({
                "rule": finding.rule, "id": entry.get("id"), "price": entry["price"],
                "why": "priced at the cheapest priced sibling rather than a number chosen here",
            })

    return {
        "ok": True,
        "applied": applied,
        "deferred": deferred,
        "note": (
            "only findings with exactly one sensible fix are applied. A loop that "
            "edits design decisions is a loop that quietly makes a different game"
        ),
    }


def _history_path(root: Path, game_id: str) -> Path:
    return root / "games" / game_id / ".evaluation.json"


def _finding_record(finding: Finding) -> dict[str, str]:
    record = {
        "rule": finding.rule,
        "severity": finding.severity,
        "message": finding.message,
    }
    record["fingerprint"] = sha256_json(record)
    return record


def _finding_label(record: dict[str, Any]) -> str:
    return f"{record.get('rule')} [{record.get('severity')}]: {record.get('message')}"


def compare_to_previous(root: Path, model: Any, evaluation: Evaluation | None) -> dict[str, Any]:
    """Compare with the last *accepted* baseline without mutating it.

    Comparison and baseline promotion are deliberately separate.  Recording
    the current evaluation before the release gate has accepted its exact build
    lets a failed run teach the next run that the same defect is normal.
    """

    if evaluation is None:
        return {"ok": False, "blocked": "nothing was evaluated, so nothing can be compared"}

    path = _history_path(root, model.id)
    current_records = [_finding_record(finding) for finding in evaluation.findings]
    current = {record["fingerprint"]: record for record in current_records}

    previous: dict[str, dict[str, str]] = {}
    first_run = True
    baseline_build_id = None
    if path.is_file():
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
            if document.get("schemaVersion") != 2 or document.get("status") != "ACCEPTED_BASELINE":
                return {
                    "ok": False,
                    "blocked": f"the recorded evaluation at {path} is not an accepted v2 baseline",
                }
            records = document.get("findings")
            if not isinstance(records, list):
                raise ValueError("findings is not an array")
            for record in records:
                if not isinstance(record, dict):
                    raise ValueError("finding is not an object")
                fingerprint = record.get("fingerprint")
                expected = sha256_json({
                    "rule": record.get("rule"),
                    "severity": record.get("severity"),
                    "message": record.get("message"),
                })
                if fingerprint != expected:
                    raise ValueError("finding fingerprint does not match its content")
                previous[fingerprint] = record
            baseline_build_id = document.get("buildId")
            first_run = False
        except (OSError, json.JSONDecodeError, ValueError):
            # A corrupt history is not a clean one. Saying so keeps the next run
            # from reading "no regressions" as "nothing got worse".
            return {"ok": False, "blocked": f"the recorded evaluation at {path} is unreadable"}

    introduced_keys = sorted(set(current) - set(previous))
    fixed_keys = sorted(set(previous) - set(current))
    carried_keys = sorted(set(current) & set(previous))

    return {
        "ok": not introduced_keys,
        "firstRun": first_run,
        "baselinePresent": not first_run,
        "baselineBuildId": baseline_build_id,
        "introduced": [_finding_label(current[key]) for key in introduced_keys],
        "fixed": [_finding_label(previous[key]) for key in fixed_keys],
        "carried": [_finding_label(current[key]) for key in carried_keys],
        "note": (
            "read-only comparison against the last accepted exact-build baseline; "
            "rule, severity and message all participate in finding identity"
        ),
    }


def record_evaluation_baseline(
    root: Path,
    model: Any,
    evaluation: Evaluation,
    *,
    build: dict[str, Any],
    runtime: dict[str, Any],
) -> dict[str, Any]:
    """Atomically promote an evaluation only after its release verdict passed."""

    identity = runtime.get("identity") if isinstance(runtime, dict) else None
    expected = {
        "buildId": build.get("buildId"),
        "placeSha256": build.get("placeSha256"),
        "sourceSha256": (build.get("source") or {}).get("sha256"),
    }
    if not isinstance(identity, dict) or any(identity.get(k) != v for k, v in expected.items()):
        raise ValueError("an evaluation baseline must be bound to matching Studio evidence")
    if runtime.get("source") != "studio-bridge":
        raise ValueError("an evaluation baseline requires studio-bridge evidence")
    document = {
        "schemaVersion": 2,
        "status": "ACCEPTED_BASELINE",
        "gameId": model.id,
        **expected,
        "findings": [_finding_record(finding) for finding in evaluation.findings],
    }
    path = _history_path(root, model.id)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.pending")
    temporary.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)
    return {"path": str(path), "buildId": expected["buildId"], "findingCount": len(evaluation.findings)}


def collect_runtime_evidence(
    hub: str = "",
    *,
    budget: dict[str, Any] | None = None,
    capture: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Ask a live session for the evidence the gate needs.

    Every check is satisfied by a measurement or not at all. A check that cannot
    be taken is absent from `satisfied`, never defaulted to true -- which is the
    difference between a gate and a formality.

    `capture` is passed in rather than taken here: a trustworthy frame needs the
    Studio window focused and unobstructed, and that is a property of the desktop
    rather than of the game. The capture tool decides trustworthiness; this only
    records whether it said yes.
    """

    import os

    from ..hub.client import StudioBridge
    from ..hub.protocol import BridgeError

    limits = budget or {"frameP99Ms": 33.0, "memoryMb": 1024.0}
    bridge = StudioBridge(hub, token=os.environ.get("RQE_BRIDGE_TOKEN"))
    satisfied: list[str] = []
    measurements: dict[str, Any] = {}
    unavailable: list[str] = []

    try:
        measurements["session"] = bridge.pin_to_running()
        satisfied.append(NEEDS_RUNTIME[0])
    except BridgeError as exc:
        return {
            "schemaVersion": 1,
            "source": "studio-bridge",
            "validationLevel": "NOT_VALIDATED",
            "satisfied": [],
            "measurements": {},
            "unavailable": [f"no running session: {exc}"],
        }

    def probe(
        label: str, method: str, params: dict[str, Any], timeout: float = 20.0
    ) -> dict[str, Any] | None:
        try:
            return bridge.call(method, params, timeout=timeout)
        except BridgeError as exc:
            unavailable.append(f"{label}: {exc}")
            return None

    state = probe("spawn", "actor.state", {})
    if state is not None:
        measurements["grounded"] = state.get("grounded")
        measurements["floorMaterial"] = state.get("floorMaterial")
        if state.get("grounded"):
            satisfied.append(NEEDS_RUNTIME[1])

    logs = probe("logs", "log.tail", {"limit": 200})
    if logs is not None:
        errors = int((logs.get("counts") or {}).get("error", 0))
        measurements["errors"] = errors
        if errors == 0:
            satisfied.append(NEEDS_RUNTIME[2])

    if capture is not None:
        measurements["capture"] = {
            "path": capture.get("path"),
            "trustworthy": bool(capture.get("trustworthy")),
            "issues": capture.get("integrityIssues") or [],
        }
        if capture.get("trustworthy"):
            satisfied.append(NEEDS_RUNTIME[3])

    # Sampling commands need a window plus the round trip. The default timeout
    # is sized for a read, and using it here reports "the plugin did not answer"
    # for a command that was working exactly as specified.
    sample_seconds = float((budget or {}).get("sampleSeconds", 3))
    metrics = probe(
        "performance", "runtime.metrics", {"seconds": sample_seconds},
        timeout=sample_seconds + 25.0,
    )
    if metrics is not None:
        # The p99, not the mean. A mean of 14 ms with a p99 of 90 is a game that
        # feels broken to everyone and measures fine.
        frame = metrics.get("frameTimeMs") or metrics.get("frame") or {}
        p99 = frame.get("p99") if isinstance(frame, dict) else None
        measurements["frameP99Ms"] = p99
        measurements["budget"] = limits
        if isinstance(p99, (int, float)) and p99 <= float(limits["frameP99Ms"]):
            satisfied.append(NEEDS_RUNTIME[4])

    return {
        "schemaVersion": 1,
        "source": "studio-bridge",
        "validationLevel": "RUNTIME_VALIDATED",
        "satisfied": satisfied,
        "measurements": measurements,
        "unavailable": unavailable,
    }


def release_verdict(
    evaluation: Evaluation | None,
    regression: dict[str, Any] | None,
    *,
    build: dict[str, Any] | None = None,
    runtime: dict[str, Any] | None = None,
    production: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """The gate. Absence of evidence never passes.

    A candidate is the end of `play -> observe -> capture -> evaluate`, so a
    build nobody has run cannot be one. The first version of this returned
    RELEASE_CANDIDATE with all five runtime checks outstanding and a note
    explaining that nobody had looked -- which is a pass with an asterisk, and
    an asterisk is not what anyone reads.

    `runtime` carries the evidence from a live session: which of NEEDS_RUNTIME
    were satisfied. Without it the verdict is BLOCKED and the missing checks are
    blockers rather than footnotes.
    """

    blockers: list[str] = []
    if evaluation is None:
        blockers.append("nothing was evaluated; an unmeasured build is not a candidate")
    else:
        for finding in evaluation.blocking:
            blockers.append(f"{finding.rule}: {finding.message}")
        for unavailable in evaluation.unavailable:
            blockers.append(f"static evaluation unavailable: {unavailable}")
        missing_static = [check for check in REQUIRED_STATIC_CHECKS if check not in evaluation.checked]
        for check in missing_static:
            blockers.append(f"static evaluation did not cover: {check}")
    if build is None:
        blockers.append("nothing was built")
    elif not build.get("ok"):
        blockers.extend(build.get("problems") or [build.get("blocked") or "the build failed"])
    elif build.get("compiles") is not True:
        blockers.append("the release build has no successful Luau compilation receipt")

    # Planning assets is not the same as integrating production assets.  The
    # lightweight producer must carry an explicit readiness receipt, and every
    # Blender mesh required by the plan must be approved rather than merely
    # produced with an advisory REVISE verdict.
    if not isinstance(production, dict):
        blockers.append("no production asset/geometry readiness receipt was supplied")
    else:
        assets = production.get("assets")
        geometry = production.get("geometry")
        if not isinstance(assets, dict) or assets.get("ok") is not True:
            blockers.append("the asset plan is absent or failed")
        elif assets.get("productionReady") is not True:
            blockers.append("the asset plan has no approved, integrated production-asset receipt")
        if not isinstance(geometry, dict) or geometry.get("ok") is not True:
            blockers.append("the geometry stage is absent or failed")
        else:
            planned = geometry.get("planned", 0)
            approved = geometry.get("approved", 0)
            if not isinstance(planned, int) or not isinstance(approved, int) or approved != planned:
                blockers.append("not every planned Blender mesh is approved for import")
    if regression is None:
        blockers.append("no regression comparison was made")
    else:
        if regression.get("introduced"):
            blockers.append(
                "this run introduced " + ", ".join(regression["introduced"])
            )
        if regression.get("ok") is False:
            reason = regression.get("blocked") or regression.get("error")
            if reason:
                blockers.append(f"regression comparison failed: {reason}")
            elif not regression.get("introduced"):
                blockers.append("regression comparison returned ok=false")

    # Runtime observations are useful only when bound to the exact source and
    # binary above.  A caller-provided list of satisfied checks without this
    # identity would recreate the fixture failure the release system replaced.
    if runtime is not None:
        if runtime.get("source") != "studio-bridge":
            blockers.append("runtime evidence was not measured by studio-bridge")
        identity = runtime.get("identity")
        if not isinstance(identity, dict):
            blockers.append("runtime evidence has no exact build identity")
        elif build is None:
            blockers.append("runtime identity cannot be checked because nothing was built")
        else:
            expected = {
                "buildId": build.get("buildId"),
                "placeSha256": build.get("placeSha256"),
                "sourceSha256": (build.get("source") or {}).get("sha256"),
            }
            for field, value in expected.items():
                if not isinstance(value, str) or not value:
                    blockers.append(f"build receipt has no {field} for runtime binding")
                elif identity.get(field) != value:
                    blockers.append(f"runtime {field} does not match the release build")

    satisfied = set((runtime or {}).get("satisfied") or ())
    outstanding = [check for check in NEEDS_RUNTIME if check not in satisfied]
    for check in outstanding:
        blockers.append(f"not observed on a running game: {check}")

    if blockers:
        status = "STATICALLY_CLEAN" if not evaluation or evaluation.ok else "BLOCKED"
        if any(not blocker.startswith("not observed") for blocker in blockers):
            status = "BLOCKED"
    else:
        status = "RELEASE_CANDIDATE"

    return {
        "schemaVersion": 1,
        "status": status,
        "blockers": blockers,
        # Never a footnote. A build that passes every static check and has never
        # been played is STATICALLY_CLEAN, which is a real and useful state --
        # and it is not a candidate.
        "outstanding": outstanding,
        "observed": sorted(satisfied),
        "note": (
            "RELEASE_CANDIDATE requires evidence from a running game. A build "
            "nobody has played is STATICALLY_CLEAN at best: every check that "
            "needs a session is a blocker, not an asterisk"
        ),
    }


__all__ = [
    "Evaluation", "Finding", "NEEDS_RUNTIME", "REQUIRED_STATIC_CHECKS",
    "collect_runtime_evidence", "compare_to_previous", "evaluate_game",
    "record_evaluation_baseline", "release_verdict", "repair_findings",
]
