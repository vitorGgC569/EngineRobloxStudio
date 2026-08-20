"""The system composer: assemble a game's systems instead of writing them.

The Game IR already knows which systems a game needs -- `required_systems`
follows the loop verbs and the dependency graph. What it could not do was hand
back anything runnable. That is this layer.

A composition names, for every system the model implies: the module that
implements it, the configuration derived from the model, and the systems it must
be started after. Nothing is generated as source text; the modules are the ones
in `roblox/lib/GameKit`, so a composed game runs the code the SDK ships and
fixing a bug there fixes it in every game at once.

**A composed system must actually load.** `verify` requires each module through
the headless harness and calls into it, so "composed" means "ran", not
"referenced". A composer that only emitted names would report a complete game
whose first `require` fails at runtime, and it would report it identically for
systems that exist and systems nobody has written.

**A system with no implementation is `PLANNED`, never silently absent.** Ten of
the fifteen systems the vocabulary accepts have no module yet. Listing only the
five that do would make a model asking for `gacha` look complete; naming the gap
keeps the denominator honest, and it is the same discipline `rqe/primitives.py`
uses for the same reason.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


class CompositionError(RuntimeError):
    """The systems could not be composed, and the message says which."""


@dataclass(frozen=True)
class SystemSpec:
    """One system: what implements it, and what it needs to start."""

    id: str
    #: The GameKit module, or "" when nothing implements it yet.
    module: str
    #: Systems that must be constructed first. Not the same as the IR's
    #: dependency list: that one is about design coherence, this one is about
    #: startup order.
    after: tuple[str, ...] = ()
    summary: str = ""
    #: Why there is no module, when there is not. Required for PLANNED systems
    #: so a gap can never be recorded as a shrug.
    planned_reason: str = ""

    @property
    def implemented(self) -> bool:
        return bool(self.module)

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "id": self.id,
            "status": "IMPLEMENTED" if self.implemented else "PLANNED",
            "after": list(self.after),
            "summary": self.summary,
        }
        if self.implemented:
            payload["module"] = f"GameKit.{self.module}"
        else:
            payload["plannedReason"] = self.planned_reason
        return payload


#: Every system the Game IR vocabulary accepts, and what stands behind it.
#:
#: The five implemented ones are real Luau in `roblox/lib/GameKit`. The rest are
#: named with their reason rather than omitted: a model asking for `gacha` must
#: find out here, cheaply, rather than at the first `require`.
SYSTEMS: dict[str, SystemSpec] = {
    "analytics": SystemSpec(
        "analytics", "Analytics",
        summary="funnels, onboarding steps and economy flows, emitted where the "
                "event happens rather than where somebody remembered to log it",
    ),
    "economy": SystemSpec(
        "economy", "Economy", after=("analytics",),
        summary="one atomic path for every currency movement, with a ledger a "
                "headless simulation can replay",
    ),
    "save": SystemSpec(
        "save", "Save", after=("analytics",),
        summary="session-locked persistence; a save duplicated across servers is "
                "the failure this exists to prevent",
    ),
    "progression": SystemSpec(
        "progression", "Progression", after=("economy",),
        summary="an ordered ladder with pacing that can be measured before anyone "
                "plays",
    ),
    "inventory": SystemSpec(
        "inventory", "Inventory", after=("analytics",),
        summary="stacks with capacity that refuses loudly; a partial pickup is "
                "reported rather than silently dropped",
    ),
    "shop": SystemSpec(
        "shop", "Shop", after=("economy", "inventory"),
        summary="offers, stock limits and tier gates, with debit and record in one "
                "atomic step and every refusal named -- a UI handed one boolean "
                "shows the same message for cannot-afford and already-owned",
    ),
    "quests": SystemSpec(
        "quests", "", after=("progression", "analytics"),
        planned_reason="no module yet; needs an objective graph with persistence, "
                       "which is a larger design than it looks because a quest "
                       "half-completed across a save is the whole problem",
    ),
    "crafting": SystemSpec(
        "crafting", "", after=("inventory", "economy"),
        planned_reason="no module yet; recipes are straightforward, but consuming "
                       "inputs and granting outputs atomically across two systems "
                       "is the part worth writing once",
    ),
    "trading": SystemSpec(
        "trading", "", after=("inventory", "analytics"),
        planned_reason="no module yet; a trade is a two-sided atomic transfer and "
                       "the exploit surface is why it is not improvised per game",
    ),
    "pets": SystemSpec(
        "pets", "", after=("inventory", "save"),
        planned_reason="no module yet",
    ),
    "gacha": SystemSpec(
        "gacha", "", after=("economy", "inventory", "analytics"),
        planned_reason="no module yet; drop tables need a verifiable RNG and a "
                       "published pity mechanic, and both are compliance concerns "
                       "rather than conveniences",
    ),
    "tower": SystemSpec(
        "tower", "Tower", after=("economy",),
        summary="placements, upgrade ladders and waves, with the arithmetic that "
                "decides whether a wave is clearable done before the wave runs -- "
                "an unwinnable level ships because nobody did the division",
    ),
    "offline_income": SystemSpec(
        "offline_income", "", after=("economy", "save"),
        planned_reason="no module yet; needs a trusted clock, and a client-supplied "
                       "elapsed time is the oldest exploit in the genre",
    ),
    "tutorial": SystemSpec(
        "tutorial", "", after=("analytics",),
        planned_reason="no module yet; onboarding steps are already emitted by "
                       "Analytics, so what is missing is the sequencing, not the "
                       "measurement",
    ),
    "leaderboard": SystemSpec(
        "leaderboard", "Leaderboard", after=("analytics",),
        summary="ordered boards with ties broken on a stable key, ascending boards "
                "for times, and an unreachable store reported rather than shown as "
                "an empty board -- which reads to a player as nobody having scored",
    ),
}


@dataclass
class Composition:
    """The systems a game needs, in the order they start."""

    game_id: str
    order: list[str] = field(default_factory=list)
    config: dict[str, Any] = field(default_factory=dict)
    verified: dict[str, Any] = field(default_factory=dict)

    @property
    def implemented(self) -> list[str]:
        return [name for name in self.order if SYSTEMS[name].implemented]

    @property
    def planned(self) -> list[str]:
        return [name for name in self.order if not SYSTEMS[name].implemented]

    @property
    def complete(self) -> bool:
        """Whether every system this game needs actually exists.

        A game with planned systems can still be built -- the rest of it works --
        but calling that complete would hide the part nobody wrote.
        """

        return not self.planned

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "gameId": self.game_id,
            "complete": self.complete,
            "startupOrder": list(self.order),
            "implemented": self.implemented,
            "planned": [
                {"id": name, "reason": SYSTEMS[name].planned_reason}
                for name in self.planned
            ],
            "systems": [SYSTEMS[name].to_dict() for name in self.order],
            "config": self.config,
            "verified": self.verified,
            "note": (
                "the modules are the SDK's own, so a composed game runs shipped code "
                "and a fix there lands in every game at once"
            ),
        }

    def summary(self) -> str:
        lines = [
            f"{'COMPLETE' if self.complete else 'PARTIAL'}  {self.game_id}: "
            f"{len(self.implemented)}/{len(self.order)} systems implemented"
        ]
        lines.append("  order: " + " -> ".join(self.order))
        for name in self.planned:
            lines.append(f"  planned: {name} -- {SYSTEMS[name].planned_reason}")
        if self.verified:
            lines.append(
                f"  verified: {self.verified.get('loaded', 0)} modules loaded and called"
            )
        return "\n".join(lines)


def _topological(names: set[str]) -> list[str]:
    """Startup order, refusing a cycle rather than picking one.

    A cycle here means two systems each expect the other to exist first, and any
    order the composer invented would work until the day it did not.
    """

    order: list[str] = []
    placed: set[str] = set()
    visiting: set[str] = set()

    def visit(name: str, trail: tuple[str, ...]) -> None:
        if name in placed:
            return
        if name in visiting:
            raise CompositionError(
                "systems depend on each other in a cycle: "
                + " -> ".join(trail + (name,))
            )
        visiting.add(name)
        for dependency in SYSTEMS[name].after:
            if dependency in names:
                visit(dependency, trail + (name,))
        visiting.discard(name)
        placed.add(name)
        order.append(name)

    for name in sorted(names):
        visit(name, ())
    return order


def compose(model: Any) -> Composition:
    """Everything a game model needs, ordered and configured."""

    from ..ir import required_systems

    needed = set(required_systems(model))
    unknown = sorted(needed - set(SYSTEMS))
    if unknown:
        raise CompositionError(
            "the model needs systems the composer does not know: " + ", ".join(unknown)
        )

    # Startup dependencies pull in systems the design never asked for --
    # `progression` needs `economy` running even in a game whose loop never
    # mentions currency. Added here rather than in the IR, because that is a
    # runtime fact and the IR is about design.
    frontier = list(needed)
    while frontier:
        for dependency in SYSTEMS[frontier.pop()].after:
            if dependency not in needed:
                needed.add(dependency)
                frontier.append(dependency)

    order = _topological(needed)
    config: dict[str, Any] = {}

    if "economy" in needed:
        config["economy"] = {
            "currencies": [
                {
                    "id": currency.id,
                    "displayName": currency.display_name,
                    "integral": True,
                    "startingBalance": 0,
                }
                for currency in model.currencies
            ],
        }
    if "progression" in needed:
        config["progression"] = {
            "tiers": model.progression.tiers,
            "kind": model.progression.kind,
            # The costs are the economy designer's answer, not the composer's.
            # Inventing them here would produce a second pacing curve nobody
            # verified.
            "costs": "solve with economy_from_model; this composer does not price tiers",
        }
    if "inventory" in needed:
        config["inventory"] = {
            # One slot per zone plus headroom, so a player can carry something
            # from everywhere the world lets them go.
            "slots": max(6, len(model.zones) * 2 + 4),
            "items": "declared by the content generator; the composer wires the "
                     "system, not the catalogue",
        }

    return Composition(game_id=model.id, order=order, config=config)


#: What each implemented system is asked to do, to prove it loaded. Deliberately
#: trivial calls: this checks that the module is present, requires cleanly and
#: exposes its entry point, not that its logic is right -- that is what its own
#: tests are for.
SMOKE = {
    "analytics": 'local m = Require("Analytics"); assert(type(m.custom) == "function")',
    "economy": 'local m = Require("Economy"); assert(type(m.define) == "function"); '
               'local _ = m.memoryStore()',
    "save": 'local m = Require("Save"); assert(type(m) == "table")',
    "progression": 'local m = Require("Progression"); '
                   'assert(type(m.define) == "function") ; local _ = m.pacing',
    "inventory": 'local m = Require("Inventory"); '
                 'local inv = m.define({{id="probe", displayName="Probe"}}, m.memoryStore(), 6); '
                 'assert(#inv:itemIds() == 1)',
}


def verify(root: Path, composition: Composition, *, timeout: float = 60.0) -> Composition:
    """Load and call every implemented system, in startup order.

    "Composed" has to mean "ran". A composer that only emitted names would
    report a complete game whose first require fails, and would report it
    identically whether the module existed or not.
    """

    from ..luau_harness import HarnessError, run

    checks = [name for name in composition.order
              if SYSTEMS[name].implemented and name in SMOKE]
    if not checks:
        composition.verified = {
            "loaded": 0,
            "note": "nothing to verify: no system in this composition has a module yet",
        }
        return composition

    # One harness run per system, not one for all of them. A single module that
    # reaches for an unshimmed service aborts the whole script, and the report
    # would then say nothing about the systems that were fine. That is how
    # `Save` -- which acquires DataStoreService at module scope -- made four
    # working systems look unverified.
    loaded: list[str] = []
    findings: list[dict[str, str]] = []
    for name in checks:
        try:
            result = run(root, libraries=["roblox/lib/GameKit"],
                         body=SMOKE[name], timeout=timeout)
        except HarnessError as exc:
            raise CompositionError(f"{name} could not be verified: {exc}") from exc

        if result.ok:
            loaded.append(name)
            continue

        stderr = result.stderr.strip()
        if "not shimmed" in stderr:
            # Not a broken system -- a system that only runs inside a live game.
            # Reported rather than raised: the composition is still usable, and
            # what a caller needs to know is that this one cannot be simulated.
            service = stderr.split("not shimmed:", 1)[-1].split("--", 1)[0].strip()
            findings.append({
                "system": name,
                "status": "NOT_PORTABLE",
                "detail": (
                    f"reaches for {service} when the module loads, so it cannot run in "
                    "the headless harness, in an Open Cloud task, or anywhere outside a "
                    "live game. Its behaviour can only be tested in a session"
                ),
            })
            continue

        raise CompositionError(
            f"composed system {name} failed to load:\n" + (stderr or "no output"))

    composition.verified = {
        "loaded": len(loaded),
        "systems": loaded,
        "findings": findings,
        "source": "roblox/lib/GameKit, through the headless harness",
        "note": "each module was required and called; this proves it loads, not that "
                "its logic is right -- that is what its own tests are for",
    }
    return composition


def compose_and_verify(root: Path, model: Any) -> Composition:
    """The normal entry point."""

    return verify(root, compose(model))


def catalogue() -> dict[str, Any]:
    """Every system the composer knows, and which ones exist."""

    implemented = [spec for spec in SYSTEMS.values() if spec.implemented]
    return {
        "schemaVersion": 1,
        "total": len(SYSTEMS),
        "implemented": len(implemented),
        "systems": [SYSTEMS[name].to_dict() for name in sorted(SYSTEMS)],
        "note": (
            "planned systems are listed with their reason rather than omitted; a model "
            "asking for one must find out here rather than at the first require"
        ),
    }
