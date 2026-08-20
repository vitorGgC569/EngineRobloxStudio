"""Behaviour as data: when something happens, if something holds, do something.

The gap this closes. World, look, sound and interface can all be composed a
piece at a time -- `scene_place`, `material_apply`, `Audio.define`, `ui_screen`.
Behaviour could not. It arrived whole, from a genre recipe, and the only way to
change it was to edit the recipe. That is why a horror brief came out as a tower
defense wearing a horror palette: the recipe chose the game.

GameKit already holds the capabilities -- Economy, Inventory, Progression, Shop,
Onboarding, Feedback, Analytics. What was missing was a way to say *when* they
should fire. That is a small vocabulary, and it is data rather than Luau on
purpose:

    trigger    what happened            prompt, touch, timer, wave, state
    condition  what must hold           currency, attribute, count, chance
    effect     what to do               spend, grant, spawn, play, announce...

**Data, not code, for three reasons.** It can be validated before anything is
installed, so a rule naming a currency the economy does not have is refused at
authoring time instead of erroring in a live game. It can be diffed, so a change
to behaviour reads as a change. And it can be written by a caller who knows the
game but not Luau -- which, for this project, is the entire point.

**The vocabulary is deliberately small.** Every entry here maps onto something
GameKit already does. Adding a verb means adding a capability, and that ordering
keeps the rule surface honest: there is nothing here that only pretends to work.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable


class RuleError(ValueError):
    """A rule was written that the runtime could not honour."""


#: What can start a rule, and what each one carries into the conditions.
#:
#: `subject` is what the rule is about -- usually the player who acted. A
#: trigger with no subject cannot run a condition about currency, and saying so
#: here stops that being discovered in a running game.
TRIGGERS: dict[str, dict[str, Any]] = {
    "prompt": {
        "needs": ["target"],
        "subject": "player",
        "note": "a ProximityPrompt was held to completion by a player",
    },
    "touch": {
        "needs": ["target"],
        "subject": "player",
        "note": "a player's character touched a part",
    },
    "timer": {
        "needs": ["seconds"],
        "subject": None,
        "note": "every N seconds while the session is active",
    },
    "wave": {
        "needs": [],
        "subject": None,
        "note": "a wave began; `index` is available to conditions",
    },
    "state": {
        "needs": ["value"],
        "subject": "player",
        "note": "session state changed to a named value: ACTIVE, VICTORY, DEFEAT",
    },
    "join": {
        "needs": [],
        "subject": "player",
        "note": "a player entered the game",
    },
}

#: What may gate a rule. Each names the fact it reads, so a condition about a
#: currency that the economy never declared is a refusal rather than a silent
#: false.
CONDITIONS: dict[str, dict[str, Any]] = {
    "currency": {
        "needs": ["name"],
        "one_of": ["atLeast", "atMost"],
        "subject": "player",
        "note": "how much of a currency the subject holds",
    },
    "attribute": {
        "needs": ["name"],
        "one_of": ["equals", "atLeast", "atMost"],
        "subject": "player",
        "note": "a player attribute the server owns",
    },
    "count": {
        "needs": ["of"],
        "one_of": ["atLeast", "atMost"],
        "subject": None,
        "note": "how many of a named thing exist in the world",
    },
    "chance": {
        "needs": ["percent"],
        "one_of": [],
        "subject": None,
        "note": "fires this often; the only deliberate non-determinism here",
    },
}

#: What a rule may do. Every one is a GameKit call.
EFFECTS: dict[str, dict[str, Any]] = {
    "spend": {
        "needs": ["currency", "amount"],
        "subject": "player",
        "capability": "economy",
        "note": "take currency through the ledger, refusing if it is not there",
    },
    "grant": {
        "needs": ["currency", "amount"],
        "subject": "player",
        "capability": "economy",
        "note": "give currency through the ledger",
    },
    "spawn": {
        "needs": ["what"],
        "subject": None,
        "capability": "world",
        "note": "build a named kit thing at the trigger's location",
    },
    "destroy": {
        "needs": ["what"],
        "subject": None,
        "capability": "world",
        "note": "remove what the trigger names",
    },
    "play": {
        "needs": ["cue"],
        "subject": None,
        "capability": "audio",
        "note": "an Audio cue, at the trigger's location when it has one",
    },
    "announce": {
        "needs": ["message"],
        "subject": "player",
        "capability": "interface",
        "note": "a banner the player reads",
    },
    "setAttribute": {
        "needs": ["name", "value"],
        "subject": "player",
        "capability": "interface",
        "note": "move a number the HUD is bound to",
    },
    "damage": {
        "needs": ["amount"],
        "subject": None,
        "capability": "world",
        "note": "hurt what the trigger names, if it has health",
    },
    "chase": {
        "needs": ["who"],
        "subject": None,
        "capability": "movement",
        "note": (
            "make what `who` names walk at the nearest player, pathfinding "
            "round geometry and repathing as the player moves. Animates while "
            "it moves; pass gait:none for the sliding version"
        ),
    },
    "flee": {
        "needs": ["who"],
        "subject": None,
        "capability": "movement",
        "note": "walk away from the nearest player until `safe` studs clear",
    },
    "patrol": {
        "needs": ["who", "points"],
        "subject": None,
        "capability": "movement",
        "note": "walk a closed loop of points, ignoring players entirely",
    },
    "halt": {
        "needs": ["who"],
        "subject": None,
        "capability": "movement",
        "note": "stop whatever movement `who` was given",
    },
    "vfx": {
        "needs": ["style"],
        "subject": None,
        "capability": "world",
        "note": "a burst at the trigger's location",
    },
}


@dataclass
class Rule:
    """One behaviour: when this happens, if this holds, do these."""

    id: str
    when: dict[str, Any]
    then: list[dict[str, Any]]
    require: list[dict[str, Any]] = field(default_factory=list)
    once: bool = False
    note: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "when": self.when,
            "require": self.require,
            "then": self.then,
            "once": self.once,
            "note": self.note,
        }


def vocabulary() -> dict[str, Any]:
    """Everything a rule may say, with what each entry needs."""

    return {
        "schemaVersion": 1,
        "triggers": TRIGGERS,
        "conditions": CONDITIONS,
        "effects": EFFECTS,
        "note": (
            "every effect maps onto a GameKit capability that already exists; "
            "adding a verb here means adding a capability first"
        ),
    }


def _missing(spec: dict[str, Any], given: dict[str, Any], kind: str,
             name: str) -> list[str]:
    problems = []
    for field_name in spec.get("needs", []):
        if field_name not in given:
            problems.append(
                f"{kind} {name!r} needs {field_name!r}; got "
                + (", ".join(sorted(k for k in given if k != "kind")) or "nothing"))
    choices = spec.get("one_of") or []
    if choices and not any(choice in given for choice in choices):
        problems.append(
            f"{kind} {name!r} needs one of {', '.join(choices)}")
    return problems


def problems(rule: Rule, *, currencies: Iterable[str] = (),
             cues: Iterable[str] = ()) -> list[str]:
    """Everything wrong with a rule, before it can reach a running game.

    Checked against what the game actually has where that is knowable: a rule
    spending `gold` in a game whose economy declares `cash` is the kind of thing
    that reads fine and fails silently on the one path nobody tested.
    """

    found: list[str] = []
    currencies = set(currencies)
    cues = set(cues)

    trigger_kind = str(rule.when.get("kind") or "")
    trigger = TRIGGERS.get(trigger_kind)
    if trigger is None:
        return [f"unknown trigger {trigger_kind!r}; known: "
                + ", ".join(sorted(TRIGGERS))]
    found += _missing(trigger, rule.when, "trigger", trigger_kind)

    has_subject = trigger.get("subject") is not None

    for condition in rule.require:
        kind = str(condition.get("kind") or "")
        spec = CONDITIONS.get(kind)
        if spec is None:
            found.append(f"unknown condition {kind!r}; known: "
                         + ", ".join(sorted(CONDITIONS)))
            continue
        found += _missing(spec, condition, "condition", kind)
        if spec.get("subject") == "player" and not has_subject:
            found.append(
                f"condition {kind!r} is about a player, but trigger "
                f"{trigger_kind!r} has none")
        if kind == "currency" and currencies:
            name = str(condition.get("name") or "")
            if name and name not in currencies:
                found.append(
                    f"condition names currency {name!r}; this game has "
                    + ", ".join(sorted(currencies)))

    if not rule.then:
        found.append("a rule with no effect is a rule that does nothing")

    for effect in rule.then:
        kind = str(effect.get("kind") or "")
        spec = EFFECTS.get(kind)
        if spec is None:
            found.append(f"unknown effect {kind!r}; known: "
                         + ", ".join(sorted(EFFECTS)))
            continue
        found += _missing(spec, effect, "effect", kind)
        if spec.get("subject") == "player" and not has_subject:
            found.append(
                f"effect {kind!r} is about a player, but trigger "
                f"{trigger_kind!r} has none")
        if kind in ("spend", "grant") and currencies:
            name = str(effect.get("currency") or "")
            if name and name not in currencies:
                found.append(
                    f"effect {kind} names currency {name!r}; this game has "
                    + ", ".join(sorted(currencies)))
        if kind == "play" and cues:
            cue = str(effect.get("cue") or "")
            if cue and cue not in cues:
                found.append(
                    f"effect play names cue {cue!r}; this game has "
                    + ", ".join(sorted(cues)))

    return found


def compile_rules(rules: Iterable[Rule], *, currencies: Iterable[str] = (),
                  cues: Iterable[str] = ()) -> dict[str, Any]:
    """Validate a set of rules and return what the runtime should install.

    Refuses the whole set rather than the bad rule. A half-installed behaviour
    is worse than none: the game runs, most of it works, and the missing piece
    looks like a design choice.
    """

    rules = list(rules)
    seen: set[str] = set()
    all_problems: list[str] = []
    for rule in rules:
        if rule.id in seen:
            all_problems.append(f"duplicate rule id {rule.id!r}")
        seen.add(rule.id)
        all_problems += [f"{rule.id}: {item}"
                         for item in problems(rule, currencies=currencies, cues=cues)]

    if all_problems:
        raise RuleError(
            "these rules cannot be installed: " + "; ".join(all_problems))

    return {
        "schemaVersion": 1,
        "rules": [rule.to_dict() for rule in rules],
        "capabilities": sorted({
            EFFECTS[str(effect.get("kind"))]["capability"]
            for rule in rules for effect in rule.then
            if str(effect.get("kind")) in EFFECTS
        }),
    }


def from_dicts(entries: Iterable[dict[str, Any]]) -> list[Rule]:
    """Build rules from plain data, as a tool call delivers them."""

    out = []
    for entry in entries:
        if "id" not in entry or "when" not in entry:
            raise RuleError(f"a rule needs an id and a when: {entry!r}")
        out.append(Rule(
            id=str(entry["id"]),
            when=dict(entry["when"]),
            then=[dict(item) for item in entry.get("then", [])],
            require=[dict(item) for item in entry.get("require", [])],
            once=bool(entry.get("once")),
            note=str(entry.get("note") or ""),
        ))
    return out
