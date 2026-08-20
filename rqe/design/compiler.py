"""The design compiler: a sentence in, a whole game design out.

    "Tycoon de laboratório submarino com exploração, coleta de criaturas e
     automação."

becomes a genre, a core loop, currencies, a progression, zones, the systems
required, the content families, the screens and the scenarios to measure -- every
one of them feeding a layer that already exists.

This is the only layer in the stack whose output has no verifiable right answer.
Everything else can be checked against something: a curve against the shipped
`Progression` module, a layout against a device, a catalogue against its own
balance rules. "Is this a good game idea" cannot be, and a compiler that
pretended otherwise would be the most dangerous module here -- confident, wrong,
and unarguable.

So the honesty is structural rather than optional. Every field carries how it
got there:

    STATED     the brief said so, and the words are quoted
    INFERRED   derived from words in the brief, which are named
    DEFAULTED  nothing in the brief decided it; the recipe or a constant did

A designer reading the output can see exactly which decisions were theirs, which
were read out of their sentence, and which the engine simply had to pick. The
third category is where disagreement belongs, and hiding it inside the second is
how a generated design becomes something nobody feels able to change.

What *is* checkable is that the result works: the model must be coherent, must
conform to its genre, and must compile. A design that reads beautifully and
produces an incoherent model has failed at the only thing this layer can be held
to.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence


class DesignError(ValueError):
    """The brief could not be compiled, and the message says what was missing."""


#: How a field got its value. The whole point of the module.
STATED = "STATED"
INFERRED = "INFERRED"
DEFAULTED = "DEFAULTED"


@dataclass(frozen=True)
class Decision:
    """One field, its value, and how it got there."""

    field: str
    value: Any
    provenance: str
    #: The words in the brief that produced it. Empty when DEFAULTED, which is
    #: exactly what makes a default visible.
    evidence: tuple[str, ...] = ()
    note: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "field": self.field,
            "value": self.value,
            "provenance": self.provenance,
            "evidence": list(self.evidence),
            "note": self.note,
        }


#: Genre signals. Multilingual on purpose: the briefs this engine receives are
#: written in Portuguese and English interchangeably, and a compiler that only
#: read one would default silently on half of them.
GENRE_SIGNALS: dict[str, tuple[str, ...]] = {
    "tycoon": ("tycoon", "factory", "fábrica", "fabrica", "production", "produção",
               "producao", "automação", "automacao", "automation", "plot", "empire",
               "império", "imperio", "assembly", "conveyor", "esteira"),
    "simulator": ("simulator", "simulador", "sim ", "grind", "pet sim", "clicker",
                  "hatch", "chocar"),
    "tower_defense": ("tower defense", "tower-defense", "defense", "defesa",
                      "waves", "ondas", "siege", "cerco", "horde", "horda", "td "),
    "roguelite": ("roguelite", "roguelike", "run-based", "runs", "permadeath",
                  "dungeon", "masmorra"),
    "collection": ("collection", "coleção", "colecao", "collect", "coletar",
                   "cards", "cartas", "gacha", "creatures", "criaturas",
                   "monsters", "monstros", "pokedex"),
    "survival": ("survival", "sobrevivência", "sobrevivencia", "survive",
                 "sobreviver", "hunger", "fome", "craft", "crafting", "shelter"),
    "racing": ("racing", "corrida", "race", "correr", "track", "pista",
               "lap", "volta", "kart"),
}

#: Mechanic signals: verbs and systems a brief asks for beyond its genre's core.
MECHANIC_SIGNALS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    # keyword -> (extra verbs, extra systems)
    "exploration": (("explore",), ()),
    "exploração": (("explore",), ()),
    "exploracao": (("explore",), ()),
    "explore": (("explore",), ()),
    "trading": (("trade",), ("trading",)),
    "troca": (("trade",), ("trading",)),
    "quests": (("quest",), ("quests",)),
    "missões": (("quest",), ("quests",)),
    "missoes": (("quest",), ("quests",)),
    "crafting": (("craft",), ("crafting",)),
    "craft": (("craft",), ("crafting",)),
    "shop": (("buy",), ("shop",)),
    "loja": (("buy",), ("shop",)),
    "store": (("buy",), ("shop",)),
    "gacha": (("pull",), ("gacha", "inventory")),
    "pets": ((), ("pets", "inventory")),
    "prestige": (("prestige",), ()),
    "offline": ((), ("offline_income",)),
    "leaderboard": ((), ("leaderboard",)),
    "ranking": ((), ("leaderboard",)),
    "tutorial": ((), ("tutorial",)),
}

#: Monetization signals.
MONETIZATION_SIGNALS = {
    "cosmetics": ("cosmetic", "cosmético", "cosmetico", "skin", "skins"),
    "boosts": ("boost", "boosts", "multiplier", "multiplicador"),
    "passes": ("gamepass", "game pass", "pass"),
    "battle_pass": ("battle pass", "passe de batalha", "season pass"),
    "currency_packs": ("robux pack", "currency pack", "pacote de moeda"),
}

#: Places a zone could be built from, grouped by concept.
#:
#: Grouped rather than listed flat because a Portuguese brief mentioning a
#: laboratory matches both "lab" and "laboratório", and a flat list produced the
#: theme "lab laboratório" -- the same concept twice, in two languages, read back
#: to the designer as if it were two places.
PLACE_CONCEPTS: dict[str, tuple[str, ...]] = {
    "reef": ("reef", "recife"),
    "abyss": ("abyss", "abismo", "trench", "fossa"),
    "cave": ("cave", "caverna"),
    "forest": ("forest", "floresta"),
    "volcano": ("volcano", "vulcão", "vulcao"),
    "desert": ("desert", "deserto"),
    "city": ("city", "cidade"),
    "station": ("station", "estação", "estacao"),
    "lab": ("lab", "laboratório", "laboratorio"),
    "mine": ("mine", "mina"),
    "farm": ("farm", "fazenda"),
    "ruins": ("ruins", "ruínas", "ruinas"),
    "temple": ("temple", "templo"),
    "island": ("island", "ilha"),
    "market": ("market", "mercado"),
    "arena": ("arena",),
}

#: Session lengths a brief can ask for, in minutes.
SESSION_SIGNALS = (
    (re.compile(r"(\d+)\s*(?:min|minuto|minute)"), 1.0),
    (re.compile(r"(\d+)\s*(?:h|hora|hour)"), 60.0),
)

# A named resource is product identity, not a cosmetic label for ``cash``.
# Kept deliberately small and semantic: these are resources briefs commonly
# state explicitly, never genre guesses.  Unknown resources remain visible as
# the recipe's default rather than being hallucinated from arbitrary nouns.
CURRENCY_CONCEPTS: dict[str, tuple[str, tuple[str, ...]]] = {
    "embers": ("Embers", ("ember", "embers", "brasa", "brasas")),
    "essence": ("Essence", ("essence", "essencia")),
    "scrap": ("Scrap", ("scrap", "sucata")),
    "coins": ("Coins", ("coin", "coins", "moeda", "moedas")),
}


def _fold(text: str) -> str:
    """Lowercase, accent-stripped, for matching only.

    Never used for output: an accent-stripped Portuguese brief read back to a
    designer looks like a bug.
    """

    decomposed = unicodedata.normalize("NFD", text.lower())
    return "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")


@dataclass
class Analysis:
    """What the brief said, before anything is decided."""

    brief: str
    genre_scores: dict[str, list[str]] = field(default_factory=dict)
    mechanics: dict[str, list[str]] = field(default_factory=dict)
    monetization: dict[str, list[str]] = field(default_factory=dict)
    places: list[str] = field(default_factory=list)
    session_minutes: float = 0.0
    currency: tuple[str, str] | None = None
    currency_evidence: tuple[str, ...] = ()
    ambiguities: list[str] = field(default_factory=list)

    @property
    def genre(self) -> str | None:
        if not self.genre_scores:
            return None
        return max(self.genre_scores, key=lambda key: len(self.genre_scores[key]))

    def to_dict(self) -> dict[str, Any]:
        return {
            "brief": self.brief,
            "genreCandidates": {
                genre: words for genre, words in
                sorted(self.genre_scores.items(), key=lambda item: -len(item[1]))
            },
            "genre": self.genre,
            "mechanics": self.mechanics,
            "monetization": self.monetization,
            "places": self.places,
            "sessionMinutes": self.session_minutes,
            "currency": (
                {"id": self.currency[0], "displayName": self.currency[1],
                 "evidence": list(self.currency_evidence)}
                if self.currency is not None else None
            ),
            "ambiguities": self.ambiguities,
        }


def analyse(brief: str) -> Analysis:
    """Read the brief. Decide nothing."""

    if not brief or not brief.strip():
        raise DesignError("an empty brief compiles to nothing")

    folded = _fold(brief)
    analysis = Analysis(brief=brief.strip())

    for genre, signals in GENRE_SIGNALS.items():
        hits = [signal.strip() for signal in signals if _fold(signal) in folded]
        if hits:
            analysis.genre_scores[genre] = hits

    for keyword, _ in MECHANIC_SIGNALS.items():
        if _fold(keyword) in folded:
            verbs, systems = MECHANIC_SIGNALS[keyword]
            entry = analysis.mechanics.setdefault(keyword, [])
            entry.extend(list(verbs) + list(systems))

    for kind, signals in MONETIZATION_SIGNALS.items():
        hits = [signal for signal in signals if _fold(signal) in folded]
        if hits:
            analysis.monetization[kind] = hits

    # One entry per concept, however many of its words appear.
    analysis.places = [
        concept for concept, words in PLACE_CONCEPTS.items()
        if any(_fold(word) in folded for word in words)
    ]

    for pattern, multiplier in SESSION_SIGNALS:
        match = pattern.search(folded)
        if match:
            analysis.session_minutes = float(match.group(1)) * multiplier
            break

    for currency_id, (display_name, signals) in CURRENCY_CONCEPTS.items():
        hits = tuple(signal for signal in signals if _fold(signal) in folded)
        if hits:
            analysis.currency = (currency_id, display_name)
            analysis.currency_evidence = hits
            break

    # Ambiguity is reported, never resolved silently. Two genres with equal
    # evidence is a question for a designer, and picking one without saying so
    # is how a brief becomes a game nobody asked for.
    if len(analysis.genre_scores) > 1:
        ranked = sorted(analysis.genre_scores.items(), key=lambda item: -len(item[1]))
        if len(ranked[0][1]) == len(ranked[1][1]):
            analysis.ambiguities.append(
                f"the brief supports {ranked[0][0]} and {ranked[1][0]} equally "
                f"({', '.join(ranked[0][1])} against {', '.join(ranked[1][1])}); "
                f"{ranked[0][0]} was taken, and naming the genre would settle it"
            )
    if not analysis.genre_scores:
        analysis.ambiguities.append(
            "no genre signal in the brief; tycoon was assumed, which is a guess "
            "rather than a reading"
        )
    if not analysis.places:
        analysis.ambiguities.append(
            "no place named in the brief, so zones were not derived; a hub-and-zones "
            "world needs somewhere to go"
        )

    return analysis


def _theme_from(brief: str, analysis: Analysis) -> tuple[str, str, tuple[str, ...]]:
    """A theme, its provenance, and the evidence."""

    if analysis.places:
        # The named places *are* the theme: "underwater lab with reefs" is
        # themed by its reef and its lab, not by an adjective somebody picked.
        return " ".join(analysis.places[:2]), INFERRED, tuple(analysis.places[:2])

    words = [word for word in re.findall(r"[A-Za-zÀ-ÿ]+", brief) if len(word) > 3]
    if words:
        return " ".join(words[:3]).lower(), INFERRED, tuple(words[:3])
    return "unthemed", DEFAULTED, ()


@dataclass
class DesignDocument:
    """A whole design, with every decision's provenance attached."""

    id: str
    brief: str
    analysis: Analysis
    decisions: list[Decision] = field(default_factory=list)
    model: Any = None

    def decision(self, name: str) -> Decision | None:
        return next((item for item in self.decisions if item.field == name), None)

    @property
    def defaulted(self) -> list[str]:
        """Fields nothing in the brief decided. Where disagreement belongs."""

        return [item.field for item in self.decisions if item.provenance == DEFAULTED]

    def to_dict(self) -> dict[str, Any]:
        from ..recipes import check
        from ..ui import screens_for

        payload: dict[str, Any] = {
            "schemaVersion": 1,
            "id": self.id,
            "brief": self.brief,
            "analysis": self.analysis.to_dict(),
            "decisions": [item.to_dict() for item in self.decisions],
            "defaulted": self.defaulted,
            "ambiguities": self.analysis.ambiguities,
        }
        if self.model is not None:
            payload["model"] = self.model.to_dict()
            payload["coherent"] = self.model.coherent
            payload["problems"] = self.model.problems()
            payload["conformance"] = check(self.model)
            payload["screens"] = screens_for(self.model)
        payload["note"] = (
            "every field says how it got there. DEFAULTED means nothing in the brief "
            "decided it -- that is where disagreement belongs, and hiding it inside "
            "INFERRED is how a generated design becomes something nobody feels able "
            "to change"
        )
        return payload

    def summary(self) -> str:
        lines = [f"{self.id}: {self.brief[:70]}"]
        if self.model is not None:
            lines.append(
                f"  {self.model.genre} / {self.model.theme} -- "
                f"{' -> '.join(self.model.core_loop)}"
            )
            lines.append(
                f"  {len(self.model.systems)} systems, {len(self.model.currencies)} "
                f"currencies, {len(self.model.zones)} zones, "
                f"{self.model.progression.tiers} tiers"
            )
        for item in self.decisions:
            if item.provenance == INFERRED:
                lines.append(f"  inferred {item.field} = {item.value} "
                             f"from {', '.join(item.evidence)}")
        if self.defaulted:
            lines.append(f"  defaulted: {', '.join(self.defaulted)}")
        for ambiguity in self.analysis.ambiguities:
            lines.append(f"  ambiguous: {ambiguity}")
        return "\n".join(lines)


