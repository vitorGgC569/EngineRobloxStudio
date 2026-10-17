"""The factory family: campaigns, capability selection, promotion.

The layer that is supposed to be driving the engine was itself only reachable by
shelling out. These tools close that, and two of them are shaped by what they
must refuse rather than by what they do.

**`capabilities_select` cannot authorise anything.** It says which slice of the
production surface is ready and refuses the rest, and the receipt states on
every response that a capability inventory is not permission to ship.

**`release_promote` cannot promote on its own say-so.** It requires a passing
deterministic gate on the same run and an explicit human confirmation, and it
refuses both when absent. Promotion pushes something outward; a tool that does
that on a default argument is a tool that will eventually do it by accident.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .server import EngineMcpServer, Tool, ToolError
from ..safe_io import SafeIoError, atomic_write_text, read_text_limited
from ..security import SecurityBoundaryError, resolve_inside, validate_path_component


def _inside(root: Path, relative: str, label: str, **checks: Any) -> Path:
    try:
        return resolve_inside(root, relative, label=label, **checks)
    except SecurityBoundaryError as exc:
        raise ToolError(str(exc)) from exc


def register_campaign_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    # ---------------------------------------------------------- capabilities

    def capabilities_select(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..production_capabilities import (
            CapabilitySelectionError,
            load_default_catalog,
        )

        try:
            catalog = load_default_catalog()
            receipt = catalog.select(
                phases=arguments.get("phases", ()),
                capability_ids=arguments.get("capabilityIds", ()),
                minimum_validation_level=arguments.get(
                    "minimumValidationLevel", "STATICALLY_VALIDATED"
                ),
            )
        except CapabilitySelectionError as exc:
            raise ToolError(str(exc)) from exc
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        return {
            "selectionStatus": receipt.get("selectionStatus"),
            "authorizesRelease": receipt.get("authorizesRelease"),
            "coverage": receipt.get("coverage"),
            "blockers": receipt.get("blockers"),
            "selected": [
                item.get("id") if isinstance(item, dict) else item
                for item in receipt.get("selectedCapabilities") or []
            ],
            "receiptId": receipt.get("receiptId"),
            "note": (
                "a capability inventory says what exists, never that it is good enough to ship"
            ),
            "receipt": receipt,
        }

    server.register(Tool(
        name="capabilities_select",
        description=(
            "Select a slice of the production surface by phase or capability id and get a "
            "fail-closed receipt: PASS only when every selected capability is available, "
            "meets the validation floor, and has its commands and adapters present."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "phases": {"type": "array", "items": {"type": "string", "minLength": 1}},
                "capabilityIds": {"type": "array", "items": {"type": "string", "minLength": 1}},
                "minimumValidationLevel": {
                    "enum": [
                        "NOT_VALIDATED", "STATICALLY_VALIDATED", "RUNTIME_VALIDATED",
                        "VISUALLY_VALIDATED", "E2E_VALIDATED",
                    ]
                },
            },
        },
        handler=capabilities_select,
    ))

    def capabilities_explain(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..production_capabilities import load_default_catalog

        try:
            catalog = load_default_catalog()
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        report = catalog.coverage_report()
        wanted = arguments.get("capabilityId")

        # The coverage report carries only ids per phase, so the full records
        # come from the catalogue itself. Reading them off the report would give
        # a listing with no risks, limitations or gaps in it -- which is exactly
        # the part an agent needs in order to decide what to rely on.
        records = {
            str(item["id"]): item
            for item in (catalog.payload.get("capabilities") or [])
            if isinstance(item, dict) and item.get("id")
        }

        if wanted:
            match = records.get(wanted)
            if match is None:
                raise ToolError(
                    f"unknown capability {wanted!r}; available: " + ", ".join(sorted(records))
                )
            return dict(match)

        # Grouped by status rather than listed flat: what an agent needs from an
        # inventory is "what can I rely on", and forty rows in declaration order
        # does not answer that.
        grouped: dict[str, list[str]] = {}
        for identifier, item in records.items():
            grouped.setdefault(str(item.get("status", "UNKNOWN")), []).append(identifier)
        return {
            "byStatus": {key: sorted(value) for key, value in sorted(grouped.items())},
            "capabilityCount": len(records),
            "phases": [
                {
                    "id": phase.get("id"),
                    "ready": phase.get("productionReady"),
                    "capabilities": phase.get("capabilityCount"),
                    "readyCapabilities": phase.get("readyCapabilityCount"),
                }
                for phase in report.get("phases") or []
            ],
            "summary": report.get("summary"),
            "gaps": report.get("gaps"),
            "authorizesRelease": report.get("authorizesRelease"),
        }

    server.register(Tool(
        name="capabilities_explain",
        description=(
            "Explain one capability -- its risks, limitations and gaps -- or group the "
            "whole inventory by status so an agent can see what it can rely on."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {"capabilityId": {"type": "string", "minLength": 1}},
        },
        handler=capabilities_explain,
    ))

    def factory_create_project(arguments: dict[str, Any]) -> dict[str, Any]:
        """Compile a game definition into a production plan and store it.

        The entry point of the factory. It does not build anything: it turns a
        declared game into the deterministic DAG that would build it, which is
        what makes two different games provably travel the same path.
        """

        from ..orchestrator.blueprint import compile_production_blueprint

        source = _inside(
            root,
            arguments["definition"],
            "definition",
            must_exist=True,
            file_only=True,
            suffixes=(".json",),
        )
        try:
            document = read_text_limited(source, 4 * 1024 * 1024, label="game definition")
            plan = compile_production_blueprint(json.loads(document))
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        payload = plan.to_dict() if hasattr(plan, "to_dict") else {}
        output = _inside(root, arguments.get("output", ".tmp/plans"), "output")
        output.mkdir(parents=True, exist_ok=True)
        try:
            plan_id = validate_path_component(
                payload.get("planId") or source.stem,
                label="planId",
            )
            written = resolve_inside(output, f"{plan_id}.plan.json", label="plan output")
            write_status = atomic_write_text(
                written,
                json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                overwrite=bool(arguments.get("overwrite")),
            )
        except (SecurityBoundaryError, SafeIoError) as exc:
            raise ToolError(str(exc)) from exc

        from .factory_tools import _summarise_plan

        return {
            "definition": str(source.relative_to(root)),
            "plan": str(written.relative_to(root)),
            "writeStatus": write_status,
            **_summarise_plan(payload),
            "note": "a plan describes what would be built; nothing has been executed",
        }

    server.register(Tool(
        name="factory_create_project",
        description=(
            "Compile a game definition into a deterministic production plan and store it. "
            "Builds nothing; this is what lets two different games travel the same path."
        ),
        input_schema={
            "type": "object",
            "required": ["definition"],
            "additionalProperties": False,
            "properties": {
                "definition": {"type": "string", "minLength": 1},
                "output": {"type": "string"},
                "overwrite": {"type": "boolean"},
            },
        },
        handler=factory_create_project,
    ))

    # -------------------------------------------------------------- campaign

    def factory_campaign(arguments: dict[str, Any]) -> dict[str, Any]:
        """Drive a campaign's state machine: execute, resume or abort.

        The machine is deliberately small and deliberately strict. `RELEASED`
        cannot be reached without a passing deterministic gate, and a terminal
        campaign cannot be restarted -- both refusals live in the machine rather
        than in the caller, so no tool can talk its way past them.
        """

        from ..orchestrator.journal import SQLiteJournal
        from ..orchestrator.models import (
            CampaignStage,
            CampaignStateMachine,
            TransitionError,
        )

        journal_path = _inside(
            root,
            arguments.get("journal", ".tmp/campaign.sqlite"),
            "journal",
            suffixes=(".sqlite", ".sqlite3", ".db"),
        )
        journal_path.parent.mkdir(parents=True, exist_ok=True)
        journal = SQLiteJournal(journal_path)

        campaign = arguments["campaign"]
        action = arguments["action"]

        machine = CampaignStateMachine()
        replayed = 0
        try:
            for event in journal.events(campaign):
                stage = CampaignStage(event.payload["stage"])
                machine.state = stage
                machine.history.append(stage)
                replayed += 1
        except Exception:  # noqa: BLE001 - an empty or unreadable journal is a fresh campaign
            pass

        if action == "inspect":
            return {
                "campaign": campaign,
                "state": machine.state.value,
                "history": [stage.value for stage in machine.history],
                "eventsReplayed": replayed,
                "terminal": machine.state.value in {"RELEASED", "CANCELLED", "INFRA_FAILED"},
            }

        target = {
            "execute": arguments.get("stage"),
            "resume": arguments.get("stage"),
            "abort": "CANCELLED",
        }.get(action)
        if not target:
            raise ToolError(
                f"{action} needs a target stage; valid stages: "
                + ", ".join(stage.value for stage in CampaignStage)
            )

        try:
            stage = machine.transition(CampaignStage(target))
        except (TransitionError, ValueError) as exc:
            raise ToolError(str(exc)) from exc

        journal.append(campaign, "stage", {"stage": stage.value, "action": action})
        return {
            "campaign": campaign,
            "action": action,
            "state": stage.value,
            "history": [item.value for item in machine.history],
            "journal": str(journal_path.relative_to(root)),
        }

    server.register(Tool(
        name="factory_campaign",
        description=(
            "Inspect, advance, resume or abort a production campaign. RELEASED is "
            "unreachable without a passing deterministic gate, and a terminal campaign "
            "cannot be restarted."
        ),
        input_schema={
            "type": "object",
            "required": ["campaign", "action"],
            "additionalProperties": False,
            "properties": {
                "campaign": {"type": "string", "minLength": 1},
                "action": {"enum": ["inspect", "execute", "resume", "abort"]},
                "stage": {"type": "string"},
                "journal": {"type": "string"},
            },
        },
        handler=factory_campaign,
    ))

    # ------------------------------------------------------------- promotion

    def release_promote(arguments: dict[str, Any]) -> dict[str, Any]:
        """Mark a run as promoted, and refuse unless it earned it.

        Two gates, both required. The run's own gate must have allowed release,
        and a human must have said so. Neither is a formality: promotion is the
        moment something goes outward, and the whole platform is arranged so
        that moment is never reached by accident.
        """

        run_dir = _inside(root, arguments["run"], "run", must_exist=True, directory_only=True)
        gate_path = _inside(
            root,
            str((run_dir / "gate.json").relative_to(root)),
            "gate",
            suffixes=(".json",),
        )
        if not gate_path.is_file():
            raise ToolError(
                f"{run_dir} has no gate.json; a run that was never evaluated cannot be promoted"
            )
        try:
            gate = json.loads(read_text_limited(gate_path, 8 * 1024 * 1024, label="release gate"))
        except (SafeIoError, json.JSONDecodeError) as exc:
            raise ToolError(f"cannot read release gate: {exc}") from exc
        allowed = bool(gate.get("releaseAllowed"))
        blockers = gate.get("blockers") or []

        if not allowed:
            return {
                "promoted": False,
                "reason": "the release gate did not allow this run",
                "blockerCount": len(blockers),
                "blockers": blockers[:10],
            }
        if arguments.get("confirmPromotion") is not True:
            return {
                "promoted": False,
                "reason": (
                    "the gate passed, but promotion sends this outward and needs an "
                    "explicit decision; pass confirmPromotion=true"
                ),
                "gateAllowed": True,
            }

        receipt = {
            "schemaVersion": 1,
            "promoted": True,
            "runId": gate.get("runId"),
            "buildHash": gate.get("buildHash"),
            "promotedBy": arguments.get("actor", "unspecified"),
            "scores": gate.get("scores"),
            # Recorded, not claimed: promotion here marks the candidate as
            # approved by this engine. Publishing it to Roblox is a separate,
            # human step, and conflating the two would let a receipt imply
            # something reached players when it did not.
            "note": (
                "this marks the candidate approved by the engine; publishing to Roblox "
                "remains a separate human action"
            ),
        }
        try:
            atomic_write_text(
                run_dir / "promotion.json",
                json.dumps(receipt, indent=2, ensure_ascii=False) + "\n",
                overwrite=False,
            )
        except SafeIoError as exc:
            raise ToolError(str(exc)) from exc
        return receipt

    server.register(Tool(
        name="release_promote",
        description=(
            "Mark an evaluated run as promoted. Refuses unless its gate allowed release "
            "AND promotion is explicitly confirmed. Does not publish anything."
        ),
        input_schema={
            "type": "object",
            "required": ["run"],
            "additionalProperties": False,
            "properties": {
                "run": {"type": "string", "minLength": 1},
                "confirmPromotion": {"type": "boolean"},
                "actor": {"type": "string"},
            },
        },
        handler=release_promote,
    ))

    return server
