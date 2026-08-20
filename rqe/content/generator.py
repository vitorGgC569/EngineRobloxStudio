"""Content generation: a whole catalogue, coherently, from a family declaration.

A game is not only systems. It needs a hundred items, thirty upgrades, twenty
enemies across eight tiers, drop tables, rarities -- and the failure mode is not
that generating them is hard. It is that generating them *by hand or by prompt*
produces a catalogue that is quietly incoherent: a tier-5 enemy weaker than a
tier-4, a rarity nobody can ever roll, a support variant strictly worse than
every other in its tier, a drop table summing to 0.97.

None of those crash. All of them are felt.

So the pipeline the document asks for is the whole point:

    ContentSchema -> generate -> consistency -> balance -> runtime catalogue

`generate` is deterministic from a seed, using the same FNV-1a hash the SDK's
`Kit.seedFor` uses, so a catalogue is reproducible and a change to it is a change
somebody made. `consistency` asks whether the catalogue is well-formed. `balance`
asks the harder question -- whether it is *fair* -- and it is the one that earns
this module its place, because a well-formed unfair catalogue passes every other
check in the engine.

Nothing here invents a theme. Names come from the theme the schema states,
composed from its own vocabulary; a generator that reached for a word list would
produce a catalogue that reads like a different game's.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence


class ContentError(ValueError):
    """The catalogue could not be generated, and the message says why."""


#: The kinds of content the generator knows how to shape. Each has a different
#: notion of what "stronger" means, which is what the balance validator checks.
KINDS = ("enemy", "item", "upgrade", "collectible", "quest")

#: Roles inside a family. A tier is not one thing -- it is a set of answers to
#: the same difficulty, and a role missing from a tier is a strategy that stops
#: working at that point in the game for no stated reason.
ROLES = ("melee", "ranged", "tank", "support", "utility")

#: Rarities, and the share of drops each should take. Ordered rarest-last so a
#: table can be built by walking it.
RARITIES = ("common", "uncommon", "rare", "epic", "legendary")
RARITY_WEIGHTS = (0.55, 0.27, 0.125, 0.045, 0.01)

#: Below this a rarity is unreachable in a normal session: at 1-in-10,000 with
#: one roll a minute, half of players never see it in fifty hours. A tier of
#: content nobody sees is content nobody made.
MIN_RARITY_SHARE = 1e-4

#: How much stronger each tier must be than the one before it. Below the floor
#: the ladder does not read as progress; above the ceiling a tier invalidates
#: everything earned before it.
TIER_POWER_BAND = (1.15, 2.5)

FNV_OFFSET = 2166136261
FNV_PRIME = 16777619
WORD = 4294967296


def _seed(*parts: Any) -> int:
    """The SDK's hash, so a catalogue seed behaves like a placement seed.

    Same construction as `Kit.seedFor` and `rqe/world/composition.py`: a third
    hash in a third place is a third thing to keep in step.
    """

    value = FNV_OFFSET
    for part in parts:
        for character in str(part):
            value ^= ord(character) % WORD
            value = (value * FNV_PRIME) % WORD
    return value


def _unit(seed: int, salt: int = 0) -> float:
    value = (seed ^ (salt * 0x9E3779B1)) % WORD
    value = (value * 1103515245 + 12345) % 0x7FFFFFFF
    return value / 0x7FFFFFFF


@dataclass(frozen=True)
class ContentSchema:
    """A family of content, declared rather than enumerated."""

    id: str
    kind: str
    theme: str
    tiers: int
    variants_per_tier: int = 1
    roles: tuple[str, ...] = ()
    #: Multiplier per tier. The designer's statement of how much a tier is
    #: worth; the balance validator checks the result against it.
    power_step: float = 1.4
    base_power: float = 10.0
    seed: int = 0

    def __post_init__(self) -> None:
        if self.kind not in KINDS:
            raise ContentError(f"kind must be one of {', '.join(KINDS)}; got {self.kind!r}")
        if not 1 <= self.tiers <= 40:
            raise ContentError("a family needs between 1 and 40 tiers")
        if not 1 <= self.variants_per_tier <= 12:
            raise ContentError("a tier holds between 1 and 12 variants")
        if not self.theme.strip():
            raise ContentError(
                "a family needs a theme; names are composed from it, and a themeless "
                "family reads like a different game's content"
            )
        for role in self.roles:
            if role not in ROLES:
                raise ContentError(
                    f"unknown role {role!r}; known roles: {', '.join(ROLES)}")
        if self.roles and len(self.roles) > self.variants_per_tier:
            raise ContentError(
                f"{len(self.roles)} roles will not fit in {self.variants_per_tier} "
                "variants per tier; some role would be missing from every tier, which "
                "is a strategy that stops working for no stated reason"
            )
        if not TIER_POWER_BAND[0] <= self.power_step <= TIER_POWER_BAND[1]:
            raise ContentError(
                f"power_step {self.power_step} is outside {TIER_POWER_BAND}; below the "
                "floor the ladder does not read as progress, above the ceiling a tier "
                "invalidates everything earned before it"
            )


@dataclass(frozen=True)
class Entry:
    """One piece of content."""

    id: str
    name: str
    kind: str
    tier: int
    role: str
    power: float
    rarity: str
    stats: dict[str, float] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id, "name": self.name, "kind": self.kind,
            "tier": self.tier, "role": self.role,
            "power": round(self.power, 2), "rarity": self.rarity,
            "stats": {key: round(value, 2) for key, value in self.stats.items()},
        }


#: Per-role stat shapes, as fractions of the entry's power budget.
#:
#: The whole budget is spent in every case, so no role is strictly worse than
#: another -- it is differently shaped. A role that spent less would be a strictly
#: dominated choice, which is the balance failure this table exists to avoid.
ROLE_SHAPE = {
    "melee":   {"attack": 0.45, "health": 0.35, "speed": 0.20},
    "ranged":  {"attack": 0.50, "health": 0.20, "range": 0.30},
    "tank":    {"attack": 0.20, "health": 0.60, "armour": 0.20},
    "support": {"attack": 0.15, "health": 0.30, "aura": 0.55},
    "utility": {"attack": 0.25, "health": 0.25, "range": 0.25, "speed": 0.25},
}

#: Name fragments per role. Composed with the theme rather than drawn from a
#: word list, so "corrupted robot" produces "Corrupted Robot Vanguard" and not
#: something from another game.
ROLE_TITLE = {
    "melee": ("Vanguard", "Breaker", "Striker"),
    "ranged": ("Marksman", "Seeker", "Lancer"),
    "tank": ("Bulwark", "Warden", "Colossus"),
    "support": ("Beacon", "Mender", "Chorus"),
    "utility": ("Scout", "Tinker", "Drifter"),
}

TIER_PREFIX = ("Lesser", "", "Greater", "Elder", "Prime", "Apex")

#: Appended when a family has more tiers than there are prefixes. Two entries a
#: player cannot tell apart are one entry as far as they are concerned, so names
#: are unique by construction rather than by luck -- an eight-tier family with a
#: six-prefix list collided on every role at tiers 6, 7 and 8, and the
#: consistency check caught it on the first run.
TIER_MARK = ("", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X")


def _title(theme: str, role: str, tier: int, seed: int) -> str:
    words = [word.capitalize() for word in theme.replace("_", " ").split()]
    titles = ROLE_TITLE.get(role, ("Form",))
    title = titles[int(_unit(seed, 3) * len(titles)) % len(titles)]

    index = min(tier - 1, len(TIER_PREFIX) - 1)
    prefix = TIER_PREFIX[index]
    # Past the prefix list, tiers are marked instead of sharing a prefix.
    overflow = (tier - 1) - index
    mark = TIER_MARK[min(overflow, len(TIER_MARK) - 1)] if overflow else ""

    parts = ([prefix] if prefix else []) + words + [title] + ([mark] if mark else [])
    return " ".join(parts)


def _rarity_for(tier: int, tiers: int, seed: int) -> str:
    """Rarity rises with tier, but never becomes certain.

    A top tier that is always legendary makes rarity meaningless there; a bottom
    tier that can never exceed common makes the early game feel like nothing
    good exists.
    """

    position = (tier - 1) / max(tiers - 1, 1)
    draw = _unit(seed, 5)
    # Bias the draw upward with tier, keeping the whole range reachable.
    biased = min(draw * (0.55 + position * 0.9), 0.999)
    running = 0.0
    for rarity, weight in zip(RARITIES, RARITY_WEIGHTS):
        running += weight
        if biased <= running:
            return rarity
    return RARITIES[-1]


@dataclass
class Catalogue:
    """Generated content, with everything needed to reproduce and judge it."""

    schema: ContentSchema
    entries: list[Entry] = field(default_factory=list)

    def by_tier(self) -> dict[int, list[Entry]]:
        grouped: dict[int, list[Entry]] = {}
        for entry in self.entries:
            grouped.setdefault(entry.tier, []).append(entry)
        return grouped

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "familyId": self.schema.id,
            "kind": self.schema.kind,
            "theme": self.schema.theme,
            "tiers": self.schema.tiers,
            "count": len(self.entries),
            "seed": self.schema.seed,
            "entries": [entry.to_dict() for entry in self.entries],
            "note": (
                "generated deterministically from the schema and seed; the same inputs "
                "always produce this catalogue, so a difference is a change somebody made"
            ),
        }


def generate(schema: ContentSchema) -> Catalogue:
    """The whole family, deterministically."""

    entries: list[Entry] = []
    used_names: set[str] = set()
    roles = schema.roles or ("utility",)

    for tier in range(1, schema.tiers + 1):
        tier_power = schema.base_power * (schema.power_step ** (tier - 1))
        for index in range(schema.variants_per_tier):
            # Roles cycle so every tier covers every role before repeating one.
            role = roles[index % len(roles)]
            seed = _seed(schema.id, schema.seed, tier, index, role)

            # Variation within a tier, bounded. Wide enough that variants are not
            # the same thing renamed, narrow enough that a variant never reaches
            # the tier above -- which would make the ladder meaningless.
            spread = 0.92 + _unit(seed, 1) * 0.16
            power = tier_power * spread

            shape = ROLE_SHAPE.get(role, ROLE_SHAPE["utility"])
            name = _title(schema.theme, role, tier, seed)
            if name in used_names:
                # Deterministic disambiguation. Two variants of one role in one
                # tier can draw the same title, and a name collision is
                # indistinguishable to a player from a duplicate entry.
                suffix = 2
                while f"{name} {suffix}" in used_names:
                    suffix += 1
                name = f"{name} {suffix}"
            used_names.add(name)

            entries.append(Entry(
                id=f"{schema.id}_t{tier}_{role}_{index + 1}",
                name=name,
                kind=schema.kind,
                tier=tier,
                role=role,
                power=power,
                rarity=_rarity_for(tier, schema.tiers, seed),
                stats={key: power * fraction for key, fraction in shape.items()},
            ))

    return Catalogue(schema=schema, entries=entries)


# ------------------------------------------------------------- consistency


def consistency(catalogue: Catalogue) -> list[dict[str, str]]:
    """Is the catalogue well-formed.

    Cheap structural facts. Each of these breaks a runtime lookup rather than a
    play session, which is why they are separated from balance.
    """

    found: list[dict[str, str]] = []

    def add(rule: str, message: str) -> None:
        found.append({"rule": rule, "message": message})

    ids = [entry.id for entry in catalogue.entries]
    duplicates = sorted({item for item in ids if ids.count(item) > 1})
    if duplicates:
        add("duplicate-id",
            f"{len(duplicates)} ids appear more than once ({', '.join(duplicates[:3])}); "
            "a runtime catalogue keyed by id would silently lose one of each pair")

    names = [entry.name for entry in catalogue.entries]
    repeated = sorted({item for item in names if names.count(item) > 1})
    if repeated:
        add("duplicate-name",
            f"{len(repeated)} names are shared ({', '.join(repeated[:3])}); two things a "
            "player cannot tell apart are one thing as far as they are concerned")

    grouped = catalogue.by_tier()
    for tier in range(1, catalogue.schema.tiers + 1):
        if tier not in grouped:
            add("empty-tier", f"tier {tier} has no content; the ladder has a hole in it")

    if catalogue.schema.roles:
        for tier, entries in sorted(grouped.items()):
            present = {entry.role for entry in entries}
            missing = sorted(set(catalogue.schema.roles) - present)
            if missing:
                add("role-gap",
                    f"tier {tier} has no {', '.join(missing)}; that strategy stops "
                    "working at this point in the game for no stated reason")

    return found


# ----------------------------------------------------------------- balance


def balance(catalogue: Catalogue) -> list[dict[str, str]]:
    """Is the catalogue *fair*.

    The question this module exists for. A well-formed unfair catalogue passes
    every other check in the engine and is felt by every player.
    """

    found: list[dict[str, str]] = []

    def add(rule: str, message: str) -> None:
        found.append({"rule": rule, "message": message})

    grouped = catalogue.by_tier()
    tiers = sorted(grouped)

    # A tier that is not stronger than the one before it.
    for previous, current in zip(tiers, tiers[1:]):
        before = max(entry.power for entry in grouped[previous])
        after = max(entry.power for entry in grouped[current])
        if after <= before:
            add("tier-not-stronger",
                f"the best of tier {current} ({after:.0f}) is no stronger than the best "
                f"of tier {previous} ({before:.0f}); the player climbs and gets nothing")
            continue
        ratio = after / before
        if ratio > TIER_POWER_BAND[1]:
            add("tier-invalidates-previous",
                f"tier {current} is {ratio:.1f}x tier {previous}; everything earned "
                "before it becomes worthless in one step")

    # A variant that reaches into the tier above.
    for previous, current in zip(tiers, tiers[1:]):
        overlap = [
            entry.id for entry in grouped[previous]
            if entry.power >= min(other.power for other in grouped[current])
        ]
        if overlap:
            add("tier-overlap",
                f"{len(overlap)} of tier {previous} match or beat the weakest of tier "
                f"{current} ({overlap[0]}); the tiers are not distinguishable in play")

    # A role strictly dominated inside its tier: worse at everything.
    for tier, entries in sorted(grouped.items()):
        for entry in entries:
            for other in entries:
                if other.id == entry.id or other.role == entry.role:
                    continue
                shared = set(entry.stats) & set(other.stats)
                if not shared:
                    continue
                if all(other.stats[key] > entry.stats[key] for key in shared) and \
                        set(entry.stats) <= set(other.stats):
                    add("dominated-variant",
                        f"{entry.id} is worse than {other.id} at everything they share "
                        "and has nothing the other lacks; nobody would ever pick it")
                    break

    # A rarity nobody can roll.
    counts: dict[str, int] = {}
    for entry in catalogue.entries:
        counts[entry.rarity] = counts.get(entry.rarity, 0) + 1
    total = len(catalogue.entries) or 1
    for rarity in RARITIES:
        share = counts.get(rarity, 0) / total
        if 0 < share < MIN_RARITY_SHARE:
            add("rarity-unreachable",
                f"{rarity} is {share:.4%} of the catalogue, below the {MIN_RARITY_SHARE:.2%} "
                "a player meets in a normal session; content nobody sees is content "
                "nobody made")

    if len(counts) == 1 and len(catalogue.entries) > 4:
        add("rarity-flat",
            f"every entry is {next(iter(counts))}; rarity is declared and means nothing")

    return found


def drop_table(catalogue: Catalogue, *, tier: int) -> dict[str, Any]:
    """A drop table for one tier, summing to exactly one.

    Built by normalising the rarity weights of what is actually in the tier. A
    hand-written table sums to 0.97 and the missing 3% silently becomes whatever
    the last branch returns.
    """

    entries = catalogue.by_tier().get(tier, [])
    if not entries:
        raise ContentError(f"tier {tier} has no content to drop")

    weights = {
        entry.id: RARITY_WEIGHTS[RARITIES.index(entry.rarity)]
        for entry in entries
    }
    total = sum(weights.values())
    table = {entry_id: weight / total for entry_id, weight in weights.items()}

    # Correct the last entry so the table sums to exactly 1.0. Floating point
    # leaves a residue, and a residue is the branch nobody wrote.
    keys = sorted(table)
    residue = 1.0 - sum(table[key] for key in keys)
    table[keys[-1]] += residue

    return {
        "schemaVersion": 1,
        "tier": tier,
        "entries": {key: round(table[key], 6) for key in keys},
        "sum": round(sum(table.values()), 9),
        "note": (
            "normalised from the rarities actually present in the tier, and closed to "
            "exactly 1.0; a table summing to 0.97 hands the remainder to whichever "
            "branch happens to be last"
        ),
    }


def build(schema: ContentSchema) -> dict[str, Any]:
    """The whole pipeline: generate, check, and report."""

    catalogue = generate(schema)
    structural = consistency(catalogue)
    fairness = balance(catalogue)
    return {
        "schemaVersion": 1,
        "ok": not structural and not fairness,
        "catalogue": catalogue.to_dict(),
        "consistency": structural,
        "balance": fairness,
        "summary": (
            f"{'OK' if not structural and not fairness else 'PROBLEMS'}  "
            f"{schema.id}: {len(catalogue.entries)} entries across {schema.tiers} tiers, "
            f"{len(structural)} consistency and {len(fairness)} balance problems"
        ),
    }


def from_model(model: Any, *, kind: str = "collectible", variants_per_tier: int = 4,
               roles: Sequence[str] = ("melee", "ranged", "tank", "support")) -> ContentSchema:
    """A content schema the game model already implies.

    Tiers come from the progression ladder and the theme from the game, so a
    catalogue cannot be generated for a different number of tiers than the game
    actually has -- which is how content ends up unreachable behind a tier that
    does not exist.
    """

    if model.progression.tiers < 1:
        raise ContentError(
            f"{model.id} declares no progression tiers, so there is nothing to spread "
            "content across"
        )
    return ContentSchema(
        id=f"{model.id}-{kind}",
        kind=kind,
        theme=model.theme,
        tiers=model.progression.tiers,
        variants_per_tier=variants_per_tier,
        roles=tuple(roles),
        seed=int(model.sha256[:8], 16) % 1_000_000,
    )
