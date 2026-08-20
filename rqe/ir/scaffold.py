"""`new-game` -- the project, laid out, from the model.

The complaint this answers is small and exact: *"nada de agente começar
procurando onde colocar arquivo."* An agent that has to decide where the intent
file goes will decide differently next time, and then two games have two
layouts and every tool that walks a project has to handle both.

So the layout is not a convention an agent is expected to know. It is produced,
from the model, in one call -- and every file in it is *derived*: the intent, the
blueprint, the quality profile and the economy all come from the same
`GameModel`, so none of them can disagree with another.

Nothing here is a placeholder. A scaffolded project compiles to a production
plan immediately, because the scaffolder refuses to write anything for a model
that would not compile. A tree of empty files that looks like a project and
fails at the first real command is worse than no tree at all: it moves the
failure to whoever comes next.
"""

from __future__ import annotations

import json
import hashlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .model import GameModel, GameModelError


#: The layout, as data. The document lists it; holding it here means the list
#: and the thing that creates it cannot drift apart.
DIRECTORIES = (
    "definition",     # intent, references, quality -- what the game *is*
    "contracts/visual",  # executable release and visual-quality contracts
    "quality",        # per-product measurement policy and producer registry
    "schemas",        # frozen engine-owned schemas; product truth forbids escapes
    "assets",         # fail-closed until production assets are approved
    "tokens",         # project-local token copy used by builder and validator
    "src/world",      # per-subsystem source roots, matching blueprint ownership
    "src/gameplay",
    "src/interface",
    "src/telemetry",
    "src/shared",
    "catalogs",       # generated content: items, enemies, quests
    "economy",        # solved curves
    "scenarios",      # what gets played and measured
    "analytics",      # what comes back
)


class ScaffoldError(RuntimeError):
    """The project could not be created, and says what stopped it."""


@dataclass
class Scaffold:
    root: Path
    game_id: str
    created: list[str] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "gameId": self.game_id,
            "root": str(self.root).replace("\\", "/"),
            "created": sorted(self.created),
            # Named rather than silently overwritten: a scaffold that clobbered
            # an existing definition would destroy the game it was asked to
            # start.
            "skipped": sorted(self.skipped),
            "note": (
                "every file is derived from the model, so none of them can disagree "
                "with another; existing files are left alone and listed"
            ),
        }

    def summary(self) -> str:
        lines = [f"games/{self.game_id}: {len(self.created)} files"]
        for path in sorted(self.created):
            lines.append(f"  +  {path}")
        for path in sorted(self.skipped):
            lines.append(f"  =  {path} (exists, left alone)")
        return "\n".join(lines)


def _write(scaffold: Scaffold, relative: str, payload: Any, *, force: bool) -> None:
    path = scaffold.root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not force:
        scaffold.skipped.append(relative)
        return
    text = (
        payload if isinstance(payload, str)
        else json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    )
    path.write_text(text, encoding="utf-8")
    scaffold.created.append(relative)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _engine_schema_sources(root: Path) -> list[Path]:
    schemas = sorted((root / "schemas").glob("*.json"))
    if not schemas:
        raise ScaffoldError(
            f"{root / 'schemas'} has no engine schemas; a release project cannot own "
            "or verify its contracts"
        )
    return schemas


