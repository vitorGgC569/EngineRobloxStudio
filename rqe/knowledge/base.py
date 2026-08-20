"""The knowledge base: what the engine learned from the games it has made.

The document's ask is that game #20 benefits from games #1 to #19 -- successful
layouts, economy curves, UI patterns, player funnels, monetization, retention,
failure patterns.

Half of that list is available now and half is not, and the difference is the
whole design of this module.

**What it can know.** Every producer run is a real execution that decided real
things and had them checked: this brief produced that genre, that cost curve was
verified against the shipped `Progression` and landed within tolerance, two zones
expanded into twenty regions, a 200,000-triangle budget fitted twelve distinct
assets at 2.3x reuse. Those are measurements, they accumulate, and a designer
starting the twentieth game can see what the previous nineteen landed on.

**What it cannot.** Player funnels, retention, monetization performance and
"which layouts players actually enjoyed" require *shipped games with players*.
No amount of engine-side work produces them. A knowledge base that returned an
empty average for retention would be worse than one that had no retention
question at all -- the empty average looks like an answer.

So every category declares its evidence source, and asking for one that needs
players comes back `UNAVAILABLE` with the reason, never as a zero. The gap is
the honest part: it names exactly what shipping a game would unlock.

Storage is append-only JSONL. A run is a fact about a moment; rewriting history
would make "the curve got steeper over time" unanswerable, which is the sort of
question this exists for.
"""

from __future__ import annotations

import json
import statistics
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence


class KnowledgeError(RuntimeError):
    """The knowledge base could not be read or written."""


DEFAULT_STORE = ".rqe/knowledge.jsonl"

#: Where a category's evidence comes from, and therefore whether it can be
#: answered at all yet.
FROM_ENGINE = "ENGINE"      # decided and checked during a producer run
FROM_SESSION = "SESSION"    # needs a measured play session
FROM_LIVE = "LIVE"          # needs a shipped game with real players


@dataclass(frozen=True)
class Category:
    id: str
    source: str
    question: str
    #: Why it is not answerable yet, when it is not.
    unlocked_by: str = ""


#: Everything the document asks the knowledge base to remember, with what each
#: one actually needs. Listing the unavailable ones is deliberate: deleting them
#: would make the base look complete and quietly stop anybody asking.
CATEGORIES: dict[str, Category] = {
    "economy_curves": Category(
        "economy_curves", FROM_ENGINE,
        "what step ratio and tier costs previous games of this genre landed on"),
    "world_layouts": Category(
        "world_layouts", FROM_ENGINE,
        "how many regions and routes a zone count expands into, and whether it validated"),
    "asset_budgets": Category(
        "asset_budgets", FROM_ENGINE,
        "how many distinct assets a triangle budget fits, and at what reuse ratio"),
    "system_sets": Category(
        "system_sets", FROM_ENGINE,
        "which systems a genre actually ends up needing"),
    "content_shapes": Category(
        "content_shapes", FROM_ENGINE,
        "how many entries a tier count produces, and whether it balanced"),
    "ui_patterns": Category(
        "ui_patterns", FROM_ENGINE,
        "which screens a system set implies, and which devices they fail on"),
    "failure_patterns": Category(
        "failure_patterns", FROM_ENGINE,
        "which stages refuse, and what they refuse for"),
    "session_pacing": Category(
        "session_pacing", FROM_SESSION,
        "how far a real player actually got in one session",
        unlocked_by="a scenario run against a built place, measured through the bridge"),
    "player_funnels": Category(
        "player_funnels", FROM_LIVE,
        "where players stop, and at which tier",
        unlocked_by="a shipped game with players and analytics coming back"),
    "retention_patterns": Category(
        "retention_patterns", FROM_LIVE,
        "which designs bring players back on day two",
        unlocked_by="a shipped game observed over days"),
    "monetization_patterns": Category(
        "monetization_patterns", FROM_LIVE,
        "which offers convert, and which annoy",
        unlocked_by="a shipped game with real purchases"),
}


@dataclass
class Record:
    """One producer run, reduced to what is worth remembering."""

    game_id: str
    recorded_at: str
    brief: str
    genre: str
    theme: str
    ok: bool
    facts: dict[str, Any] = field(default_factory=dict)
    failures: dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "gameId": self.game_id,
            "recordedAt": self.recorded_at,
            "brief": self.brief,
            "genre": self.genre,
            "theme": self.theme,
            "ok": self.ok,
            "facts": self.facts,
            "failures": self.failures,
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "Record":
        return cls(
            game_id=str(payload.get("gameId", "")),
            recorded_at=str(payload.get("recordedAt", "")),
            brief=str(payload.get("brief", "")),
            genre=str(payload.get("genre", "")),
            theme=str(payload.get("theme", "")),
            ok=bool(payload.get("ok", False)),
            facts=dict(payload.get("facts") or {}),
            failures=dict(payload.get("failures") or {}),
        )


