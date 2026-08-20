"""Machine-readable inventory of the Roblox production control surface.

This module answers two different questions without conflating them:

* is the capability catalog an exact, non-drifting description of the checked-in
  Studio command manifest and Python adapters? (catalog integrity)
* can a requested production slice be selected without relying on a partial,
  blocked, unsupported or unvalidated capability? (selection readiness)

Neither report is runtime evidence and neither authorizes release.  The highest
claim made here is ``STATICALLY_VALIDATED``: source and versioned manifests were
inspected, but no Studio command was executed.
"""

from __future__ import annotations

import ast
import hashlib
import json
import os
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Mapping

from .hub.commands import CommandRegistry, CommandRegistryError
from .models import VALIDATION_LEVELS, validation_level_at_least
from .schema_validation import SchemaDefinitionError, validate_schema_instance


CATALOG_RELATIVE_PATH = Path("quality/production-capabilities.v1.json")
REPORT_SCHEMA = "rqe://schemas/production-capability-coverage-report.v1.schema.json"
SELECTION_SCHEMA = "rqe://schemas/production-capability-selection-receipt.v1.schema.json"
REPORT_SCHEMA_RELATIVE_PATH = Path("schemas/production-capability-coverage-report.v1.schema.json")
SELECTION_SCHEMA_RELATIVE_PATH = Path("schemas/production-capability-selection-receipt.v1.schema.json")

REQUIRED_PHASES = (
    "project",
    "studio",
    "build",
    "edit",
    "runtime",
    "player",
    "client",
    "capture",
    "assets",
    "publish",
    "multiplayer",
    "persistence",
    "monetization",
    "release",
)
CAPABILITY_STATUSES = {"AVAILABLE", "PARTIAL", "BLOCKED", "GAP", "UNSUPPORTED"}
_CAPABILITY_ID = re.compile(r"^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$")
_PYTHON_SYMBOL = re.compile(
    r"^(?P<module>rqe(?:\.[a-z_][a-z0-9_]*)*):(?P<name>[A-Za-z_][A-Za-z0-9_]*)$"
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


class CapabilityCatalogError(ValueError):
    """The catalog cannot be trusted as an inventory of the source tree."""


class CapabilitySelectionError(ValueError):
    """A requested phase or capability is not defined by the catalog."""


@dataclass(frozen=True)
class BridgeCommandRef:
    method: str
    required: bool


@dataclass(frozen=True)
class PythonAdapterRef:
    symbol: str
    role: str
    required: bool


@dataclass(frozen=True)
class ProductionCapability:
    id: str
    phase: str
    title: str
    description: str
    status: str
    validation_level: str
    bridge_commands: tuple[BridgeCommandRef, ...]
    adapters: tuple[PythonAdapterRef, ...]
    risks: tuple[str, ...]
    limitations: tuple[str, ...]
    gaps: tuple[str, ...]


@dataclass(frozen=True)
class AdapterResolution:
    symbol: str
    resolved: bool
    source: str | None
    line: int | None
    error: str | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "symbol": self.symbol,
            "resolved": self.resolved,
            "source": self.source,
            "line": self.line,
            "error": self.error,
        }


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _inside(
    root: Path,
    value: Any,
    label: str,
    *,
    base: Path | None = None,
) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise CapabilityCatalogError(f"{label} must be a non-empty relative path")
    relative = Path(value)
    if relative.is_absolute():
        raise CapabilityCatalogError(f"{label} must be relative to the repository")
    candidate = ((base or root) / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise CapabilityCatalogError(f"{label} escapes the repository: {value}") from exc
    return candidate


def _read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CapabilityCatalogError(f"cannot read {label} {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise CapabilityCatalogError(f"{label} must be a JSON object")
    return payload


def _strings(value: Any, label: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise CapabilityCatalogError(f"{label} must be an array")
    if any(not isinstance(item, str) or not item.strip() for item in value):
        raise CapabilityCatalogError(f"{label} must contain only non-empty strings")
    if len(value) != len(set(value)):
        raise CapabilityCatalogError(f"{label} contains duplicate values")
    return tuple(value)


def _ratio(numerator: int, denominator: int) -> float:
    return round(numerator / denominator, 6) if denominator else 1.0


def _validate_owned_output(root: Path, payload: dict[str, Any], schema_path: Path) -> None:
    schema = _read_json(root / schema_path, "production capability output schema")
    try:
        issues = validate_schema_instance(payload, schema)
    except SchemaDefinitionError as exc:
        raise CapabilityCatalogError(f"invalid capability output schema: {exc}") from exc
    if issues:
        raise CapabilityCatalogError(
            f"generated capability artifact failed {schema_path.name}:\n- "
            + "\n- ".join(str(item) for item in issues)
        )


def _module_source(root: Path, module: str) -> Path:
    relative = Path(*module.split("."))
    module_file = (root / relative).with_suffix(".py")
    package_file = root / relative / "__init__.py"
    for candidate in (module_file, package_file):
        candidate = candidate.resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            continue
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"module source not found for {module}")


def resolve_python_adapter(root: Path, symbol: str) -> AdapterResolution:
    """Resolve an RQE adapter statically without importing or executing it."""

    match = _PYTHON_SYMBOL.fullmatch(symbol)
    if match is None:
        return AdapterResolution(symbol, False, None, None, "invalid RQE Python symbol")
    module = match.group("module")
    name = match.group("name")
    try:
        source = _module_source(root, module)
        tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
    except (OSError, SyntaxError) as exc:
        return AdapterResolution(symbol, False, None, None, str(exc))
    definitions = {
        node.name: node.lineno
        for node in tree.body
        if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef))
    }
    line = definitions.get(name)
    if line is None:
        return AdapterResolution(
            symbol,
            False,
            source.relative_to(root).as_posix(),
            None,
            f"top-level symbol {name!r} does not exist",
        )
    return AdapterResolution(
        symbol,
        True,
        source.relative_to(root).as_posix(),
        line,
        None,
    )


