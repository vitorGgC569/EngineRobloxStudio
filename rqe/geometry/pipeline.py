"""Brief to approved asset: the modelling loop, run end to end.

    brief + program
        -> build      (Blender executes the program)
        -> analyse    (topology measured inside Blender)
        -> validate   (Roblox's rules applied on this side)
        -> render     (five fixed angles)
        -> critique   (the renders read back and scored)
        -> package    (everything, hashed)
        -> verdict    APPROVED_FOR_IMPORT | REVISE | BLOCKED

The verdict is the point, and it takes both halves. `validate` answers "will
Roblox accept this mesh"; `critique` answers "is it worth looking at". A
watertight, under-budget, correctly-unwrapped cube passes the first and fails
the second, so approval requires both and the two failures are reported
separately: BLOCKED goes back to a human, REVISE goes back to the modeller with
concrete changes.

Nothing here publishes. That is the asset pipeline's job, and publishing is
irreversible, so it does not belong inside a loop that is expected to iterate.
"""

from __future__ import annotations

import json
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Sequence

from .brief import AssetBrief, choose_backend
from .critic import CriticError, Critique, critique_package
from .package import AssetPackage
from .program import Program, ProgramError, compile_program
from .validation import Budget, MeshValidation, validate_analysis
from .worker import BlenderUnavailable, GeometryWorker, JobResult


class PipelineError(RuntimeError):
    """The pipeline could not run."""


@dataclass
class BuildOutcome:
    """One revision, and everything known about it."""

    status: str
    revision: int
    package: AssetPackage | None = None
    validation: MeshValidation | None = None
    brief_findings: list[str] = field(default_factory=list)
    blockers: list[str] = field(default_factory=list)
    critique: Critique | None = None
    stages: dict[str, Any] = field(default_factory=dict)
    duration_seconds: float = 0.0

    @property
    def approved(self) -> bool:
        return self.status == "APPROVED_FOR_IMPORT"

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "status": self.status,
            "revision": self.revision,
            "approved": self.approved,
            "package": self.package.to_dict() if self.package else None,
            "validation": self.validation.to_dict() if self.validation else None,
            "briefFindings": list(self.brief_findings),
            "blockers": list(self.blockers),
            "critique": self.critique.to_dict() if self.critique else None,
            "revisions": self.critique.revisions if self.critique else [],
            "stages": self.stages,
            "durationSeconds": round(self.duration_seconds, 3),
        }

    def summary(self) -> str:
        lines = [f"{self.status} (revision {self.revision})"]
        for blocker in self.blockers:
            lines.append(f"  BLOCKED: {blocker}")
        for finding in self.brief_findings:
            lines.append(f"  brief:   {finding}")
        if self.validation is not None:
            for finding in self.validation.findings:
                lines.append(f"  {finding.severity:8s} {finding.rule}: {finding.message}")
        if self.critique is not None:
            lines.append(f"  visual   {self.critique.overall:.0f}/100 {self.critique.verdict}")
            for item in self.critique.revisions:
                lines.append(f"  revise:  {item}")
        return "\n".join(lines)


@dataclass
class RefinementOutcome:
    """A whole revision loop: every attempt, and why it stopped."""

    attempts: list[BuildOutcome] = field(default_factory=list)
    stopped_because: str = "exhausted"

    @property
    def approved(self) -> bool:
        return bool(self.attempts) and self.attempts[-1].approved

    @property
    def best(self) -> BuildOutcome | None:
        """The highest-scoring attempt, which is not always the last one.

        A revision can make an asset worse. Returning the final attempt
        regardless would quietly ship a regression the loop itself measured.
        """

        scored = [a for a in self.attempts if a.critique is not None]
        if not scored:
            return self.attempts[-1] if self.attempts else None
        return max(scored, key=lambda a: a.critique.overall)  # type: ignore[union-attr]

    def to_dict(self) -> dict[str, Any]:
        trajectory = [
            {
                "revision": attempt.revision,
                "status": attempt.status,
                "overall": round(attempt.critique.overall, 2) if attempt.critique else None,
            }
            for attempt in self.attempts
        ]
        best = self.best
        regressed = [
            later["revision"]
            for earlier, later in zip(trajectory, trajectory[1:])
            if earlier["overall"] is not None and later["overall"] is not None
            and later["overall"] < earlier["overall"]
        ]
        return {
            "schemaVersion": 1,
            "approved": self.approved,
            "stoppedBecause": self.stopped_because,
            "revisions": len(self.attempts),
            "trajectory": trajectory,
            "bestRevision": best.revision if best else None,
            # Named rather than smoothed over: a revision that scored worse than
            # the one before it is the signal that the loop is being driven in
            # the wrong direction, and it is invisible in the final score alone.
            "regressedAt": regressed,
            "final": self.attempts[-1].to_dict() if self.attempts else None,
        }