def observe(run: Any) -> Record:
    """Reduce a production run to facts.

    Only what a later game could use. The whole run is already on disk if
    somebody wants it; a knowledge base that stored everything would be a log,
    and nobody queries a log.
    """

    facts: dict[str, Any] = {}
    failures: dict[str, str] = {}

    design = run.result("design")
    genre = (design.detail.get("genre", "") if design and design.detail else "")
    theme = (design.detail.get("theme", "") if design and design.detail else "")

    for result in run.results:
        if result.status == "FAILED":
            # The error *type*, not the message: messages carry paths and ids
            # that are about one run, and the pattern is what repeats.
            failures[result.stage] = result.error.split(":", 1)[0]
            continue
        if result.status != "OK" or not result.detail:
            continue

        detail = result.detail
        if result.stage == "economy":
            facts["economy_curves"] = {
                "stepRatio": detail.get("stepRatio"),
                "tiers": len(detail.get("tierCosts") or []),
                "firstCost": (detail.get("tierCosts") or [None])[0],
                "verifiedMinutes": detail.get("verifiedMinutes"),
                "problems": len(detail.get("problems") or []),
            }
        elif result.stage == "world":
            facts["world_layouts"] = {
                "regions": detail.get("regions"),
                "routes": detail.get("routes"),
                "walkableArea": detail.get("walkableArea"),
                "validated": detail.get("ok"),
            }
        elif result.stage == "assets":
            facts["asset_budgets"] = {
                "distinct": detail.get("distinct"),
                "placements": detail.get("placements"),
                "allocated": detail.get("allocated"),
                "reuseRatio": detail.get("reuseRatio"),
                "fits": detail.get("ok"),
            }
        elif result.stage == "systems":
            facts["system_sets"] = {
                "order": detail.get("order"),
                "implemented": detail.get("implemented"),
                "planned": detail.get("planned"),
            }
        elif result.stage == "content":
            facts["content_shapes"] = {
                "entries": detail.get("entries"),
                "consistency": detail.get("consistency"),
                "balance": detail.get("balance"),
                "balanced": detail.get("ok"),
            }
        elif result.stage == "interface":
            facts["ui_patterns"] = {
                "screens": detail.get("screens"),
                "failing": detail.get("failing"),
            }

    return Record(
        game_id=run.game_id,
        recorded_at=datetime.now(timezone.utc).isoformat(),
        brief=run.brief,
        genre=genre,
        theme=theme,
        ok=run.ok,
        facts=facts,
        failures=failures,
    )


def record(root: Path, run: Any, *, store: str = DEFAULT_STORE) -> Record:
    """Append one run to the base."""

    entry = observe(run)
    path = (root / store).resolve()
    try:
        path.relative_to(Path(root).resolve())
    except ValueError as exc:
        raise KnowledgeError("the store must stay inside the project root") from exc

    path.parent.mkdir(parents=True, exist_ok=True)
    # Append-only. A run is a fact about a moment, and rewriting history makes
    # "did the curve get steeper over time" unanswerable.
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry.to_dict(), ensure_ascii=False) + "\n")
    return entry


def load(root: Path, *, store: str = DEFAULT_STORE) -> list[Record]:
    path = root / store
    if not path.is_file():
        return []
    records: list[Record] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(Record.from_dict(json.loads(line)))
        except json.JSONDecodeError as exc:
            raise KnowledgeError(f"{path} has a malformed entry: {exc}") from exc
    return records


def _numbers(values: Iterable[Any]) -> list[float]:
    return [float(value) for value in values
            if isinstance(value, (int, float)) and not isinstance(value, bool)]


def _summarise(values: list[float]) -> dict[str, float]:
    return {
        "samples": len(values),
        "min": round(min(values), 4),
        "median": round(statistics.median(values), 4),
        "max": round(max(values), 4),
    }