class ProductionCapabilityCatalog:
    """Validated catalog bound to one exact Studio command manifest."""

    def __init__(
        self,
        *,
        root: Path,
        source: Path,
        payload: dict[str, Any],
        registry: CommandRegistry,
        command_manifest_path: Path,
        command_manifest_hash: str,
        phases: tuple[dict[str, str], ...],
        capabilities: tuple[ProductionCapability, ...],
    ) -> None:
        self.root = root
        self.source = source
        self.payload = payload
        self.registry = registry
        self.command_manifest_path = command_manifest_path
        self.command_manifest_hash = command_manifest_hash
        self.phases = phases
        self.capabilities = capabilities
        self.catalog_id = str(payload["catalogId"])
        self.catalog_hash = _sha256_file(source)
        self._by_id = {item.id: item for item in capabilities}

    @classmethod
    def load(
        cls,
        root: str | Path,
        catalog_path: str | Path = CATALOG_RELATIVE_PATH,
    ) -> "ProductionCapabilityCatalog":
        repository = Path(root).resolve()
        if not repository.is_dir():
            raise CapabilityCatalogError(f"repository root does not exist: {repository}")
        source_value = Path(catalog_path)
        source = (
            source_value.resolve()
            if source_value.is_absolute()
            else (repository / source_value).resolve()
        )
        try:
            source.relative_to(repository)
        except ValueError as exc:
            raise CapabilityCatalogError("catalog path escapes the repository") from exc
        payload = _read_json(source, "production capability catalog")

        schema_path = _inside(
            repository,
            payload.get("$schema"),
            "catalog.$schema",
            base=source.parent,
        )
        schema = _read_json(schema_path, "production capability schema")
        try:
            schema_issues = validate_schema_instance(payload, schema)
        except SchemaDefinitionError as exc:
            raise CapabilityCatalogError(f"invalid capability schema: {exc}") from exc
        if schema_issues:
            raise CapabilityCatalogError(
                "production capability catalog failed schema validation:\n- "
                + "\n- ".join(str(item) for item in schema_issues)
            )

        manifest_declaration = payload["commandManifest"]
        command_manifest_path = _inside(
            repository,
            manifest_declaration["path"],
            "catalog.commandManifest.path",
        )
        try:
            measured_manifest_hash = _sha256_file(command_manifest_path)
        except OSError as exc:
            raise CapabilityCatalogError(
                f"cannot hash command manifest {command_manifest_path}: {exc}"
            ) from exc
        expected_manifest_hash = manifest_declaration["sha256"]
        if not _SHA256.fullmatch(expected_manifest_hash):
            raise CapabilityCatalogError("catalog.commandManifest.sha256 is invalid")
        if measured_manifest_hash != expected_manifest_hash:
            raise CapabilityCatalogError(
                "Studio command manifest drifted from the capability catalog: "
                f"expected {expected_manifest_hash}, measured {measured_manifest_hash}"
            )
        try:
            registry = CommandRegistry.from_file(command_manifest_path)
        except CommandRegistryError as exc:
            raise CapabilityCatalogError(str(exc)) from exc
        if registry.schema_version != manifest_declaration["schemaVersion"]:
            raise CapabilityCatalogError(
                "command manifest schemaVersion differs from the capability catalog"
            )
        if registry.protocol != manifest_declaration["protocol"]:
            raise CapabilityCatalogError(
                "command manifest protocol differs from the capability catalog"
            )

        phases, capabilities = cls._parse(payload, registry)
        return cls(
            root=repository,
            source=source,
            payload=payload,
            registry=registry,
            command_manifest_path=command_manifest_path,
            command_manifest_hash=measured_manifest_hash,
            phases=phases,
            capabilities=capabilities,
        )

    @classmethod
    def _parse(
        cls,
        payload: dict[str, Any],
        registry: CommandRegistry,
    ) -> tuple[tuple[dict[str, str], ...], tuple[ProductionCapability, ...]]:
        raw_phases = payload.get("phases", [])
        phases = tuple(
            {
                "id": str(item["id"]),
                "title": str(item["title"]),
                "description": str(item["description"]),
            }
            for item in raw_phases
        )
        phase_ids = tuple(item["id"] for item in phases)
        if phase_ids != REQUIRED_PHASES:
            raise CapabilityCatalogError(
                "catalog phases must appear exactly in industrial pipeline order: "
                + ", ".join(REQUIRED_PHASES)
            )

        capabilities: list[ProductionCapability] = []
        identifiers: set[str] = set()
        command_owners: dict[str, str] = {}
        for index, raw in enumerate(payload.get("capabilities", [])):
            label = f"capabilities[{index}]"
            identifier = raw["id"]
            if not _CAPABILITY_ID.fullmatch(identifier):
                raise CapabilityCatalogError(f"{label}.id is invalid: {identifier!r}")
            if identifier in identifiers:
                raise CapabilityCatalogError(f"duplicate capability id: {identifier}")
            identifiers.add(identifier)
            phase = raw["phase"]
            if phase not in REQUIRED_PHASES:
                raise CapabilityCatalogError(f"{label}.phase is unknown: {phase!r}")
            status = raw["status"]
            if status not in CAPABILITY_STATUSES:
                raise CapabilityCatalogError(f"{label}.status is invalid: {status!r}")
            validation_level = raw["validationLevel"]
            if validation_level not in VALIDATION_LEVELS:
                raise CapabilityCatalogError(
                    f"{label}.validationLevel is invalid: {validation_level!r}"
                )

            bridge_commands: list[BridgeCommandRef] = []
            local_commands: set[str] = set()
            for command_index, command in enumerate(raw["bridgeCommands"]):
                method = command["method"]
                command_label = f"{label}.bridgeCommands[{command_index}]"
                if method in local_commands:
                    raise CapabilityCatalogError(
                        f"{command_label}: duplicate command {method!r}"
                    )
                local_commands.add(method)
                if method in command_owners:
                    raise CapabilityCatalogError(
                        f"bridge command {method!r} is owned by both "
                        f"{command_owners[method]} and {identifier}"
                    )
                try:
                    spec = registry.require(method)
                except CommandRegistryError as exc:
                    raise CapabilityCatalogError(
                        f"{command_label}: references nonexistent command {method!r}"
                    ) from exc
                required = command["required"]
                if spec.availability == "unsupported" and required:
                    raise CapabilityCatalogError(
                        f"{command_label}: unsupported command cannot be required"
                    )
                if spec.availability == "unsupported" and status not in {
                    "PARTIAL",
                    "BLOCKED",
                    "UNSUPPORTED",
                }:
                    raise CapabilityCatalogError(
                        f"{command_label}: unsupported command is hidden by status {status}"
                    )
                command_owners[method] = identifier
                bridge_commands.append(BridgeCommandRef(method, required))

            adapters = tuple(
                PythonAdapterRef(item["symbol"], item["role"], item["required"])
                for item in raw["adapters"]
            )
            risks = _strings(raw["risks"], f"{label}.risks")
            limitations = _strings(raw["limitations"], f"{label}.limitations")
            gaps = _strings(raw["gaps"], f"{label}.gaps")
            if status == "AVAILABLE":
                if validation_level == "NOT_VALIDATED":
                    raise CapabilityCatalogError(
                        f"{identifier}: AVAILABLE cannot be NOT_VALIDATED"
                    )
                if gaps:
                    raise CapabilityCatalogError(
                        f"{identifier}: AVAILABLE capability cannot declare gaps"
                    )
            else:
                if not gaps:
                    raise CapabilityCatalogError(
                        f"{identifier}: {status} capability must declare at least one gap"
                    )
            if status == "GAP" and (bridge_commands or adapters):
                raise CapabilityCatalogError(
                    f"{identifier}: GAP capability cannot claim implemented interfaces"
                )
            capabilities.append(
                ProductionCapability(
                    id=identifier,
                    phase=phase,
                    title=raw["title"],
                    description=raw["description"],
                    status=status,
                    validation_level=validation_level,
                    bridge_commands=tuple(bridge_commands),
                    adapters=adapters,
                    risks=risks,
                    limitations=limitations,
                    gaps=gaps,
                )
            )

        absent_phases = sorted(set(REQUIRED_PHASES) - {item.phase for item in capabilities})
        if absent_phases:
            raise CapabilityCatalogError(
                "production phases have no capability entries: " + ", ".join(absent_phases)
            )
        registry_commands = set(registry.methods())
        catalog_commands = set(command_owners)
        missing = sorted(registry_commands - catalog_commands)
        unknown = sorted(catalog_commands - registry_commands)
        if missing or unknown:
            details: list[str] = []
            if missing:
                details.append("unmapped registry commands: " + ", ".join(missing))
            if unknown:
                details.append("nonexistent catalog commands: " + ", ".join(unknown))
            raise CapabilityCatalogError("command/capability inventory mismatch: " + "; ".join(details))
        return phases, tuple(capabilities)

    def _adapter_resolutions(self) -> dict[str, AdapterResolution]:
        symbols = sorted(
            {adapter.symbol for capability in self.capabilities for adapter in capability.adapters}
        )
        return {symbol: resolve_python_adapter(self.root, symbol) for symbol in symbols}

    def _readiness_reasons(
        self,
        capability: ProductionCapability,
        resolutions: Mapping[str, AdapterResolution],
        *,
        minimum_validation_level: str = "STATICALLY_VALIDATED",
    ) -> list[str]:
        reasons: list[str] = []
        if capability.status != "AVAILABLE":
            reasons.append(f"capability status is {capability.status}, not AVAILABLE")
        if not validation_level_at_least(
            capability.validation_level,
            minimum_validation_level,
        ):
            reasons.append(
                f"declared validation level {capability.validation_level} is below "
                f"{minimum_validation_level}"
            )
        for command in capability.bridge_commands:
            if not command.required:
                continue
            spec = self.registry.require(command.method)
            if spec.availability != "supported":
                reasons.append(
                    f"required bridge command {command.method} is {spec.availability}"
                )
        for adapter in capability.adapters:
            if adapter.required and not resolutions[adapter.symbol].resolved:
                reasons.append(
                    f"required adapter {adapter.symbol} is unresolved: "
                    f"{resolutions[adapter.symbol].error}"
                )
        return reasons

    def coverage_report(self) -> dict[str, Any]:
        """Return catalog integrity and honest production-readiness coverage."""

        resolutions = self._adapter_resolutions()
        declarations: dict[str, dict[str, Any]] = {}
        for capability in self.capabilities:
            for adapter in capability.adapters:
                row = declarations.setdefault(
                    adapter.symbol,
                    {
                        "roles": set(),
                        "capabilityIds": set(),
                        "required": False,
                    },
                )
                row["roles"].add(adapter.role)
                row["capabilityIds"].add(capability.id)
                row["required"] = row["required"] or adapter.required

        adapter_rows: list[dict[str, Any]] = []
        issues: list[dict[str, str]] = []
        for symbol in sorted(resolutions):
            resolution = resolutions[symbol]
            declaration = declarations[symbol]
            adapter_rows.append(
                {
                    **resolution.to_dict(),
                    "roles": sorted(declaration["roles"]),
                    "capabilityIds": sorted(declaration["capabilityIds"]),
                    "required": declaration["required"],
                }
            )
            if not resolution.resolved:
                issues.append(
                    {
                        "code": "E_ADAPTER_UNRESOLVED",
                        "message": f"{symbol}: {resolution.error}",
                    }
                )

        readiness: dict[str, bool] = {}
        for capability in self.capabilities:
            readiness[capability.id] = not self._readiness_reasons(
                capability,
                resolutions,
            )

        phase_rows: list[dict[str, Any]] = []
        for phase in self.phases:
            members = [item for item in self.capabilities if item.phase == phase["id"]]
            ready = [item for item in members if readiness[item.id]]
            phase_rows.append(
                {
                    "id": phase["id"],
                    "title": phase["title"],
                    "capabilityIds": [item.id for item in members],
                    "capabilityCount": len(members),
                    "readyCapabilityCount": len(ready),
                    "statuses": sorted({item.status for item in members}),
                    "productionReady": len(ready) == len(members),
                }
            )

        status_counts = {
            status: sum(item.status == status for item in self.capabilities)
            for status in sorted(CAPABILITY_STATUSES)
        }
        registry_commands = list(self.registry.methods())
        unsupported = [
            method
            for method in registry_commands
            if self.registry.require(method).availability == "unsupported"
        ]
        resolved_count = sum(item.resolved for item in resolutions.values())
        ready_count = sum(readiness.values())
        gaps = [
            {
                "capabilityId": item.id,
                "phase": item.phase,
                "status": item.status,
                "items": list(item.gaps),
            }
            for item in self.capabilities
            if item.gaps
        ]
        integrity_status = "PASS" if not issues else "BLOCKED"
        production_ready = (
            integrity_status == "PASS"
            and ready_count == len(self.capabilities)
            and not gaps
        )
        report = {
            "$schema": REPORT_SCHEMA,
            "schemaVersion": 1,
            "reportType": "rqe.production-capability-coverage",
            "generatedAt": _utc_now(),
            "authorizesRelease": False,
            "validationLevel": (
                "STATICALLY_VALIDATED" if integrity_status == "PASS" else "NOT_VALIDATED"
            ),
            "integrityStatus": integrity_status,
            "productionReadiness": "READY" if production_ready else "INCOMPLETE",
            "catalog": {
                "id": self.catalog_id,
                "path": self.source.relative_to(self.root).as_posix(),
                "sha256": self.catalog_hash,
            },
            "commandManifest": {
                "path": self.command_manifest_path.relative_to(self.root).as_posix(),
                "sha256": self.command_manifest_hash,
                "schemaVersion": self.registry.schema_version,
                "protocol": self.registry.protocol,
            },
            "summary": {
                "phaseTotal": len(self.phases),
                "capabilityTotal": len(self.capabilities),
                "capabilityByStatus": status_counts,
                "readyCapabilityTotal": ready_count,
                "readyCapabilityCoverage": _ratio(ready_count, len(self.capabilities)),
                "bridgeCommandTotal": len(registry_commands),
                "mappedBridgeCommandTotal": len(registry_commands),
                "bridgeCommandCoverage": 1.0,
                "unsupportedBridgeCommandTotal": len(unsupported),
                "adapterTotal": len(resolutions),
                "resolvedAdapterTotal": resolved_count,
                "adapterCoverage": _ratio(resolved_count, len(resolutions)),
            },
            "phases": phase_rows,
            "bridgeCommands": {
                "mapped": registry_commands,
                "unmapped": [],
                "unknown": [],
                "unsupported": unsupported,
            },
            "adapters": adapter_rows,
            "gaps": gaps,
            "issues": issues,
        }
        _validate_owned_output(self.root, report, REPORT_SCHEMA_RELATIVE_PATH)
        return report

    def assert_integrity(self) -> dict[str, Any]:
        report = self.coverage_report()
        if report["integrityStatus"] != "PASS":
            messages = [item["message"] for item in report["issues"]]
            raise CapabilityCatalogError(
                "production capability catalog integrity failed:\n- "
                + "\n- ".join(messages)
            )
        return report

    def select(
        self,
        *,
        phases: Iterable[str] = (),
        capability_ids: Iterable[str] = (),
        minimum_validation_level: str = "STATICALLY_VALIDATED",
    ) -> dict[str, Any]:
        """Create a fail-closed receipt for a requested production slice.

        Phase and explicit capability selectors are combined as a union.  A
        selection is ``PASS`` only when every selected capability is AVAILABLE,
        meets the requested declared validation floor, and has all required
        command/adaptor surfaces present.  This still does not execute them.
        """

        if minimum_validation_level not in VALIDATION_LEVELS:
            raise CapabilitySelectionError(
                f"invalid minimum validation level: {minimum_validation_level}"
            )
        requested_phases = tuple(sorted(set(phases)))
        requested_ids = tuple(sorted(set(capability_ids)))
        unknown_phases = sorted(set(requested_phases) - set(REQUIRED_PHASES))
        unknown_ids = sorted(set(requested_ids) - set(self._by_id))
        if unknown_phases or unknown_ids:
            details: list[str] = []
            if unknown_phases:
                details.append("unknown phases: " + ", ".join(unknown_phases))
            if unknown_ids:
                details.append("unknown capability ids: " + ", ".join(unknown_ids))
            raise CapabilitySelectionError("; ".join(details))

        if requested_phases or requested_ids:
            selected = [
                item
                for item in self.capabilities
                if item.phase in requested_phases or item.id in requested_ids
            ]
        else:
            selected = list(self.capabilities)
        if not selected:
            raise CapabilitySelectionError("selection resolved to no capabilities")

        integrity = self.coverage_report()
        resolutions = self._adapter_resolutions()
        selected_rows: list[dict[str, Any]] = []
        blockers: list[dict[str, str]] = []
        required_commands = 0
        supported_commands = 0
        required_adapters = 0
        resolved_adapters = 0
        ready_capabilities = 0
        for capability in selected:
            reasons = self._readiness_reasons(
                capability,
                resolutions,
                minimum_validation_level=minimum_validation_level,
            )
            selectable = not reasons and integrity["integrityStatus"] == "PASS"
            if selectable:
                ready_capabilities += 1
            for reason in reasons:
                blockers.append(
                    {
                        "code": "E_CAPABILITY_NOT_READY",
                        "capabilityId": capability.id,
                        "message": reason,
                    }
                )
            required_command_rows = [item for item in capability.bridge_commands if item.required]
            required_commands += len(required_command_rows)
            supported_commands += sum(
                self.registry.require(item.method).availability == "supported"
                for item in required_command_rows
            )
            required_adapter_rows = [item for item in capability.adapters if item.required]
            required_adapters += len(required_adapter_rows)
            resolved_adapters += sum(
                resolutions[item.symbol].resolved for item in required_adapter_rows
            )
            selected_rows.append(
                {
                    "id": capability.id,
                    "phase": capability.phase,
                    "status": capability.status,
                    "declaredValidationLevel": capability.validation_level,
                    "selectable": selectable,
                    "reasons": reasons,
                    "bridgeCommands": [
                        {
                            "method": item.method,
                            "required": item.required,
                            "availability": self.registry.require(item.method).availability,
                        }
                        for item in capability.bridge_commands
                    ],
                    "adapters": [
                        {
                            "symbol": item.symbol,
                            "required": item.required,
                            "resolved": resolutions[item.symbol].resolved,
                        }
                        for item in capability.adapters
                    ],
                    "risks": list(capability.risks),
                    "limitations": list(capability.limitations),
                    "gaps": list(capability.gaps),
                }
            )

        if integrity["integrityStatus"] != "PASS":
            blockers.extend(
                {
                    "code": item["code"],
                    "capabilityId": "catalog",
                    "message": item["message"],
                }
                for item in integrity["issues"]
            )
        selection_status = "PASS" if not blockers else "BLOCKED"
        request = {
            "selectorMode": "UNION",
            "phases": list(requested_phases),
            "capabilityIds": list(requested_ids),
            "minimumValidationLevel": minimum_validation_level,
        }
        coverage = {
            "selectedCapabilityTotal": len(selected),
            "readyCapabilityTotal": ready_capabilities,
            "readyCapabilityCoverage": _ratio(ready_capabilities, len(selected)),
            "requiredBridgeCommandTotal": required_commands,
            "supportedRequiredBridgeCommandTotal": supported_commands,
            "requiredBridgeCommandCoverage": _ratio(supported_commands, required_commands),
            "requiredAdapterTotal": required_adapters,
            "resolvedRequiredAdapterTotal": resolved_adapters,
            "requiredAdapterCoverage": _ratio(resolved_adapters, required_adapters),
        }
        identity = {
            "catalogId": self.catalog_id,
            "catalogSha256": self.catalog_hash,
            "commandManifestSha256": self.command_manifest_hash,
            "request": request,
            "selectedCapabilities": selected_rows,
            "coverage": coverage,
            "selectionStatus": selection_status,
            "blockers": blockers,
        }
        receipt = {
            "$schema": SELECTION_SCHEMA,
            "schemaVersion": 1,
            "receiptType": "rqe.production-capability-selection",
            "receiptId": _canonical_sha256(identity),
            "createdAt": _utc_now(),
            "authorizesRelease": False,
            "receiptValidationLevel": "STATICALLY_VALIDATED",
            "selectionStatus": selection_status,
            "catalog": {
                "id": self.catalog_id,
                "sha256": self.catalog_hash,
            },
            "commandManifest": {
                "sha256": self.command_manifest_hash,
                "schemaVersion": self.registry.schema_version,
                "protocol": self.registry.protocol,
            },
            "request": request,
            "selectedCapabilities": selected_rows,
            "coverage": coverage,
            "blockers": blockers,
        }
        _validate_owned_output(self.root, receipt, SELECTION_SCHEMA_RELATIVE_PATH)
        return receipt


def repository_root() -> Path:
    return Path(__file__).resolve().parents[1]


def load_default_catalog(*, verify: bool = True) -> ProductionCapabilityCatalog:
    catalog = ProductionCapabilityCatalog.load(repository_root())
    if verify:
        catalog.assert_integrity()
    return catalog


def write_structured_receipt(path: str | Path, payload: Mapping[str, Any]) -> Path:
    """Atomically write a report/receipt without creating a global latest file."""

    destination = Path(path)
    if not isinstance(payload, Mapping) or payload.get("schemaVersion") != 1:
        raise CapabilityCatalogError("receipt payload must be a versioned mapping")
    if payload.get("authorizesRelease") is not False:
        raise CapabilityCatalogError("capability receipts must never authorize release")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, destination)
    return destination