def _fingerprint(document: dict[str, Any]) -> str:
    import hashlib

    return hashlib.sha256(
        json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


DEFAULT_VIEWS = ("front", "back", "left", "right", "perspective")


class GeometryPipeline:
    """Runs briefs and programs through Blender and returns asset packages."""

    def __init__(
        self,
        workspace: Path,
        worker: GeometryWorker | None = None,
        *,
        views: Sequence[str] = DEFAULT_VIEWS,
    ) -> None:
        self.workspace = Path(workspace)
        self.workspace.mkdir(parents=True, exist_ok=True)
        self._worker = worker
        self.views = tuple(views)

    @property
    def worker(self) -> GeometryWorker:
        if self._worker is None:
            self._worker = GeometryWorker()
        return self._worker

    def capabilities(self) -> dict[str, Any]:
        from .worker import capabilities as worker_capabilities

        return worker_capabilities()

    # -- the loop --------------------------------------------------------

    def build(
        self,
        brief: AssetBrief,
        program_document: dict[str, Any],
        *,
        revision: int = 1,
        backend_override: str | None = None,
    ) -> BuildOutcome:
        """Execute one revision and return its verdict."""

        import time

        started = time.monotonic()
        stages: dict[str, Any] = {}

        selection = choose_backend(brief, override=backend_override)
        stages["backend"] = selection
        if selection["backend"] != "blender":
            # Honest rather than helpful: this pipeline models with Blender. A
            # brief routed elsewhere is not a failure, and silently building it
            # here anyway would use the wrong tool for the job.
            return BuildOutcome(
                status="ROUTED_ELSEWHERE",
                revision=revision,
                blockers=[
                    f"this brief routes to the {selection['backend']} backend: {selection['reason']}"
                ],
                stages=stages,
                duration_seconds=time.monotonic() - started,
            )

        # -- compile ------------------------------------------------------
        try:
            program = compile_program(program_document)
        except ProgramError as exc:
            return BuildOutcome(
                status="PROGRAM_INVALID",
                revision=revision,
                blockers=[str(exc)],
                stages=stages,
                duration_seconds=time.monotonic() - started,
            )
        stages["program"] = {"id": program.id, "steps": len(program.steps), "result": program.result}

        try:
            worker = self.worker
        except BlenderUnavailable as exc:
            return BuildOutcome(
                status="BLOCKED",
                revision=revision,
                blockers=[str(exc)],
                stages=stages,
                duration_seconds=time.monotonic() - started,
            )

        # -- build --------------------------------------------------------
        package_root = self.workspace / f"{brief.id}-r{revision}"
        if package_root.exists():
            # A revision directory that already exists holds the previous
            # attempt. Reusing it would mix two builds in one manifest.
            shutil.rmtree(package_root)
        package_root.mkdir(parents=True)

        build_result = worker.build(program.to_dict(), package_root)
        stages["build"] = _stage(build_result)
        if not build_result.ok:
            return BuildOutcome(
                status="BUILD_FAILED",
                revision=revision,
                blockers=[build_result.error or "the modelling program failed"],
                stages=stages,
                duration_seconds=time.monotonic() - started,
            )

        package = AssetPackage.create(self.workspace, f"{brief.id}-r{revision}")
        # `build` wrote straight into the revision directory; move its output
        # into the package layout rather than leaving two shapes on disk.
        for category, source_dir in (("project", package_root / "project"), ("export", package_root / "export")):
            if source_dir.is_dir():
                for path in sorted(source_dir.iterdir()):
                    if path.is_file():
                        package.adopt(path, category)
        shutil.rmtree(package_root, ignore_errors=True)

        package.write_program(program.to_dict())
        package.write_analysis("brief", brief.to_dict())

        mesh_path = package.mesh()
        if mesh_path is None:
            return BuildOutcome(
                status="BUILD_FAILED",
                revision=revision,
                package=package,
                blockers=["the build produced no exported mesh"],
                stages=stages,
                duration_seconds=time.monotonic() - started,
            )

        # -- analyse ------------------------------------------------------
        analysis_result = worker.analyse(mesh_path)
        stages["analyse"] = _stage(analysis_result)
        if not analysis_result.ok:
            return BuildOutcome(
                status="ANALYSIS_FAILED",
                revision=revision,
                package=package,
                blockers=[analysis_result.error or "topology analysis failed"],
                stages=stages,
                duration_seconds=time.monotonic() - started,
            )
        package.write_analysis("topology", analysis_result.data)

        # -- validate -----------------------------------------------------
        validation = validate_analysis(analysis_result.data, brief.budget)
        package.write_analysis("validation", validation.to_dict())

        # Y-up, because that is the convention the brief is written in and the
        # one the exported glTF uses. Comparing against Blender's Z-up figures
        # silently checks a height against a depth.
        measured = validation.measured.get("dimensionsYUp") or [0, 0, 0]
        brief_findings = brief.dimension_findings(measured)
        package.write_analysis("dimensions", {
            "convention": "Y-up (Roblox), matching the brief and the exported glTF",
            "requested": list(brief.dimensions),
            "measured": list(measured),
            "measuredBlenderZUp": list(validation.measured.get("dimensions") or []),
            "findings": brief_findings,
        })
        package.write_analysis("materials", {
            "requested": list(brief.materials),
            "measured": analysis_result.data.get("objects", {})
                .get(analysis_result.data.get("primary", ""), {})
                .get("materials", []),
        })

        # -- render -------------------------------------------------------
        blend_files = sorted(package.project_dir.glob("*.blend"))
        if blend_files:
            render_result = worker.render(blend_files[0], package.previews_dir, views=self.views)
            stages["render"] = _stage(render_result)
            if not render_result.ok:
                # Renders are how an agent sees what it made. Without them the
                # asset cannot be reviewed, so this is a blocker rather than a
                # missing nicety.
                return BuildOutcome(
                    status="RENDER_FAILED",
                    revision=revision,
                    package=package,
                    validation=validation,
                    brief_findings=brief_findings,
                    blockers=[render_result.error or "preview rendering failed"],
                    stages=stages,
                    duration_seconds=time.monotonic() - started,
                )
        else:
            stages["render"] = {"ok": False, "error": "no .blend was saved"}

        # -- critique -----------------------------------------------------
        #
        # Topology approval only says Roblox will accept the mesh. A watertight,
        # under-budget, correctly-unwrapped cube passes every check above and is
        # still a cube, so the renders get read back before anything is called
        # approved.
        critique_result = None
        try:
            critique_result = critique_package(package)
            stages["critique"] = critique_result.to_dict()
        except CriticError as exc:
            # Fail closed. An asset nobody could look at is not an approved one.
            stages["critique"] = {"ok": False, "error": str(exc)}
            return BuildOutcome(
                status="CRITIQUE_FAILED",
                revision=revision,
                package=package,
                validation=validation,
                brief_findings=brief_findings,
                blockers=[f"the renders could not be read: {exc}"],
                stages=stages,
                duration_seconds=time.monotonic() - started,
            )

        # -- verdict ------------------------------------------------------
        blockers = [item.message for item in validation.blocking]
        blockers.extend(brief_findings)
        if blockers:
            status = "BLOCKED"
        elif critique_result.approved:
            status = "APPROVED_FOR_IMPORT"
        else:
            # Sound geometry, weak composition. A distinct status because the
            # answer is different: this one goes back to the modeller with
            # revisions rather than to a human with an error.
            status = "REVISE"

        package.write_manifest({
            "briefId": brief.id,
            "briefSha256": brief.sha256,
            "revision": revision,
            "programId": program.id,
            "status": status,
            "approved": status == "APPROVED_FOR_IMPORT",
            "visual": {
                "verdict": critique_result.verdict,
                "overall": round(critique_result.overall, 2),
                "scores": {k: round(v, 2) for k, v in critique_result.scores.items()},
            } if critique_result else None,
            "triangles": validation.measured.get("triangles"),
            "backend": "blender",
            "blender": worker.install.to_dict(),
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        })

        return BuildOutcome(
            status=status,
            revision=revision,
            package=package,
            validation=validation,
            brief_findings=brief_findings,
            blockers=blockers,
            critique=critique_result,
            stages=stages,
            duration_seconds=time.monotonic() - started,
        )

    def refine(
        self,
        brief: AssetBrief,
        program_document: dict[str, Any],
        *,
        reviser: Callable[[Critique, dict[str, Any], int], dict[str, Any] | None],
        max_revisions: int = 3,
    ) -> RefinementOutcome:
        """Build, critique, revise, repeat, until approved or out of attempts.

        The engine runs the loop; it does not invent the geometry. `reviser` is
        handed the critique and the program that produced it and returns the
        next program, or None to stop -- because deciding that a narrower base
        means scaling this box rather than that one is modelling, and a pipeline
        that guessed at it would be authoring blind.
        """

        attempts: list[BuildOutcome] = []
        seen: set[str] = set()
        document = program_document
        stopped = "exhausted"

        for revision in range(1, max_revisions + 1):
            fingerprint = _fingerprint(document)
            if fingerprint in seen:
                # The reviser handed back a program already built. Without this
                # the loop burns its whole budget re-rendering one asset and
                # reports the same score three times as though it had tried.
                stopped = "unchanged"
                break
            seen.add(fingerprint)

            outcome = self.build(brief, document, revision=revision)
            attempts.append(outcome)
            if outcome.approved:
                stopped = "approved"
                break
            if outcome.critique is None:
                # BLOCKED, BUILD_FAILED, PROGRAM_INVALID: nothing was scored, so
                # there is nothing for a visual reviser to act on.
                stopped = outcome.status
                break
            if revision == max_revisions:
                break

            document = reviser(outcome.critique, document, revision)
            if document is None:
                stopped = "reviser-stopped"
                break

        return RefinementOutcome(attempts=attempts, stopped_because=stopped)

    def compare(self, first: AssetPackage, second: AssetPackage) -> dict[str, Any]:
        """What changed between two revisions.

        Content hashes rather than timestamps, so "the revision changed nothing"
        is answerable without opening Blender -- which is the failure mode when
        an agent revises a program and the change had no effect.
        """

        left, right = first.manifest(), second.manifest()
        left_files, right_files = left.get("files", {}), right.get("files", {})

        changed = sorted(
            name for name in set(left_files) & set(right_files)
            if left_files[name]["sha256"] != right_files[name]["sha256"]
        )
        return {
            "identical": left.get("contentHash") == right.get("contentHash"),
            "added": sorted(set(right_files) - set(left_files)),
            "removed": sorted(set(left_files) - set(right_files)),
            "changed": changed,
            "triangles": {"before": left.get("triangles"), "after": right.get("triangles")},
            "status": {"before": left.get("status"), "after": right.get("status")},
            "briefUnchanged": left.get("briefSha256") == right.get("briefSha256"),
        }


def _stage(result: JobResult) -> dict[str, Any]:
    record = result.to_dict()
    if not result.ok:
        # Blender's stderr is the only evidence of why a script died, and it is
        # useless three days later if it was not kept.
        record["stderrTail"] = "\n".join((result.stderr or "").splitlines()[-20:])
    return record
