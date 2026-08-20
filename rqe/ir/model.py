"""The Game IR: what a game *is*, before anything decides how to build it.

Today an agent authors a `product-intent.json` and a blueprint project entry
side by side, and nothing checks that they agree. The intent says the loop is
"collect, process, upgrade"; the blueprint lists three subsystems and two asset
needs; whether those are the same game is a matter of whoever read both.

This is the layer above. A `GameModel` states the game in the terms a designer
would use -- genre, theme, core loop, world topology and zones, progression,
currencies, systems, monetization -- and everything downstream is *derived* from
it rather than authored beside it. The blueprint stops being a second
description that can disagree with the first.

What earns it its place is not the vocabulary, which is the easy part. It is
that a model can be **internally wrong** in ways no single file could show:

- a loop verb with no system that implements it
- a currency nothing earns, or nothing spends
- monetization on a currency that does not exist
- progression tiers with no economy to fund them
- zones the topology has no room for
- a system requiring another system nobody declared

Every one of those ships a game that builds cleanly and does not work, and every
one is decidable from the model alone, in milliseconds, before a task graph is
compiled or a single Part exists.

The IR does not invent anything. `compile` derives a production blueprint from a
model; deciding what the model should *say* is the design compiler's job, one
layer up, and keeping the two apart is what stops a generated game from being
graded against a spec that was generated to fit it.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping


class GameModelError(ValueError):
    """The model is malformed. Structure, not design judgement."""


#: Genres the engine has a production path for. A genre with no recipe compiles
#: to a blueprint nothing knows how to execute, so it is refused at the door
#: rather than three layers down.
GENRES = ("tycoon", "simulator", "tower_defense", "roguelite", "collection", "survival", "racing")

#: World shapes. Each implies a different blockout grammar and a different set
#: of scenario classes, which is why it is a typed field rather than prose.
TOPOLOGIES = ("hub_and_zones", "single_arena", "grid_plots", "open_world", "linear_levels")

PROGRESSION_KINDS = ("tiered", "unlock_graph", "endless", "wave", "checkpoint")

#: Progressions whose tiers are *bought*. Only these need an economy behind
#: them: a wave is survived and a checkpoint is reached, and demanding a currency
#: for either is a rule about tycoons applied to games that are not one. Found by
#: applying every genre recipe -- roguelite and tower defense both tripped it.
PURCHASED_PROGRESSIONS = ("tiered", "unlock_graph")

#: Systems the composer can assemble. The value is what the system needs from
#: the model, checked below -- a system that silently accepts a model missing
#: what it needs is how a shop ships with nothing to sell.
SYSTEM_REQUIREMENTS: dict[str, tuple[str, ...]] = {
    "economy": ("currencies",),
    "progression": ("progression",),
    "save": (),
    "analytics": (),
    "inventory": (),
    "shop": ("currencies",),
    "quests": (),
    "crafting": ("inventory",),
    "trading": ("inventory",),
    "pets": ("inventory",),
    "gacha": ("currencies", "inventory"),
    "tower": (),
    "offline_income": ("currencies", "economy"),
    "tutorial": (),
    "leaderboard": (),
}

#: Loop verbs, and the system each one needs to actually happen. A loop is the
#: game's promise to the player; a verb with nothing behind it is the promise
#: being broken in a way that builds and passes every structural check.
LOOP_VERB_SYSTEMS: dict[str, tuple[str, ...]] = {
    "explore": (),
    "collect": ("inventory",),
    "process": ("economy",),
    "craft": ("crafting",),
    "upgrade": ("economy", "progression"),
    "unlock": ("progression",),
    "sell": ("economy",),
    "buy": ("shop", "economy"),
    "build": ("economy",),
    "fight": (),
    "defend": ("tower",),
    "trade": ("trading",),
    "quest": ("quests",),
    "pull": ("gacha",),
    "prestige": ("progression",),
    "race": (),
    "survive": (),
}

MONETIZATION_KINDS = ("cosmetics", "boosts", "passes", "currency_packs", "battle_pass")

_ID = re.compile(r"^[a-z][a-z0-9_-]*$")


def _identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or not _ID.match(value):
        raise GameModelError(
            f"{label} must be a lowercase identifier (letters, digits, - and _); got {value!r}"
        )
    return value


@dataclass(frozen=True)
class Currency:
    id: str
    display_name: str
    #: What produces it. A currency nothing earns cannot be spent, and a shop
    #: priced in it is a shop nobody can use.
    earned_by: tuple[str, ...] = ()
    #: What consumes it. A currency nothing spends is a number that goes up,
    #: which players read as a bug rather than as progress.
    spent_on: tuple[str, ...] = ()
    premium: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id, "displayName": self.display_name,
            "earnedBy": list(self.earned_by), "spentOn": list(self.spent_on),
            "premium": self.premium,
        }


@dataclass(frozen=True)
class Zone:
    id: str
    theme: str
    difficulty: int = 1
    unlocked_at_tier: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id, "theme": self.theme, "difficulty": self.difficulty,
            "unlockedAtTier": self.unlocked_at_tier,
        }


@dataclass(frozen=True)
class Progression:
    kind: str
    tiers: int = 0
    #: Seconds the designer intends the first tier to take. Carried in the model
    #: because it is a *design* decision, and it is what the economy designer
    #: solves the cost curve against.
    first_tier_seconds: float = 0.0
    session_minutes: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind, "tiers": self.tiers,
            "firstTierSeconds": self.first_tier_seconds,
            "sessionMinutes": self.session_minutes,
        }


@dataclass
class GameModel:
    """A whole game, stated once."""

    id: str
    genre: str
    theme: str
    pitch: str
    core_loop: tuple[str, ...]
    topology: str
    progression: Progression
    currencies: tuple[Currency, ...] = ()
    zones: tuple[Zone, ...] = ()
    systems: tuple[str, ...] = ()
    monetization: tuple[str, ...] = ()
    token_set: str = ""
    concurrent_players: int = 1
    private_space: bool = False

    # -- structure -------------------------------------------------------

    def __post_init__(self) -> None:
        _identifier(self.id, "game id")
        if self.genre not in GENRES:
            raise GameModelError(
                f"genre {self.genre!r} has no production path; known genres: "
                + ", ".join(GENRES)
            )
        if self.topology not in TOPOLOGIES:
            raise GameModelError(
                f"topology {self.topology!r} is not one the blockout grammar knows: "
                + ", ".join(TOPOLOGIES)
            )
        if self.progression.kind not in PROGRESSION_KINDS:
            raise GameModelError(
                f"progression kind {self.progression.kind!r} is not one of: "
                + ", ".join(PROGRESSION_KINDS)
            )
        if not self.pitch.strip():
            raise GameModelError("a game needs a pitch; it is what every later choice is judged against")
        if not self.core_loop:
            raise GameModelError("a game with no core loop is not a game")

        for verb in self.core_loop:
            if verb not in LOOP_VERB_SYSTEMS:
                raise GameModelError(
                    f"core loop verb {verb!r} is not one the engine can build; known verbs: "
                    + ", ".join(sorted(LOOP_VERB_SYSTEMS))
                )
        for system in self.systems:
            if system not in SYSTEM_REQUIREMENTS:
                raise GameModelError(
                    f"system {system!r} has no implementation; known systems: "
                    + ", ".join(sorted(SYSTEM_REQUIREMENTS))
                )
        for kind in self.monetization:
            if kind not in MONETIZATION_KINDS:
                raise GameModelError(
                    f"monetization {kind!r} is not one of: " + ", ".join(MONETIZATION_KINDS)
                )

        seen: set[str] = set()
        for currency in self.currencies:
            _identifier(currency.id, "currency id")
            if currency.id in seen:
                raise GameModelError(f"currency {currency.id!r} is declared twice")
            seen.add(currency.id)

        zone_ids: set[str] = set()
        for zone in self.zones:
            _identifier(zone.id, "zone id")
            if zone.id in zone_ids:
                raise GameModelError(f"zone {zone.id!r} is declared twice")
            zone_ids.add(zone.id)

    # -- coherence -------------------------------------------------------

    def problems(self) -> list[str]:
        """Ways this game is internally inconsistent.

        Separate from `__post_init__` on purpose. Malformed is a typo and stops
        everything; incoherent is a design that parses, compiles, builds and
        does not work -- and that one deserves the whole list at once rather
        than the first item, because fixing them one exception at a time is how
        a model takes six passes to become playable.
        """

        found: list[str] = []
        systems = set(self.systems)
        currency_ids = {currency.id for currency in self.currencies}

        # A loop verb with nothing behind it.
        for verb in self.core_loop:
            for required in LOOP_VERB_SYSTEMS[verb]:
                if required not in systems:
                    found.append(
                        f"the core loop promises {verb!r} but no {required!r} system is "
                        f"declared; the loop would build and the player could not do it"
                    )

        # A system whose own dependency is missing.
        for system in sorted(systems):
            for required in SYSTEM_REQUIREMENTS[system]:
                if required in SYSTEM_REQUIREMENTS and required not in systems:
                    found.append(
                        f"system {system!r} needs {required!r}, which is not declared"
                    )
                elif required == "currencies" and not self.currencies:
                    found.append(
                        f"system {system!r} needs at least one currency and none is declared"
                    )
                elif required == "progression" and self.progression.tiers <= 0:
                    found.append(
                        f"system {system!r} needs a progression with tiers; the model declares "
                        f"{self.progression.tiers}"
                    )

        # A currency that only goes one way.
        for currency in self.currencies:
            if not currency.earned_by:
                found.append(
                    f"currency {currency.id!r} is spent but never earned; a price nobody can "
                    "pay is a locked door with no key"
                )
            if not currency.spent_on:
                found.append(
                    f"currency {currency.id!r} is earned but never spent; a number that only "
                    "goes up reads to a player as a bug rather than as progress"
                )

        # Monetization with nothing behind it.
        if self.monetization and not currency_ids:
            found.append(
                "monetization is declared with no currency to sell; a purchase needs "
                "something to grant"
            )
        if "currency_packs" in self.monetization and not any(c.premium for c in self.currencies):
            found.append(
                "currency_packs are declared but no currency is marked premium, so a pack "
                "would grant something the player can already farm"
            )

        # Progression nothing funds -- but only where tiers are bought.
        purchased = self.progression.kind in PURCHASED_PROGRESSIONS
        if purchased and self.progression.tiers > 0 and "economy" not in systems:
            found.append(
                f"progression declares {self.progression.tiers} purchased tiers with no "
                "economy system to fund them; the ladder would exist and nothing would "
                "climb it"
            )
        if purchased and self.progression.tiers > 0 and not self.currencies:
            found.append(
                "progression declares purchased tiers with no currency to price them in")

        # Zones the topology cannot hold.
        if self.zones and self.topology in ("single_arena", "grid_plots"):
            found.append(
                f"{len(self.zones)} zones are declared under the {self.topology!r} topology, "
                "which has no place to put them"
            )
        if self.topology == "hub_and_zones" and not self.zones:
            found.append("the hub_and_zones topology needs zones and the model declares none")

        # A zone gated behind a tier that does not exist.
        for zone in self.zones:
            if zone.unlocked_at_tier > self.progression.tiers:
                found.append(
                    f"zone {zone.id!r} unlocks at tier {zone.unlocked_at_tier}, above the "
                    f"{self.progression.tiers} the ladder has; it would never open"
                )

        # Persistence, which is invisible until the second session.
        if self.progression.tiers > 0 and "save" not in systems:
            found.append(
                "progression is declared with no save system; every player would restart "
                "from zero, and nothing in a first session would show it"
            )

        return found

    @property
    def coherent(self) -> bool:
        return not self.problems()

    # -- identity --------------------------------------------------------

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "id": self.id,
            "genre": self.genre,
            "theme": self.theme,
            "pitch": self.pitch,
            "coreLoop": list(self.core_loop),
            "world": {
                "topology": self.topology,
                "zones": [zone.to_dict() for zone in self.zones],
            },
            "progression": self.progression.to_dict(),
            "economy": {"currencies": [c.to_dict() for c in self.currencies]},
            "systems": list(self.systems),
            "monetization": list(self.monetization),
            "tokenSet": self.token_set,
            "concurrentPlayers": self.concurrent_players,
            "privateSpace": self.private_space,
        }

    @property
    def sha256(self) -> str:
        return hashlib.sha256(
            json.dumps(self.to_dict(), sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

    def summary(self) -> str:
        problems = self.problems()
        head = (
            f"{'COHERENT' if not problems else 'INCOHERENT'}  {self.id} "
            f"({self.genre}/{self.theme}) loop: {' -> '.join(self.core_loop)}"
        )
        lines = [head, f"  {len(self.systems)} systems, {len(self.currencies)} currencies, "
                       f"{len(self.zones)} zones, {self.progression.tiers} tiers"]
        for problem in problems:
            lines.append(f"  problem: {problem}")
        return "\n".join(lines)


def load_model(document: Mapping[str, Any]) -> GameModel:
    """Build a model from the shape an agent authors."""

    if not isinstance(document, Mapping):
        raise GameModelError("a game model must be an object")

    world = document.get("world") or {}
    economy = document.get("economy") or {}
    progression = document.get("progression") or {}

    try:
        return GameModel(
            id=str(document.get("id", "")),
            genre=str(document.get("genre", "")),
            theme=str(document.get("theme", "")),
            pitch=str(document.get("pitch", "")),
            core_loop=tuple(str(v) for v in document.get("coreLoop", ())),
            topology=str(world.get("topology", "")),
            zones=tuple(
                Zone(
                    id=str(z["id"]), theme=str(z.get("theme", "")),
                    difficulty=int(z.get("difficulty", 1)),
                    unlocked_at_tier=int(z.get("unlockedAtTier", 0)),
                )
                for z in world.get("zones", ())
            ),
            progression=Progression(
                kind=str(progression.get("kind", "")),
                tiers=int(progression.get("tiers", 0)),
                first_tier_seconds=float(progression.get("firstTierSeconds", 0.0)),
                session_minutes=float(progression.get("sessionMinutes", 0.0)),
            ),
            currencies=tuple(
                Currency(
                    id=str(c["id"]), display_name=str(c.get("displayName", c["id"])),
                    earned_by=tuple(str(v) for v in c.get("earnedBy", ())),
                    spent_on=tuple(str(v) for v in c.get("spentOn", ())),
                    premium=bool(c.get("premium", False)),
                )
                for c in economy.get("currencies", ())
            ),
            systems=tuple(str(v) for v in document.get("systems", ())),
            monetization=tuple(str(v) for v in document.get("monetization", ())),
            token_set=str(document.get("tokenSet", "")),
            concurrent_players=int(document.get("concurrentPlayers", 1)),
            private_space=bool(document.get("privateSpace", False)),
        )
    except (KeyError, TypeError, ValueError) as exc:
        if isinstance(exc, GameModelError):
            raise
        raise GameModelError(f"the model is malformed: {exc}") from exc


def required_systems(model: GameModel) -> list[str]:
    """Every system the model implies, including transitive dependencies.

    What the composer would have to assemble. Reported so a model can be told
    what it is missing rather than merely that something is.
    """

    needed: set[str] = set(model.systems)
    for verb in model.core_loop:
        needed.update(LOOP_VERB_SYSTEMS[verb])

    frontier = list(needed)
    while frontier:
        system = frontier.pop()
        for dependency in SYSTEM_REQUIREMENTS.get(system, ()):
            if dependency in SYSTEM_REQUIREMENTS and dependency not in needed:
                needed.add(dependency)
                frontier.append(dependency)
    return sorted(needed)