def query(
    root: Path,
    category: str,
    *,
    genre: str = "",
    store: str = DEFAULT_STORE,
) -> dict[str, Any]:
    """What previous games landed on, for one category.

    Answers `UNAVAILABLE` rather than zero when a category needs evidence the
    engine cannot produce. An empty average looks like an answer, and that is
    the failure this module was shaped to avoid.
    """

    if category not in CATEGORIES:
        raise KnowledgeError(
            f"unknown category {category!r}; known: " + ", ".join(sorted(CATEGORIES)))
    definition = CATEGORIES[category]

    if definition.source != FROM_ENGINE:
        return {
            "schemaVersion": 1,
            "category": category,
            "status": "UNAVAILABLE",
            "question": definition.question,
            "evidenceSource": definition.source,
            "unlockedBy": definition.unlocked_by,
            "note": (
                "not answerable from engine-side work at all. Returning an empty "
                "average here would look like an answer, which is worse than the gap"
            ),
        }

    records = [item for item in load(root, store=store)
               if not genre or item.genre == genre]
    relevant = [item for item in records if category in item.facts]

    if not relevant:
        return {
            "schemaVersion": 1,
            "category": category,
            "status": "NO_DATA",
            "question": definition.question,
            "evidenceSource": definition.source,
            "records": len(records),
            "note": (
                "this category is answerable, and nothing has been recorded for it yet"
                + (f" for genre {genre!r}" if genre else "")
            ),
        }

    # Aggregate every field the category carries, so a new field in the producer
    # surfaces here without this function being edited.
    #
    # Numbers become a spread; lists become frequencies. The list case is not an
    # afterthought -- "which systems does a simulator end up needing" is the most
    # useful question here, and it has no median.
    numeric: dict[str, list[float]] = {}
    categorical: dict[str, dict[str, int]] = {}
    for item in relevant:
        for key, value in item.facts[category].items():
            if isinstance(value, (list, tuple)):
                counts = categorical.setdefault(key, {})
                for element in value:
                    counts[str(element)] = counts.get(str(element), 0) + 1
                continue
            numbers = _numbers([value])
            if numbers:
                numeric.setdefault(key, []).extend(numbers)

    return {
        "schemaVersion": 1,
        "category": category,
        "status": "MEASURED",
        "question": definition.question,
        "evidenceSource": definition.source,
        "records": len(relevant),
        "genre": genre or "any",
        "games": [item.game_id for item in relevant],
        "fields": {key: _summarise(values) for key, values in sorted(numeric.items())},
        "frequencies": {
            key: {
                # Reported as "n of m games", not as a percentage: with three
                # records a percentage implies a precision nobody has.
                name: f"{count} of {len(relevant)}"
                for name, count in sorted(counts.items(), key=lambda pair: -pair[1])
            }
            for key, counts in sorted(categorical.items())
        },
        "note": (
            "measured from real producer runs; every number here was decided and "
            "checked by a layer, not estimated"
        ),
    }


def failures(root: Path, *, store: str = DEFAULT_STORE) -> dict[str, Any]:
    """Which stages refuse, and how often.

    The document's "failure patterns", and the one category that gets more
    useful the worse things go.
    """

    records = load(root, store=store)
    counts: dict[str, dict[str, int]] = {}
    for item in records:
        for stage, error in item.failures.items():
            counts.setdefault(stage, {})
            counts[stage][error] = counts[stage].get(error, 0) + 1

    return {
        "schemaVersion": 1,
        "category": "failure_patterns",
        "status": "MEASURED" if records else "NO_DATA",
        "records": len(records),
        "byStage": {
            stage: dict(sorted(errors.items(), key=lambda item: -item[1]))
            for stage, errors in sorted(counts.items())
        },
        "note": (
            "error types rather than messages: a message carries the paths and ids of "
            "one run, and the pattern is what repeats"
        ),
    }


def advise(root: Path, genre: str, *, store: str = DEFAULT_STORE) -> dict[str, Any]:
    """What the previous games of a genre suggest for the next one.

    The document's actual ask, stated plainly: game #20 reading games #1-19.
    """

    records = [item for item in load(root, store=store) if item.genre == genre]
    engine_categories = [key for key, value in CATEGORIES.items()
                         if value.source == FROM_ENGINE]

    suggestions: dict[str, Any] = {}
    for category in engine_categories:
        result = query(root, category, genre=genre, store=store)
        if result.get("status") == "MEASURED":
            entry: dict[str, Any] = {}
            if result.get("fields"):
                entry["spread"] = result["fields"]
            if result.get("frequencies"):
                entry["frequencies"] = result["frequencies"]
            if entry:
                suggestions[category] = entry

    return {
        "schemaVersion": 1,
        "genre": genre,
        "priorGames": [item.game_id for item in records],
        "count": len(records),
        "suggestions": suggestions,
        # Named every time, so the half that needs shipping never quietly
        # disappears from view.
        "stillUnknown": [
            {"category": key, "unlockedBy": value.unlocked_by}
            for key, value in sorted(CATEGORIES.items())
            if value.source != FROM_ENGINE
        ],
        "note": (
            "what previous runs landed on, not what is correct. A median is where the "
            "engine has been, and following it without thinking is how twenty games "
            "become one game twenty times"
        ),
    }


def coverage(root: Path, *, store: str = DEFAULT_STORE) -> dict[str, Any]:
    """What the base knows, and what it cannot know yet."""

    records = load(root, store=store)
    populated = {key for item in records for key in item.facts}
    return {
        "schemaVersion": 1,
        "records": len(records),
        "games": sorted({item.game_id for item in records}),
        "categories": [
            {
                "id": key,
                "source": value.source,
                "question": value.question,
                "status": (
                    "MEASURED" if key in populated
                    else "NO_DATA" if value.source == FROM_ENGINE
                    else "UNAVAILABLE"
                ),
                "unlockedBy": value.unlocked_by,
            }
            for key, value in sorted(CATEGORIES.items())
        ],
        "note": (
            "categories needing players are listed rather than omitted: deleting them "
            "would make the base look complete and quietly stop anybody asking"
        ),
    }