def _probe_registry_source(root: Path) -> dict[str, Any]:
    path = root / "quality" / "probe-registry.v1.json"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ScaffoldError(
            f"{path} is missing; a measurement plan without a producer registry "
            "cannot distinguish executable evidence from an orphan probe"
        ) from exc
    except json.JSONDecodeError as exc:
        raise ScaffoldError(f"{path} is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ScaffoldError(f"{path} must contain a JSON object")
    payload["$schema"] = "../schemas/probe-registry.v1.schema.json"
    return payload


def scaffold_project(
    model: GameModel,
    *,
    root: Path,
    force: bool = False,
    economy: dict[str, Any] | None = None,
) -> Scaffold:
    """Create `games/<id>/` from a model, with every file derived."""

    from .compiler import to_blueprint
    from .operational import (
        game_contract,
        initial_runtime_scenario,
        pending_asset_manifest,
        pending_product_intent,
        project_configuration,
        quality_focus,
        reference_benchmark_placeholder,
        reference_bundle,
        release_quality_profile,
        rojo_project,
        visual_calibration_placeholder,
        visual_quality_spec,
    )

    if not model.coherent:
        # Refused before anything is written. A project tree for a game the
        # model already says will not work is a tree somebody has to discover
        # is wrong.
        raise ScaffoldError(
            f"{model.id} is not coherent, so there is nothing worth scaffolding:\n  - "
            + "\n  - ".join(model.problems())
        )
    if not 1 <= model.concurrent_players <= 100:
        raise ScaffoldError(
            f"{model.id} declares {model.concurrent_players} concurrent players; the "
            "industrial game-contract schema accepts 1..100 and silently clamping it "
            "would make the release contract describe a different product"
        )

    root = root.resolve()
    project_root = (root / "games" / model.id).resolve()
    try:
        project_root.relative_to(root.resolve())
    except ValueError as exc:
        raise ScaffoldError("the project must live inside the repository") from exc

    # Read the engine inputs before creating anything.  Missing schemas or the
    # producer registry are platform defects, not product blockers, and should
    # not leave behind a directory that looks scaffolded.
    schema_sources = _engine_schema_sources(root)
    registry = _probe_registry_source(root)

    source_token = None
    token_problem: str | None = None
    if model.token_set:
        from ..tokens import TokenError, load_token_set

        try:
            source_token = load_token_set(root, model.token_set)
        except (TokenError, OSError, json.JSONDecodeError) as exc:
            # A token is a product input, so its absence blocks this product but
            # not unrelated scaffold outputs.  The release profile names it and
            # the measurement plan records NOT_DECLARED.
            token_problem = str(exc)

    scaffold = Scaffold(root=project_root, game_id=model.id)
    for directory in DIRECTORIES:
        (project_root / directory).mkdir(parents=True, exist_ok=True)

    schema_paths: list[str] = []
    for source in schema_sources:
        relative = f"schemas/{source.name}"
        _write(scaffold, relative, source.read_text(encoding="utf-8"), force=force)
        schema_paths.append(relative)

    _write(scaffold, "quality/probe-registry.v1.json", registry, force=force)

    token_path: str | None = None
    local_token = None
    if source_token is not None:
        token_path = "tokens/release-tokens.json"
        token_payload = json.loads(json.dumps(source_token.data))
        token_payload["$schema"] = "../schemas/design-tokens.v1.schema.json"
        _write(scaffold, token_path, token_payload, force=force)
        from ..tokens import TokenError, load_token_set

        try:
            local_token = load_token_set(project_root, token_path)
        except TokenError as exc:
            # Existing files are preserved by default.  If a preserved local
            # token is stale or invalid, do not replace it and do not let the
            # config claim that it is release-consumable.
            token_problem = str(exc)
            token_path = None

    _write(scaffold, "game.json", model.to_dict(), force=force)
    _write(scaffold, "definition/reference-bundle.json", reference_bundle(model), force=force)
    quality_profile = release_quality_profile(model, token_path=token_path)
    if token_problem:
        quality_profile["tokenProblem"] = token_problem
    _write(scaffold, "definition/release-quality.json", quality_profile, force=force)

    _write(scaffold, "scenarios/initial-runtime.json",
           initial_runtime_scenario(model), force=force)
    _write(scaffold, "contracts/visual/visual-quality.json",
           visual_quality_spec(model, local_token), force=force)
    _write(scaffold, "contracts/game-contract.json", game_contract(model), force=force)
    _write(scaffold, "quality/quality-focus.json", quality_focus(model), force=force)
    _write(scaffold, "assets/asset-manifest.json",
           pending_asset_manifest(model), force=force)
    _write(scaffold, "default.project.json", rojo_project(model), force=force)

    _write(scaffold, "definition/reference-benchmark.json",
           reference_benchmark_placeholder(model), force=force)
    benchmark_path = project_root / "definition/reference-benchmark.json"
    _write(scaffold, "definition/visual-calibration.json",
           visual_calibration_placeholder(
               model, benchmark_sha256=_sha256(benchmark_path)), force=force)

    # Intent last among its dependencies.  Its hashes bind the exact files the
    # release runner will load, including preserved files when force=False.
    bindings = {
        "contract": {
            "path": "contracts/game-contract.json",
            "artifactId": f"{model.id}.release",
            "sha256": _sha256(project_root / "contracts/game-contract.json"),
        },
        "visualQualitySpec": {
            "path": "contracts/visual/visual-quality.json",
            "artifactId": f"{model.id}.visual",
            "sha256": _sha256(project_root / "contracts/visual/visual-quality.json"),
        },
        "referenceBenchmark": {
            "path": "definition/reference-benchmark.json",
            "artifactId": f"{model.id}.reference-benchmark",
            "sha256": _sha256(benchmark_path),
        },
        "visualCalibration": {
            "path": "definition/visual-calibration.json",
            "artifactId": f"{model.id}.visual-calibration",
            "sha256": _sha256(project_root / "definition/visual-calibration.json"),
        },
    }
    _write(scaffold, "definition/product-intent.json",
           pending_product_intent(model, bindings=bindings), force=force)

    _write(scaffold, "rqe.project.json", project_configuration(
        model, token_path=token_path, schema_paths=schema_paths), force=force)

    if economy is not None:
        _write(scaffold, "economy/ladder.json", economy, force=force)

    # The blueprint last: it is the file that has to compile, and writing it
    # only after the definitions exist means its artefact hashes cover real
    # files rather than absent ones.
    _write(scaffold, "blueprint.json",
           to_blueprint([model], root=root, blueprint_id=model.id), force=force)

    _write(scaffold, "README.md", _readme(model), force=force)
    return scaffold


def _readme(model: GameModel) -> str:
    loop = " -> ".join(model.core_loop)
    systems = ", ".join(model.systems) or "none declared"
    currencies = ", ".join(c.id for c in model.currencies) or "none"
    return f"""# {model.id}

{model.pitch}

**{model.genre}** / {model.theme}

    loop:        {loop}
    topology:    {model.topology}
    progression: {model.progression.kind}, {model.progression.tiers} tiers
    currencies:  {currencies}
    systems:     {systems}

Everything in this directory is derived from `game.json`. Change the game there
and recompile; editing `definition/` or `blueprint.json` by hand creates a
second description that can disagree with the first, which is the failure the
game model exists to prevent.

    rqe game validate  games/{model.id}/game.json
    rqe game compile   games/{model.id}/game.json
    python rqe.py release games/{model.id} --static-only

The release command is expected to remain blocked until a human-approved
ProductIntent, an independent reference benchmark, its complete calibration,
approved production assets and product-specific E2E scenarios replace the
typed placeholders. A scaffold is an operational release project, not release
evidence.
"""


def load_project_model(root: Path, game_id: str) -> GameModel:
    """Read back the model a project was scaffolded from."""

    from .model import load_model

    path = root / "games" / game_id / "game.json"
    if not path.is_file():
        raise ScaffoldError(
            f"no game model at {path}; a project without one cannot be recompiled, only "
            "edited by hand"
        )
    try:
        return load_model(json.loads(path.read_text(encoding="utf-8")))
    except (json.JSONDecodeError, GameModelError) as exc:
        raise ScaffoldError(f"{path}: {exc}") from exc
