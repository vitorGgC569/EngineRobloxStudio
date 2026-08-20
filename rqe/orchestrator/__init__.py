"""Fail-closed primitives for the agentic production orchestrator.

This package does not discover agents or talk to Studio on its own.  Its durable
executor invokes only deterministic handlers explicitly registered by the
caller, while owning the invariants those adapters must obey: task ordering,
exclusive write ownership, impact selection, campaign state transitions,
leases, checkpoints, and an append-only local journal.
"""

from .dag import TaskGraph, TaskGraphError
from .blueprint import (
    BlueprintError,
    GameProjectDefinition,
    ProductionBlueprint,
    ProductionPlan,
    compile_production_blueprint,
    load_game_project_definition,
    load_production_blueprint,
)
from .impact import ImpactMapError, ImpactSelection, ImpactSelector
from .executor import (
    CampaignExecutionReport,
    DurableDagExecutor,
    ExecutionPolicy,
    ExecutorError,
    HandlerCancelled,
    HandlerRegistration,
    HandlerRegistrationError,
    HandlerRegistry,
    HandlerResult,
    TaskExecutionContext,
    TaskExecutionState,
)
from .journal import (
    CampaignBindingError,
    JournalEvent,
    LeaseUnavailable,
    SQLiteJournal,
    StaleFenceError,
    TaskCheckpoint,
    TaskLease,
)
from .models import (
    CampaignStage,
    CampaignStateMachine,
    TaskSpec,
    TaskStatus,
    TransitionError,
    ValidationOutcome,
    ValidationScope,
)
from .ownership import OwnershipConflict, OwnershipRegistry, canonical_write_path

__all__ = [
    "BlueprintError",
    "CampaignStage",
    "CampaignStateMachine",
    "CampaignBindingError",
    "CampaignExecutionReport",
    "DurableDagExecutor",
    "ExecutionPolicy",
    "ExecutorError",
    "GameProjectDefinition",
    "ImpactMapError",
    "ImpactSelection",
    "ImpactSelector",
    "JournalEvent",
    "HandlerCancelled",
    "HandlerRegistration",
    "HandlerRegistrationError",
    "HandlerRegistry",
    "HandlerResult",
    "LeaseUnavailable",
    "OwnershipConflict",
    "OwnershipRegistry",
    "ProductionBlueprint",
    "ProductionPlan",
    "SQLiteJournal",
    "StaleFenceError",
    "TaskGraph",
    "TaskGraphError",
    "TaskCheckpoint",
    "TaskExecutionContext",
    "TaskExecutionState",
    "TaskLease",
    "TaskSpec",
    "TaskStatus",
    "TransitionError",
    "ValidationOutcome",
    "ValidationScope",
    "canonical_write_path",
    "compile_production_blueprint",
    "load_game_project_definition",
    "load_production_blueprint",
]
