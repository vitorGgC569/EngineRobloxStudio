"""The producer: one brief in, a whole production package out.

Ten layers exist and each answers to a different call. Driving them by hand
means knowing that the economy needs the model, that the asset plan needs the
world, that the world needs the zones the design inferred -- and getting the
order wrong produces a plan for a game the design already said would not work.

So the ordering lives here, as a dependency graph, and the engine walks it.

**A failed stage stops what depends on it, not everything.** The document lists
nine agents; the reason to coordinate them centrally is that most of their work
is independent. If the world cannot be expanded, the economy still solves and
the systems still compose -- and a run that abandoned everything on the first
refusal would waste nine-tenths of the work it had already done.

**Nothing here is an LLM.** Each stage is one deterministic call into a layer
that already exists and already tests itself. Calling them "agents" would
suggest judgement being applied where none is, and the sequencing *is* the
contribution -- the layers were already the intelligence.

**It produces a built package, not a release claim.** Blender and Rojo may run
here, but Studio is still the final truth. What comes back is every decision,
source and binary receipt in order, with what refused and why; an unplayed place
finishes as statically clean at best, never as a release candidate.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


class ProducerError(RuntimeError):
    """The run could not start. Stage failures are reported, not raised."""


#: A stage's verdict.
OK = "OK"
FAILED = "FAILED"
SKIPPED = "SKIPPED"
#: The stage ran and had nothing to do. A tycoon on grid plots has no zoned
#: world; a wave ladder has no purchased curve. Reporting those as failures
#: makes a correct design look broken, and -- worse -- stops everything
#: downstream that would have been fine.
NOT_APPLICABLE = "NOT_APPLICABLE"


class NothingToDo(Exception):
    """Raised by a stage with no work, carrying why."""



@dataclass
class StageResult:
    stage: str
    status: str
    detail: dict[str, Any] = field(default_factory=dict)
    error: str = ""
    #: Which upstream failure caused this to be skipped. Naming it is the
    #: difference between "this stage is broken" and "this stage never ran".
    blocked_by: str = ""
    seconds: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "stage": self.stage,
            "status": self.status,
            "seconds": round(self.seconds, 3),
        }
        if self.detail:
            payload["detail"] = self.detail
        if self.error:
            payload["error"] = self.error
        if self.blocked_by:
            payload["blockedBy"] = self.blocked_by
        return payload


@dataclass(frozen=True)
class Stage:
    """One step, and what it needs to have succeeded first."""

    id: str
    after: tuple[str, ...]
    run: Callable[[dict[str, Any]], dict[str, Any]]
    summary: str = ""
    #: Work whose result this stage consumes when available, but whose refusal
    #: must not suppress a useful degraded artifact.  Geometry is the canonical
    #: case: a cheap corpus build may emit the Part fallback, while release
    #: still depends on geometry as a hard requirement.
    optional_after: tuple[str, ...] = ()


def _declared_failure(detail: dict[str, Any]) -> str:
    """Return why a stage's result refused success, or an empty string.

    Stage functions report expected operational refusals as data so one failed
    branch does not abort independent work.  That data is still a verdict:
    ``ok=False`` and ``blocked`` must never be promoted to pipeline success just
    because the function returned normally.
    """

    if "blocked" in detail:
        reason = detail.get("blocked")
        return str(reason) if reason else "stage reported blocked without a reason"
    if detail.get("ok") is False:
        reason = detail.get("error")
        return str(reason) if reason else "stage reported ok=false"
    return ""


@dataclass
class ProductionRun:
    """Everything the producer did, in order."""

    game_id: str
    brief: str
    results: list[StageResult] = field(default_factory=list)
    context: dict[str, Any] = field(default_factory=dict)
    scaffold_requested: bool = False
    planned_stages: tuple[str, ...] = ()

    def result(self, stage: str) -> StageResult | None:
        return next((item for item in self.results if item.stage == stage), None)

    @property
    def ok(self) -> bool:
        return all(item.status in (OK, NOT_APPLICABLE) for item in self.results)

    @property
    def completed(self) -> list[str]:
        return [item.stage for item in self.results if item.status == OK]

    @property
    def not_applicable(self) -> list[str]:
        return [item.stage for item in self.results if item.status == NOT_APPLICABLE]

    @property
    def failed(self) -> list[str]:
        return [item.stage for item in self.results if item.status == FAILED]

    @property
    def skipped(self) -> list[str]:
        return [item.stage for item in self.results if item.status == SKIPPED]

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "gameId": self.game_id,
            "brief": self.brief,
            "ok": self.ok,
            "completed": self.completed,
            "failed": self.failed,
            "skipped": self.skipped,
            "notApplicable": self.not_applicable,
            "scaffoldRequested": self.scaffold_requested,
            "plannedStages": list(self.planned_stages),
            "stages": [item.to_dict() for item in self.results],
            "seconds": round(sum(item.seconds for item in self.results), 3),
            "note": (
                "a built production package, not a release-ready game: Studio runtime "
                "evidence is still required. What is here is every decision, source "
                "and binary receipt in order, with what refused and why"
            ),
        }

    def summary(self) -> str:
        lines = [
            f"{'OK' if self.ok else 'PARTIAL'}  {self.game_id}: "
            f"{len(self.completed)} of {len(self.results)} stages "
            f"({sum(item.seconds for item in self.results):.1f}s)"
        ]
        for item in self.results:
            mark = {OK: "+", FAILED: "!", SKIPPED: "-", NOT_APPLICABLE: "."}[item.status]
            line = f"  {mark} {item.stage}"
            if item.status == FAILED:
                line += f": {item.error[:110]}"
            elif item.status == NOT_APPLICABLE:
                line += f": nothing to do -- {item.error[:90]}"
            elif item.status == SKIPPED:
                line += f": skipped, {item.blocked_by} did not succeed"
            lines.append(line)
        return "\n".join(lines)


def model_id(context: dict[str, Any]) -> str:
    return getattr(context.get("model"), "id", "game")


def _dimensions_for(role: str, context: dict[str, Any]) -> tuple[float, float, float]:
    """Size a planned asset from its role, at the scale the world is built to."""

    if role == "hero":
        return (24.0, 40.0, 24.0)
    if role == "machine":
        return (10.0, 12.0, 8.0)
    return (4.0, 5.0, 4.0)


def _silhouette_for(role: str) -> str:
    return {
        "hero": "a tapering tower on a wide base, crowned and buttressed",
        "machine": "a low chassis with a raised working drum and vented flank",
    }.get(role, "a compact body with a rim and a foot")


def _source_receipt(root: Path, game_id: str) -> dict[str, Any]:
    """Fingerprint every source tree consumed by the generated Rojo project.

    The general release path has richer project provenance.  Produced games do
    not all have a release project yet, so the producer still needs a local
    invariant: the source evaluated after a repair must be the source Rojo
    packaged.  Keeping the receipt here prevents a repaired source tree from
    being paired with the pre-repair place merely because both files exist.
    """

    from ..provenance import tree_sha256

    paths: tuple[str, ...] = (
        f"games/{game_id}/src",
        f"games/{game_id}/default.project.json",
        "roblox/lib/GameKit",
        "roblox/lib/WorldKit",
        "roblox/lib/Templates",
    )
    digest, files = tree_sha256(root, paths)
    return {
        "sha256": digest,
        "fileCount": len(files),
        "paths": [path for path in paths if (root / path).exists()],
    }


def _stages(root: Path, *, scaffold: bool) -> tuple[Stage, ...]:
    """The production graph.

    Ordered by what each stage genuinely needs, not by what reads well: the
    economy needs only the model, so it does not wait on the world, and a world
    that will not expand does not stop a curve from being solved.
    """

    def design(context: dict[str, Any]) -> dict[str, Any]:
        from ..design import compile_brief

        document = compile_brief(
            context["brief"], id=context["gameId"],
            genre=context.get("genre", ""), theme=context.get("theme", ""),
            token_set=context.get("tokenSet", "tokens/brickfarm.json"),
        )
        context["model"] = document.model
        context["document"] = document
        return {
            "genre": document.model.genre,
            "theme": document.model.theme,
            "loop": list(document.model.core_loop),
            "defaulted": document.defaulted,
            "ambiguities": document.analysis.ambiguities,
        }

    def art(context: dict[str, Any]) -> dict[str, Any]:
        """The game's own palette and light, derived from its brief.

        Everything downstream of here reads `model.token_set`, and until this
        stage existed that string was `tokens/brickfarm.json` in every game the
        factory had ever made -- a farm's greens and a sun deliberately placed
        high enough to erase shadows. Deriving it per game is what makes two
        games look like two games.

        The base set is not discarded: scale, spacing, type, motion, cameras and
        audio come through unchanged, because those are ergonomics. Only colour
        and light are re-decided.
        """

        import json

        from ..art import direct, key_for, value_profile

        model = context["model"]
        base_relative = model.token_set or context.get("tokenSet") or "tokens/brickfarm.json"
        base = json.loads((root / base_relative).read_text(encoding="utf-8"))

        brief = " ".join(part for part in (
            context.get("brief", ""), context.get("genre", ""), context.get("theme", ""),
            model.genre, model.theme, model.pitch) if part)
        document = direct(base, game_id=model.id, brief=brief)

        # Written beside the game rather than into `tokens/`: a derived set is an
        # output of this run, and mixing it with the hand-authored reference sets
        # is how a generated palette ends up cited as a reference.
        relative = f"games/{model.id}/tokens/{document['tokenSetId']}.json"
        destination = root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        # `$schema` is resolved relative to the file that carries it, and this
        # file sits two directories deeper than the base set it came from.
        # Copying the string verbatim pointed the loader at
        # games/<id>/schemas/, which does not exist.
        import os

        document["$schema"] = os.path.relpath(
            root / "schemas" / "design-tokens.v1.schema.json", destination.parent
        ).replace(os.sep, "/")
        destination.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")

        # Load it back through the real loader, so a set that would fail schema
        # or semantic validation fails here rather than inside the Luau that
        # requires it.
        from ..tokens import load_token_set

        load_token_set(root, relative)

        model.token_set = relative
        context["tokenSet"] = relative
        profile = value_profile(document)
        before = value_profile(base)
        return {
            "key": document["tokenSetId"].rsplit("-", 1)[-1],
            "tokenSet": relative,
            "basedOn": base_relative,
            "moods": sorted(document["moods"]),
            "weightedMean": round(profile.weighted_mean, 4),
            "weightedMeanBefore": round(before.weighted_mean, 4),
            "weightedSpread": round(profile.weighted_spread, 4),
            "hueFamilies": profile.hue_families,
        }

    def scaffold_stage(context: dict[str, Any]) -> dict[str, Any]:
        from ..ir.scaffold import scaffold_project

        result = scaffold_project(context["model"], root=root)
        return {"created": result.created, "skipped": result.skipped}

    def systems(context: dict[str, Any]) -> dict[str, Any]:
        from ..systems import compose, verify

        composition = verify(root, compose(context["model"]))
        context["composition"] = composition
        return {
            "order": composition.order,
            "implemented": composition.implemented,
            "planned": composition.planned,
            "verified": composition.verified.get("loaded", 0),
        }

    def economy(context: dict[str, Any]) -> dict[str, Any]:
        from ..economy import Targets, solve

        model = context["model"]
        if model.progression.tiers < 2 or model.progression.first_tier_seconds <= 0:
            # Not every genre has a purchased ladder. Reported as a skip with a
            # reason rather than a failure, because "this game has no cost curve"
            # is an answer.
            raise NothingToDo(
                f"{model.id} progresses by {model.progression.kind} with "
                f"{model.progression.tiers} tiers; there is no purchased curve to solve"
            )
        total = max(model.progression.session_minutes * 6, 30.0)
        design_result = solve(root, Targets(
            tiers=model.progression.tiers,
            first_tier_seconds=model.progression.first_tier_seconds,
            total_minutes=total,
        ))
        context["economy"] = design_result
        return {
            "tierCosts": [round(cost) for cost in design_result.tier_costs],
            "stepRatio": round(design_result.step_ratio, 3),
            "verifiedMinutes": design_result.verified.get("totalMinutes"),
            "problems": design_result.problems,
        }

    def content(context: dict[str, Any]) -> dict[str, Any]:
        from ..content import build, from_model

        report = build(from_model(context["model"]))
        context["content"] = report
        return {
            "entries": report["catalogue"]["count"],
            "consistency": len(report["consistency"]),
            "balance": len(report["balance"]),
            "ok": report["ok"],
        }

    def world(context: dict[str, Any]) -> dict[str, Any]:
        from ..tokens import load_token_set
        from ..world import plan as plan_world
        from ..world.grammar import build_world

        model = context["model"]
        # Only topologies that genuinely need zones. `single_arena` has a
        # structure of its own -- staging, arena, lane, objective, build plots --
        # and refusing it here starved everything downstream: no regions meant
        # the asset director budgeted for nothing, so an arena game reached the
        # place as a floor and a spawn.
        from ..world.grammar import ZONELESS_TOPOLOGIES

        if not model.zones and model.topology not in ZONELESS_TOPOLOGIES:
            raise NothingToDo(
                f"{model.id} uses the {model.topology} topology, which declares no "
                "zones; there is no zoned world to expand"
            )
        tokens = load_token_set(root, model.token_set or "tokens/brickfarm.json").data
        spec = build_world(
            f"{model.id}-world", tokens=tokens,
            zones=[{"id": z.id, "theme": z.theme, "difficulty": z.difficulty}
                   for z in model.zones],
            topology=model.topology,
        )
        context["world"] = spec
        result = plan_world(root, spec, tokens=model.token_set or "tokens/brickfarm.json")
        return {
            "regions": len(spec.regions),
            "routes": len(spec.circulation),
            "walkableArea": round(result.walkable_area),
            "ok": result.ok,
            "problems": result.problems + result.unreachable,
        }

    def assets(context: dict[str, Any]) -> dict[str, Any]:
        from ..assets.director import Budget, plan_for_model

        result = plan_for_model(
            context["model"], world_spec=context.get("world"),
            budget=Budget(triangles=int(context.get("triangleBudget", 200_000))),
            source_offers=context.get("sourceOffers"),
        )
        context["assets"] = result
        payload = {
            "distinct": result.distinct,
            "geometryDistinct": result.geometry_distinct,
            "mediaDistinct": result.media_distinct,
            "placements": result.placements,
            "geometryPlacements": result.geometry_placements,
            "allocated": result.allocated,
            "reuseRatio": round(result.reuse_ratio, 2),
            "sourced": sum(entry.strategy == "DISCOVER" for entry in result.entries),
            "generated": sum(entry.strategy == "CREATE" for entry in result.entries),
            "sources": sorted({
                entry.source for entry in result.entries
                if entry.strategy == "DISCOVER" and entry.source != "internal"
            }),
            # A plan can prove routing, never moderation or integration.
            "productionReady": False,
            "ok": result.ok,
            "blockers": result.blocking_problems(),
            "warnings": result.warnings(),
            "problems": result.problems(),
        }
        context["assetsResult"] = payload
        context["assetPlan"] = result
        return payload

    def interface(context: dict[str, Any]) -> dict[str, Any]:
        from ..tokens import load_token_set
        from ..ui import compose_matrix, screens_for

        model = context["model"]
        tokens = load_token_set(root, model.token_set or "tokens/brickfarm.json").data
        needed = screens_for(model)
        failing = []
        for name in needed:
            if not compose_matrix(name, tokens=tokens)["ok"]:
                failing.append(name)
        result = {"screens": needed, "failing": failing, "ok": not failing}
        context["interfaceResult"] = result
        return result

    def geometry_stage(context: dict[str, Any]) -> dict[str, Any]:
        """Build the meshes the asset plan asked for.

        The link that was missing. The director plans a hero and a machine at
        20,000 triangles each and routes both to Blender; the geometry pipeline
        can build, validate, render and critique them; and nothing connected the
        two. Every game shipped with its 3D assets permanently "still to build",
        and the only sign was a line in the world's own log saying so.

        Skipped honestly rather than faked when Blender is absent: an asset the
        pipeline could not build is reported as such, and the game still says
        how many of its assets are placeholders.
        """

        from ..assets.director import AssetPlan
        from ..geometry.brief import AssetBrief
        from ..geometry.pipeline import GeometryPipeline
        from ..geometry.programs import ProgramError, program_for
        from ..geometry.worker import BlenderUnavailable

        plan = context.get("assetPlan")
        if plan is None:
            result = {"planned": 0, "built": 0, "approved": 0, "skipped": [], "ok": True,
                      "note": "no asset plan to build from"}
            context["geometryResult"] = result
            return result

        wanted = [e for e in plan.entries
                  if e.backend == "blender" and e.strategy == "CREATE"]
        if not wanted:
            result = {"planned": 0, "built": 0, "approved": 0, "skipped": [], "ok": True,
                      "note": "the plan routes no asset to Blender"}
            context["geometryResult"] = result
            return result

        try:
            pipeline = GeometryPipeline(workspace=root / ".tmp" / "geometry" / model_id(context))
            pipeline.worker  # probe now, so a missing Blender is one message not five
        except BlenderUnavailable as exc:
            result = {
                "planned": len(wanted),
                "built": 0,
                "approved": 0,
                "skipped": [e.id for e in wanted],
                "ok": False,
                "blocked": f"Blender is unavailable, so {len(wanted)} planned mesh(es) "
                           f"were not built: {exc}",
            }
            context["geometryResult"] = result
            return result

        results: list[dict[str, Any]] = []
        packages: dict[str, Any] = {}
        for entry in wanted:
            brief = AssetBrief(
                id=entry.id.replace("-", "_"),
                # Sized from the token grammar rather than guessed: a hero that
                # is not landmark-height is a hero nobody sees over a wall.
                dimensions=_dimensions_for(entry.role, context),
                style=getattr(context["model"], "theme", "") or "stylised",
                silhouette=_silhouette_for(entry.role),
                materials=("dark", "light", "accent"),
                triangle_budget=max(entry.triangles, 64),
                gameplay_role=entry.role,
            )
            try:
                document = program_for(brief)
            except ProgramError as exc:
                results.append({"id": entry.id, "status": "NO_PROGRAM", "reason": str(exc)})
                continue

            outcome = pipeline.build(brief, document)
            record = {
                "id": entry.id,
                "status": outcome.status,
                "triangles": (outcome.validation.measured.get("triangles")
                              if outcome.validation else None),
            }
            if outcome.critique is not None:
                record["visual"] = round(outcome.critique.overall, 1)
                record["verdict"] = outcome.critique.verdict
            if outcome.blockers:
                record["blockers"] = outcome.blockers[:2]
            if outcome.package is not None and outcome.status in (
                "APPROVED_FOR_IMPORT", "REVISE"
            ):
                manifest = outcome.package.manifest()
                packages[entry.id] = {
                    "root": str(outcome.package.root),
                    "expectedBriefSha256": brief.sha256,
                    "expectedContentHash": manifest.get("contentHash"),
                }
            results.append(record)

        context["geometryPackages"] = packages
        approved = [r for r in results if r["status"] == "APPROVED_FOR_IMPORT"]
        result = {
            "planned": len(wanted),
            "built": len([r for r in results if r["status"] in
                          ("APPROVED_FOR_IMPORT", "REVISE")]),
            "approved": len(approved),
            "results": results,
            # A mesh that built and scored REVISE is still a mesh. Requiring
            # visual approval here would block every game on the first asset the
            # critic disliked, and the critic is advisory at this stage.
            "ok": bool(results) and all(
                r["status"] in ("APPROVED_FOR_IMPORT", "REVISE") for r in results),
        }
        context["geometryResult"] = result
        return result

    def implement_stage(context: dict[str, Any]) -> dict[str, Any]:
        """The plan becomes Luau. Everything before this stage plans.

        Compiled immediately after being written. A generator that emits source
        nobody parses is a generator that produces plausible-looking files, and
        the first thing to find out is that they do not build -- which is a
        different and much cheaper failure than discovering it in Studio.
        """

        from ..implement import implement as write_game
        from ..implement.assembly import sdk_calls, sdk_enum_arguments
        from ..luau_check import ToolchainUnavailable, check_all
        from ..ui import screens_for

        model = context["model"]
        written = write_game(
            model,
            root=root,
            composition=context.get("composition"),
            economy=context.get("economy"),
            content=context.get("content"),
            world=context.get("world"),
            assets=context.get("assetPlan"),
            geometry_packages=context.get("geometryPackages"),
            screens=screens_for(model),
        )
        files = written.write()
        context["implementation"] = written

        payload = written.to_dict()
        payload["written"] = files

        # Two classes the Luau compiler cannot see, both of which shipped a game
        # that compiled and did nothing: a call to an SDK function nobody wrote,
        # and a literal the SDK refuses at runtime. The second killed an entire
        # HUD on its first line and the only symptom was an empty screenshot.
        invented = sdk_calls(written.files, root / "roblox" / "lib" / "GameKit")
        refused = sdk_enum_arguments(written.files)
        payload["sdkMisuse"] = invented + refused
        try:
            failures = check_all(root, source_roots=[f"games/{model.id}/src"])
            payload["compiles"] = not failures
            payload["syntaxErrors"] = [
                {"path": str(failure.path), "message": failure.message} for failure in failures
            ]
            payload["ok"] = not failures and not payload["sdkMisuse"]
        except ToolchainUnavailable as exc:
            # Reported, never assumed. Source that was not parsed is source
            # nobody has any reason to believe builds.
            payload["compiles"] = None
            payload["ok"] = False
            payload["blocked"] = f"no Luau toolchain, so nothing verified the emitted source: {exc}"
        return payload

    def production_plan(context: dict[str, Any]) -> dict[str, Any]:
        from ..ir.compiler import compile_model

        result = compile_model(context["model"], root=root)
        tasks = result["plan"]["projects"][0]["tasks"]
        return {
            "planId": result["plan"].get("planId"),
            "tasks": len(tasks),
            "stages": sorted({task["stage"] for task in tasks}),
        }

    def build_stage(context: dict[str, Any]) -> dict[str, Any]:
        """Rojo turns the emitted source into a place file.

        The first step whose output a human can open. Everything before it is
        text that claims to be a game; this is where that claim becomes
        checkable, and where a mis-declared Rojo tree stops being invisible.
        """

        import shutil
        import subprocess

        from ..luau_check import ToolchainUnavailable, check_all
        from ..provenance import sha256_file, sha256_json

        model = context["model"]
        # Resolved, because rojo runs with cwd set to the game directory and a
        # relative path would be joined onto it twice.
        game_dir = (root / "games" / model.id).resolve()
        project = game_dir / "default.project.json"
        if not project.is_file():
            return {"ok": False, "blocked": "no Rojo project was emitted"}

        rojo = shutil.which("rojo")
        if rojo is None:
            # Named rather than skipped. A pipeline that reports success without
            # having built anything is the failure this whole stage exists to
            # prevent.
            return {"ok": False, "blocked": "rojo is not on PATH, so nothing was built"}

        output = game_dir / f"{model.id}.rbxlx"
        inputs_before = _source_receipt(root, model.id)
        try:
            syntax_failures = check_all(root, source_roots=[f"games/{model.id}/src"])
        except ToolchainUnavailable as exc:
            return {
                "ok": False,
                "blocked": (
                    "the post-repair source was not compiled, so it cannot be packaged: "
                    f"{exc}"
                ),
                "source": inputs_before,
            }
        if syntax_failures:
            return {
                "ok": False,
                "blocked": "the post-repair source does not compile",
                "source": inputs_before,
                "syntaxErrors": [
                    {"path": str(item.path), "message": item.message}
                    for item in syntax_failures
                ],
            }
        process = subprocess.run(
            [rojo, "build", str(project), "--output", str(output)],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            cwd=str(game_dir), timeout=300,
        )
        if process.returncode != 0 or not output.is_file():
            return {
                "ok": False,
                "error": (process.stderr or process.stdout).strip()[-800:],
                "blocked": "Rojo refused the project",
            }

        inputs_after = _source_receipt(root, model.id)
        if inputs_after["sha256"] != inputs_before["sha256"]:
            return {
                "ok": False,
                "blocked": "release inputs changed while Rojo was building",
                "inputsBefore": inputs_before,
                "inputsAfter": inputs_after,
                "place": str(output.relative_to(root.resolve())),
            }

        # Counted from the artefact, not from what was requested: a tree that
        # maps a path Rojo silently found empty builds fine and ships nothing.
        import re

        text = output.read_text(encoding="utf-8", errors="replace")
        counts = {
            kind: len(re.findall(f'class="{kind}"', text))
            for kind in ("Script", "LocalScript", "ModuleScript")
        }
        problems = []
        if counts["Script"] == 0:
            problems.append("the place contains no server Script; nothing would run")
        if counts["ModuleScript"] < 5:
            problems.append(
                f"only {counts['ModuleScript']} ModuleScripts: the SDK does not look mapped in"
            )
        place_sha256 = sha256_file(output)
        build_id = sha256_json({
            "sourceSha256": inputs_before["sha256"],
            "placeSha256": place_sha256,
            "gameId": model.id,
        })
        result = {
            "ok": not problems,
            "place": str(output.relative_to(root.resolve())),
            "bytes": output.stat().st_size,
            "instances": counts,
            "problems": problems,
            "compiles": True,
            "buildId": build_id,
            "placeSha256": place_sha256,
            "source": inputs_before,
        }
        context["buildResult"] = result
        return result

    def _evaluate_current(context: dict[str, Any], *, final: bool) -> dict[str, Any]:
        """Run the SDK's own validators against what was emitted.

        Not a second opinion: the same `problems` functions the shipped modules
        expose, executed on the emitted catalogues through the headless harness.
        A checker that reimplemented those rules would drift from the code the
        game runs, and then agree with itself while the game misbehaves.

        This is the half that does not need Studio. What it cannot see -- whether
        the place opens, whether the character stands on anything, what a frame
        looks like -- is named rather than assumed, because a report that lists
        only what it checked reads as a clean bill of health.
        """

        from ..evaluate import evaluate_game

        result = evaluate_game(root, context["model"], context)
        context["evaluation"] = result
        source = _source_receipt(root, context["model"].id)
        context["evaluationSource"] = source
        payload = result.to_dict()
        # `Evaluation.ok` is a verdict about the product, not about whether the
        # evaluator ran.  Repairs need the findings even when that verdict is
        # negative, so keep the two meanings separate at the stage boundary.
        payload["evaluationOk"] = payload.pop("ok")
        payload["ok"] = True
        payload["source"] = source
        payload["pass"] = "final" if final else "pre-repair"

        build = context.get("buildResult") if final else None
        if build is not None and source["sha256"] != (build.get("source") or {}).get("sha256"):
            payload["ok"] = False
            payload["blocked"] = (
                "the evaluated source differs from the source packaged by Rojo"
            )
        return payload

    def evaluate_stage(context: dict[str, Any]) -> dict[str, Any]:
        return _evaluate_current(context, final=False)

    def reevaluate_stage(context: dict[str, Any]) -> dict[str, Any]:
        """Evaluate the exact post-repair source packaged into the place."""

        return _evaluate_current(context, final=True)

    def repair_stage(context: dict[str, Any]) -> dict[str, Any]:
        """Apply the findings that are mechanically safe, and refuse the rest.

        A repair loop that edits design decisions is a loop that quietly makes a
        different game. Only findings with a determined fix are applied -- a
        price of zero, a board that ranks the wrong way -- and everything that
        needs a decision is handed back with what it would take.
        """

        from ..evaluate import repair_findings

        evaluation = context.get("evaluation")
        if evaluation is None:
            return {"ok": False, "blocked": "nothing was evaluated, so nothing can be repaired"}
        result = repair_findings(root, context["model"], evaluation, context)
        if result.get("applied"):
            # Re-emit so the place carries the repair rather than the report of
            # it. A fix that lives only in a JSON file is not a fix.
            from ..implement import implement as write_game
            from ..ui import screens_for

            written = write_game(
                context["model"], root=root,
                composition=context.get("composition"), economy=context.get("economy"),
                content=context.get("content"), world=context.get("world"),
                assets=context.get("assetPlan"),
                geometry_packages=context.get("geometryPackages"),
                screens=screens_for(context["model"]),
            )
            written.write()
            context["implementation"] = written
            # Any earlier binary or evidence names the pre-repair source.  It
            # must be impossible for a later stage to reuse either silently.
            context.pop("buildResult", None)
            context.pop("regression", None)
            result["reemitted"] = True
            result["invalidated"] = ["build", "evaluation", "regression"]
        return result

    def regression_stage(context: dict[str, Any]) -> dict[str, Any]:
        """Did this run make anything worse than the last one?

        Compared against the recorded evaluation of the previous run, per
        finding. A build that fixes two things and breaks one reads as progress
        in any count of open findings, and reads correctly here.
        """

        from ..evaluate import compare_to_previous

        result = compare_to_previous(root, context["model"], context.get("evaluation"))
        context["regression"] = result
        return result

    def release_candidate_stage(context: dict[str, Any]) -> dict[str, Any]:
        """The gate. Fail-closed, and explicit about what it did not see.

        A candidate is not "nothing failed". It is: everything that could be
        checked was checked, nothing blocking survived, nothing regressed, and
        the checks that need a running game are listed as outstanding rather
        than counted as passed.
        """

        from ..evaluate import record_evaluation_baseline, release_verdict

        result = release_verdict(
            context.get("evaluation"),
            context.get("regression"),
            build=context.get("buildResult"),
            # Supplied by whoever ran the game. Absent by default, which is what
            # makes an unplayed build fail this gate rather than pass it.
            runtime=context.get("runtimeEvidence"),
            production={
                "assets": context.get("assetsResult"),
                "geometry": context.get("geometryResult"),
            },
        )
        result["ok"] = result.get("status") == "RELEASE_CANDIDATE"
        build = context.get("buildResult") or {}
        if build.get("buildId"):
            result["buildId"] = build["buildId"]
            result["placeSha256"] = build.get("placeSha256")
            result["sourceSha256"] = (build.get("source") or {}).get("sha256")
        if result["ok"]:
            result["regressionBaseline"] = record_evaluation_baseline(
                root,
                context["model"],
                context["evaluation"],
                build=build,
                runtime=context["runtimeEvidence"],
            )
        return result

    graph: list[Stage] = [
        Stage("design", (), design,
              "a brief becomes a coherent, genre-conforming game model"),
    ]
    graph.append(Stage("art", ("design",), art,
                       "the game's own palette and light, derived from its brief"))
    if scaffold:
        graph.append(Stage("scaffold", ("design", "art"), scaffold_stage,
                           "the project on disk, every file derived from the model"))
    graph.extend([
        Stage("systems", ("design",), systems,
              "the SDK modules the game needs, loaded and called"),
        Stage("economy", ("design",), economy,
              "the cost curve, verified against the module the game runs"),
        Stage("content", ("design",), content,
              "a catalogue, checked for consistency and for fairness"),
        Stage("world", ("design", "art"), world,
              "the zones expanded into a validated layout"),
        Stage("interface", ("design", "art"), interface,
              "the screens the systems imply, across the device matrix"),
        # Assets wait on the world because a plan without it cannot see the
        # region kinds, and would budget for an experience icon and nothing else.
        Stage("assets", ("design", "art", "world"), assets,
              "what to build, how many, unique or reused, within one budget"),
        # The link that was missing: the plan said "build these in Blender" and
        # nothing did, so every game shipped with its meshes permanently pending.
        Stage("geometry", ("assets",), geometry_stage,
              "the meshes the asset plan asked for, actually built"),

        Stage("plan", ("design",) + (("scaffold",) if scaffold else ()), production_plan,
              "the production DAG the factory executes"),
        # The stage everything above was for. It waits on every layer that
        # decides a number the game runs on, so nothing is emitted from a
        # default where a decision was supposed to be.
        Stage("implement", ("design", "art", "systems", "economy", "content", "world", "interface", "assets"),
              implement_stage,
              "the plan becomes Luau, consuming authored geometry when available",
              optional_after=("geometry",)),
        Stage("evaluate", ("implement",), evaluate_stage,
              "the SDK's validators produce findings for the repair pass"),
        Stage("repair", ("evaluate",), repair_stage,
              "the mechanically safe findings applied; the rest handed back"),
        Stage("build", ("repair",), build_stage,
              "Rojo packages the post-repair source into a content-addressed place"),
        Stage("reevaluate", ("build",), reevaluate_stage,
              "the post-repair source is evaluated and matched to the built place"),
        Stage("regression", ("reevaluate",), regression_stage,
              "what this run made worse than the last one"),
        Stage("release_candidate", ("geometry", "build", "reevaluate", "regression"), release_candidate_stage,
              "the gate, fail-closed and explicit about what it could not see"),
    ])
    return tuple(graph)


def produce(
    root: Path,
    brief: str,
    *,
    game_id: str,
    genre: str = "",
    theme: str = "",
    token_set: str = "tokens/brickfarm.json",
    triangle_budget: int = 200_000,
    scaffold: bool = False,
    skip_stages: Sequence[str] = (),
    source_offers: Mapping[str, Sequence[str]] | None = None,
) -> ProductionRun:
    """Drive every layer from one brief.

    ``skip_stages`` is an explicit degraded execution profile, used by the
    cheap corpus to omit Blender.  A skipped stage never enters ``succeeded``:
    optional consumers may still produce diagnostic artifacts, while hard
    dependents (especially release) remain blocked.
    """

    if not brief.strip():
        raise ProducerError("a production run needs a brief")

    context: dict[str, Any] = {
        "brief": brief.strip(), "gameId": game_id, "genre": genre, "theme": theme,
        "tokenSet": token_set, "triangleBudget": triangle_budget,
        "sourceOffers": {
            str(asset_id): tuple(str(source) for source in sources)
            for asset_id, sources in (source_offers or {}).items()
        },
        # Explicitly empty is materially different from emitter auto-discovery.
        # A skipped or failed geometry stage must never consume a prior run's
        # persistent .tmp cache.
        "geometryPackages": {},
    }
    graph = _stages(root, scaffold=scaffold)
    run = ProductionRun(
        game_id=game_id,
        brief=brief.strip(),
        context=context,
        scaffold_requested=bool(scaffold),
        planned_stages=tuple(stage.id for stage in graph),
    )
    succeeded: set[str] = set()
    requested_skips = {str(item) for item in skip_stages}
    unknown_skips = requested_skips - {stage.id for stage in graph}
    if unknown_skips:
        raise ProducerError(
            "unknown stage(s) in skip_stages: " + ", ".join(sorted(unknown_skips))
        )

    for stage in graph:
        if stage.id in requested_skips:
            run.results.append(StageResult(
                stage=stage.id,
                status=SKIPPED,
                blocked_by="execution profile",
                error="explicitly omitted by skip_stages",
            ))
            continue
        blocker = next((name for name in stage.after if name not in succeeded), "")
        if blocker:
            run.results.append(StageResult(
                stage=stage.id, status=SKIPPED, blocked_by=blocker))
            continue

        started = time.monotonic()
        try:
            detail = stage.run(context)
        except NothingToDo as exc:
            # Counts as succeeded for dependency purposes: a stage with nothing
            # to do has not blocked anything. Treating it as a failure left a
            # grid-plots tycoon with no asset plan at all, because the director
            # works perfectly well without a world.
            succeeded.add(stage.id)
            run.results.append(StageResult(
                stage=stage.id, status=NOT_APPLICABLE, error=str(exc),
                seconds=time.monotonic() - started,
            ))
            continue
        except Exception as exc:  # noqa: BLE001
            # Caught deliberately and by type name. A stage failing is data --
            # the run reports which one and why, and everything independent of
            # it still runs. Letting it propagate would throw away nine-tenths
            # of the work already done.
            run.results.append(StageResult(
                stage=stage.id, status=FAILED,
                error=f"{type(exc).__name__}: {exc}",
                seconds=time.monotonic() - started,
            ))
            continue

        failure = _declared_failure(detail)
        if failure:
            run.results.append(StageResult(
                stage=stage.id, status=FAILED, detail=detail, error=failure,
                seconds=time.monotonic() - started,
            ))
            continue

        succeeded.add(stage.id)
        run.results.append(StageResult(
            stage=stage.id, status=OK, detail=detail,
            seconds=time.monotonic() - started,
        ))

    return run


def stages() -> list[dict[str, str]]:
    """The production graph, readable before anything runs."""

    return [
        {
            "id": stage.id,
            "after": list(stage.after),
            "optionalAfter": list(stage.optional_after),
            "summary": stage.summary,
        }
        for stage in _stages(Path("."), scaffold=True)
    ]
