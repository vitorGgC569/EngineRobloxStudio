"""Versioned Studio Bridge command registry and wire-value validation.

The Luau dispatcher is the executable surface; ``schemas/bridge-commands.v1.json``
is the control-plane contract for that surface.  Loading the default registry in
a source checkout compares both inventories so adding a dispatcher entry without
its effect, contexts and schemas fails before the hub accepts work.

The validator intentionally implements the small JSON Schema subset used by the
manifest.  RQE has no third-party runtime dependencies, and accepting an
unvalidated command because an optional package is missing would be a worse
failure mode than keeping this subset explicit.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


MANIFEST_RELATIVE_PATH = Path("schemas/bridge-commands.v1.json")
DISPATCHER_RELATIVE_PATH = Path("apps/studio-plugin/src/Dispatcher.lua")

EFFECTS = {"read", "transient", "mutation", "context-transition", "arbitrary"}
CONTEXTS = {"edit", "run", "server", "client"}
IDEMPOTENCY = {"safe-retry", "naturally-idempotent", "at-most-once"}
AVAILABILITY = {"supported", "unsupported"}
SELECTOR_SESSION = {"optional", "required"}
SELECTOR_BUILD = {"none", "optional", "required"}
SELECTOR_PLAYER = {"none", "optional", "required"}

_DISPATCHER_ENTRY = re.compile(
    r'^\s*\["(?P<method>[^"]+)"\]\s*=\s*[A-Za-z][A-Za-z0-9_]*Commands\.',
    re.MULTILINE,
)


class CommandRegistryError(ValueError):
    """The manifest or Dispatcher inventory is internally inconsistent."""


class CommandValidationError(ValueError):
    """A command's params or result do not satisfy its versioned schema."""

    def __init__(self, method: str, phase: str, issues: Iterable[str]) -> None:
        self.method = method
        self.phase = phase
        self.issues = list(issues)
        super().__init__(f"{method} {phase} failed schema validation: {'; '.join(self.issues)}")


@dataclass(frozen=True)
class CommandSpec:
    method: str
    method_version: int
    effect: str
    contexts: frozenset[str]
    idempotency: str
    availability: str
    selector: dict[str, str]
    params_schema: dict[str, Any]
    result_schema: dict[str, Any]
    _manifest: dict[str, Any]

    @property
    def mutates(self) -> bool:
        return self.effect != "read"

    @property
    def lease_targeted(self) -> bool:
        return self.selector["build"] == "required"

    def validate_params(self, value: Any) -> None:
        issues = _schema_issues(value, self.params_schema, self._manifest, "params")
        if issues:
            raise CommandValidationError(self.method, "params", issues)

    def validate_result(self, value: Any) -> None:
        issues = _schema_issues(value, self.result_schema, self._manifest, "result")
        if issues:
            raise CommandValidationError(self.method, "result", issues)