def compile_brief(
    brief: str,
    *,
    id: str,
    genre: str = "",
    theme: str = "",
    pitch: str = "",
    session_minutes: float = 0.0,
    token_set: str = "tokens/brickfarm.json",
) -> DesignDocument:
    """A brief becomes a whole design, showing its work.

    Anything passed explicitly is `STATED` and overrides what the brief implies:
    a designer who names the genre has settled it, and re-deriving it would be
    the compiler arguing with the person it works for.
    """

    from ..recipes import RecipeError, apply, recipe_for

    analysis = analyse(brief)
    decisions: list[Decision] = []

    # -- genre ----------------------------------------------------------
    if genre:
        chosen = genre
        decisions.append(Decision("genre", genre, STATED, note="named by the caller"))
    elif analysis.genre:
        chosen = analysis.genre
        decisions.append(Decision("genre", chosen, INFERRED,
                                  tuple(analysis.genre_scores[chosen])))
    else:
        chosen = "tycoon"
        decisions.append(Decision(
            "genre", chosen, DEFAULTED,
            note="no genre word in the brief; tycoon is the engine's most complete "
                 "production path, which makes it a safe guess and still a guess"))

    try:
        recipe = recipe_for(chosen)
    except RecipeError as exc:
        raise DesignError(str(exc)) from exc

    # -- theme ----------------------------------------------------------
    if theme:
        chosen_theme = theme
        decisions.append(Decision("theme", theme, STATED))
    else:
        chosen_theme, provenance, evidence = _theme_from(brief, analysis)
        decisions.append(Decision("theme", chosen_theme, provenance, evidence))

    # -- pitch ----------------------------------------------------------
    if pitch:
        chosen_pitch = pitch
        decisions.append(Decision("pitch", pitch, STATED))
    else:
        # The brief itself, not a rewrite of it. A compiler that paraphrased
        # would be putting words in a designer's mouth and calling them theirs.
        chosen_pitch = analysis.brief
        decisions.append(Decision("pitch", chosen_pitch, STATED,
                                  note="the brief verbatim; paraphrasing it would put "
                                       "words in the designer's mouth"))

    # -- mechanics ------------------------------------------------------
    extra_verbs: list[str] = []
    extra_systems: list[str] = []
    for keyword, additions in analysis.mechanics.items():
        verbs, systems = MECHANIC_SIGNALS[keyword]
        for verb in verbs:
            if verb not in extra_verbs:
                extra_verbs.append(verb)
        for system in systems:
            if system not in extra_systems:
                extra_systems.append(system)
    if extra_verbs or extra_systems:
        decisions.append(Decision(
            "mechanics", {"verbs": extra_verbs, "systems": extra_systems},
            INFERRED, tuple(sorted(analysis.mechanics))))

    # -- zones ----------------------------------------------------------
    zones: list[dict[str, Any]] = []
    if recipe.topology in ("hub_and_zones", "open_world"):
        if analysis.places:
            for index, place in enumerate(analysis.places[:4]):
                zones.append({
                    "id": re.sub(r"[^a-z0-9]+", "-", _fold(place)).strip("-") or f"zone{index}",
                    "theme": place,
                    # Difficulty rises with position: the first place named is
                    # where a player starts, which is the reading a designer
                    # would expect and is still an assumption.
                    "difficulty": min(index + 1, 5),
                    "unlockedAtTier": index * 2,
                })
            decisions.append(Decision("zones", [zone["id"] for zone in zones],
                                      INFERRED, tuple(analysis.places[:4])))
        else:
            zones = [
                {"id": "start", "theme": chosen_theme, "difficulty": 1, "unlockedAtTier": 0},
                {"id": "deep", "theme": chosen_theme, "difficulty": 3, "unlockedAtTier": 4},
            ]
            decisions.append(Decision(
                "zones", ["start", "deep"], DEFAULTED,
                note=f"{recipe.topology} needs zones and the brief named no place; "
                     "two were assumed so the world has somewhere to go"))

    # -- session --------------------------------------------------------
    if session_minutes:
        minutes = session_minutes
        decisions.append(Decision("sessionMinutes", minutes, STATED))
    elif analysis.session_minutes:
        minutes = analysis.session_minutes
        decisions.append(Decision("sessionMinutes", minutes, INFERRED,
                                  (f"{int(minutes)} minutes",)))
    else:
        minutes = recipe.default_session_minutes
        decisions.append(Decision(
            "sessionMinutes", minutes, DEFAULTED,
            note=f"the {recipe.genre} recipe's usual session"))

    # -- monetization ---------------------------------------------------
    monetization = sorted(analysis.monetization)
    if monetization:
        decisions.append(Decision(
            "monetization", monetization, INFERRED,
            tuple(word for words in analysis.monetization.values() for word in words)))
    else:
        decisions.append(Decision(
            "monetization", [], DEFAULTED,
            note="the brief asked for none; shipping without monetization is a "
                 "decision rather than an oversight, and it is reversible"))

    decisions.append(Decision(
        "loop", list(recipe.core_verbs) + extra_verbs, INFERRED,
        (f"the {recipe.genre} recipe",),
        note="the genre's own loop, plus what the brief added"))

    currencies: list[dict[str, Any]] = []
    if analysis.currency is not None:
        currency_id, display_name = analysis.currency
        verbs = list(recipe.core_verbs) + extra_verbs
        earners = [v for v in verbs if v in ("sell", "process", "defend", "race", "collect")]
        spenders = [v for v in verbs if v in ("upgrade", "build", "unlock", "buy")]
        currencies.append({
            "id": currency_id,
            "displayName": display_name,
            "earnedBy": earners or ["collect"],
            "spentOn": spenders or ["upgrade"],
        })
        decisions.append(Decision(
            "currency", {"id": currency_id, "displayName": display_name},
            INFERRED, analysis.currency_evidence,
            note="the brief named the resource; the genre loop supplies how it is earned and spent",
        ))

    try:
        model = apply(
            recipe, id=id, theme=chosen_theme, pitch=chosen_pitch,
            zones=zones, extra_verbs=extra_verbs, extra_systems=extra_systems,
            session_minutes=minutes, token_set=token_set,
            monetization=monetization, currencies=currencies,
        )
    except RecipeError as exc:
        # The one thing this layer *can* be held to. A design that reads well
        # and produces an incoherent model has failed at it.
        raise DesignError(
            f"the compiled design does not hold together:\n{exc}"
        ) from exc

    return DesignDocument(id=id, brief=analysis.brief, analysis=analysis,
                          decisions=decisions, model=model)