class CommandRegistry:
    """Validated lookup table for all public bridge commands."""

    def __init__(self, manifest: dict[str, Any], source: Path | None = None) -> None:
        self.manifest = manifest
        self.source = source
        self.protocol = str(manifest.get("protocol") or "")
        self.schema_version = manifest.get("schemaVersion")
        self._specs = self._parse(manifest)

    @classmethod
    def from_file(cls, path: Path) -> "CommandRegistry":
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise CommandRegistryError(f"could not load command manifest {path}: {exc}") from exc
        if not isinstance(payload, dict):
            raise CommandRegistryError("command manifest must be a JSON object")
        return cls(payload, source=path)

    @staticmethod
    def _parse(manifest: dict[str, Any]) -> dict[str, CommandSpec]:
        issues: list[str] = []
        if manifest.get("schemaVersion") != 1:
            issues.append("schemaVersion must be 1")
        if not isinstance(manifest.get("protocol"), str) or not manifest.get("protocol"):
            issues.append("protocol must be a non-empty string")
        commands = manifest.get("commands")
        if not isinstance(commands, dict) or not commands:
            issues.append("commands must be a non-empty object")
            commands = {}

        specs: dict[str, CommandSpec] = {}
        for method, raw in commands.items():
            prefix = f"commands.{method}"
            if not isinstance(method, str) or not re.fullmatch(r"[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*", method):
                issues.append(f"{prefix}: invalid method name")
                continue
            if not isinstance(raw, dict):
                issues.append(f"{prefix}: spec must be an object")
                continue
            version = raw.get("methodVersion")
            effect = raw.get("effect")
            contexts = raw.get("contexts")
            idempotency = raw.get("idempotency")
            availability = raw.get("availability")
            selector = raw.get("selector")
            params_schema = raw.get("params")
            result_schema = raw.get("result")

            if not isinstance(version, int) or isinstance(version, bool) or version < 1:
                issues.append(f"{prefix}.methodVersion must be a positive integer")
            if effect not in EFFECTS:
                issues.append(f"{prefix}.effect must be one of {sorted(EFFECTS)}")
            if not isinstance(contexts, list) or not contexts or any(item not in CONTEXTS for item in contexts):
                issues.append(f"{prefix}.contexts must be a non-empty subset of {sorted(CONTEXTS)}")
            if idempotency not in IDEMPOTENCY:
                issues.append(f"{prefix}.idempotency must be one of {sorted(IDEMPOTENCY)}")
            if availability not in AVAILABILITY:
                issues.append(f"{prefix}.availability must be one of {sorted(AVAILABILITY)}")
            if not isinstance(selector, dict):
                issues.append(f"{prefix}.selector must be an object")
            else:
                expected_selector_keys = {"session", "build", "player"}
                if set(selector) != expected_selector_keys:
                    issues.append(f"{prefix}.selector must contain exactly {sorted(expected_selector_keys)}")
                if selector.get("session") not in SELECTOR_SESSION:
                    issues.append(f"{prefix}.selector.session must be one of {sorted(SELECTOR_SESSION)}")
                if selector.get("build") not in SELECTOR_BUILD:
                    issues.append(f"{prefix}.selector.build must be one of {sorted(SELECTOR_BUILD)}")
                if selector.get("player") not in SELECTOR_PLAYER:
                    issues.append(f"{prefix}.selector.player must be one of {sorted(SELECTOR_PLAYER)}")
            if not isinstance(params_schema, dict):
                issues.append(f"{prefix}.params must be a JSON Schema object")
            if not isinstance(result_schema, dict):
                issues.append(f"{prefix}.result must be a JSON Schema object")

            if all(
                (
                    isinstance(version, int) and not isinstance(version, bool) and version >= 1,
                    effect in EFFECTS,
                    isinstance(contexts, list) and bool(contexts) and all(item in CONTEXTS for item in contexts),
                    idempotency in IDEMPOTENCY,
                    availability in AVAILABILITY,
                    isinstance(selector, dict) and set(selector) == {"session", "build", "player"},
                    isinstance(params_schema, dict),
                    isinstance(result_schema, dict),
                )
            ):
                specs[method] = CommandSpec(
                    method=method,
                    method_version=version,
                    effect=effect,
                    contexts=frozenset(contexts),
                    idempotency=idempotency,
                    availability=availability,
                    selector=dict(selector),
                    params_schema=params_schema,
                    result_schema=result_schema,
                    _manifest=manifest,
                )

        if issues:
            raise CommandRegistryError("invalid command manifest:\n- " + "\n- ".join(issues))
        return specs

    def __len__(self) -> int:
        return len(self._specs)

    def methods(self) -> tuple[str, ...]:
        return tuple(sorted(self._specs))

    def require(self, method: str) -> CommandSpec:
        try:
            return self._specs[method]
        except KeyError as exc:
            raise CommandRegistryError(f"unknown bridge command {method!r}") from exc

    def assert_dispatcher_inventory(self, dispatcher_path: Path) -> None:
        dispatcher = dispatcher_methods(dispatcher_path)
        manifest = set(self._specs)
        missing = sorted(dispatcher - manifest)
        extra = sorted(manifest - dispatcher)
        if missing or extra:
            details: list[str] = []
            if missing:
                details.append(f"missing manifest entries: {', '.join(missing)}")
            if extra:
                details.append(f"manifest entries absent from Dispatcher: {', '.join(extra)}")
            raise CommandRegistryError("Dispatcher/manifest inventory mismatch: " + "; ".join(details))


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def dispatcher_methods(path: Path) -> set[str]:
    try:
        source = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CommandRegistryError(f"could not read Dispatcher inventory {path}: {exc}") from exc
    methods = {match.group("method") for match in _DISPATCHER_ENTRY.finditer(source)}
    if not methods:
        raise CommandRegistryError(f"no public command entries found in {path}")
    return methods


def load_default_registry(*, verify_dispatcher: bool = True) -> CommandRegistry:
    root = repository_root()
    registry = CommandRegistry.from_file(root / MANIFEST_RELATIVE_PATH)
    dispatcher = root / DISPATCHER_RELATIVE_PATH
    if verify_dispatcher:
        registry.assert_dispatcher_inventory(dispatcher)
    return registry


def _resolve_ref(schema: dict[str, Any], root: dict[str, Any]) -> dict[str, Any]:
    reference = schema.get("$ref")
    if reference is None:
        return schema
    if not isinstance(reference, str) or not reference.startswith("#/"):
        raise CommandRegistryError(f"only local JSON Schema refs are supported, got {reference!r}")
    current: Any = root
    for token in reference[2:].split("/"):
        key = token.replace("~1", "/").replace("~0", "~")
        if not isinstance(current, dict) or key not in current:
            raise CommandRegistryError(f"unresolved JSON Schema ref {reference!r}")
        current = current[key]
    if not isinstance(current, dict):
        raise CommandRegistryError(f"JSON Schema ref {reference!r} did not resolve to an object")
    return current


def _matches_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "null":
        return value is None
    raise CommandRegistryError(f"unsupported JSON Schema type {expected!r}")


def _schema_issues(value: Any, schema: dict[str, Any], root: dict[str, Any], path: str) -> list[str]:
    schema = _resolve_ref(schema, root)
    issues: list[str] = []
    expected = schema.get("type")
    if expected is not None:
        allowed = expected if isinstance(expected, list) else [expected]
        if not allowed or any(not isinstance(item, str) for item in allowed):
            raise CommandRegistryError(f"{path}: schema type must be a string or non-empty string array")
        if not any(_matches_type(value, item) for item in allowed):
            issues.append(f"{path} must be {allowed}, got {type(value).__name__}")
            return issues

    if "enum" in schema and value not in schema["enum"]:
        issues.append(f"{path} must be one of {schema['enum']!r}")

    all_of = schema.get("allOf")
    if all_of is not None:
        if not isinstance(all_of, list) or not all_of or any(not isinstance(item, dict) for item in all_of):
            raise CommandRegistryError(f"{path}: allOf must be a non-empty schema array")
        for child in all_of:
            issues.extend(_schema_issues(value, child, root, path))

    any_of = schema.get("anyOf")
    if any_of is not None:
        if not isinstance(any_of, list) or not any_of or any(not isinstance(item, dict) for item in any_of):
            raise CommandRegistryError(f"{path}: anyOf must be a non-empty schema array")
        alternatives = [_schema_issues(value, child, root, path) for child in any_of]
        if all(alternative for alternative in alternatives):
            issues.append(
                f"{path} must match at least one alternative "
                f"({'; '.join(' / '.join(item) for item in alternatives)})"
            )

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                issues.append(f"{path}.{key} is required")
        properties = schema.get("properties", {})
        if properties and not isinstance(properties, dict):
            raise CommandRegistryError(f"{path}: properties must be an object")
        for key, item in value.items():
            child = properties.get(key) if isinstance(properties, dict) else None
            if isinstance(child, dict):
                issues.extend(_schema_issues(item, child, root, f"{path}.{key}"))
            elif schema.get("additionalProperties") is False:
                issues.append(f"{path}.{key} is not allowed")
            elif isinstance(schema.get("additionalProperties"), dict):
                issues.extend(_schema_issues(item, schema["additionalProperties"], root, f"{path}.{key}"))

    if isinstance(value, list):
        minimum_items = schema.get("minItems")
        maximum_items = schema.get("maxItems")
        if isinstance(minimum_items, int) and len(value) < minimum_items:
            issues.append(f"{path} needs at least {minimum_items} item(s)")
        if isinstance(maximum_items, int) and len(value) > maximum_items:
            issues.append(f"{path} allows at most {maximum_items} item(s)")
        items = schema.get("items")
        if isinstance(items, dict):
            for index, item in enumerate(value):
                issues.extend(_schema_issues(item, items, root, f"{path}[{index}]"))

    if isinstance(value, str):
        minimum_length = schema.get("minLength")
        if isinstance(minimum_length, int) and len(value) < minimum_length:
            issues.append(f"{path} needs at least {minimum_length} character(s)")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        minimum = schema.get("minimum")
        maximum = schema.get("maximum")
        if isinstance(minimum, (int, float)) and value < minimum:
            issues.append(f"{path} must be >= {minimum}")
        if isinstance(maximum, (int, float)) and value > maximum:
            issues.append(f"{path} must be <= {maximum}")

    return issues
