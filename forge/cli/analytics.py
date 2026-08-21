"""Read the telemetry back.

The gap this closes
-------------------

`Telemetry` has buffered, batched, funnelled and aggregated since the day it
was written, and `Meta.installTelemetrySink` writes every batch into a real
DataStore keyed by day. Nothing has ever read a single row back.

That is worse than having no telemetry, because it looks like having
telemetry. An agent proposing a balance change with a dashboard behind it and
an agent guessing are the same agent if nobody opens the dashboard.

    forge analytics provingground              the last seven days
    forge analytics provingground --days 30    a month
    forge analytics provingground --raw        the events, unaggregated

What this reads
---------------

The Open Cloud Standard DataStore API, against the same `ForgeAnalytics` store
and the same `events/<date>` keys the sink writes. No second pipeline, no
export step: the thing that reads is pointed at the thing that wrote.

The key needs **datastore-api read** scope on the universe, which is a separate
tick from the `universe.place:write` scope publishing uses. A key with only the
publish scope answers 403 here, and this says so rather than reporting zero
events — a silent zero is how an analytics system convinces you nobody plays
your game.

Why summaries and not a table
-----------------------------

A list of eleven thousand events is not evidence, it is a haystack. What makes
telemetry worth reading is the small number of shapes a designer acts on:
where players stop, how long they stay, what breaks, and what they actually
do. Those four are computed here; `--raw` is available for anything else.
"""

from __future__ import annotations

import json
import statistics
import urllib.parse
from collections import Counter, defaultdict
from datetime import date, timedelta
from pathlib import Path
from typing import Any

from . import publish

REPO = Path(__file__).resolve().parents[2]

#: Must match `Meta.installTelemetrySink`. Named once, here, so the reader and
#: the writer cannot drift apart without this line changing.
STORE = "ForgeAnalytics"
KEY_PREFIX = "events/"


class AnalyticsError(RuntimeError):
    pass


def target(game: str) -> dict[str, str]:
    entry = publish.targets().get(game)
    if not entry:
        raise AnalyticsError(
            f"no published experience for {game}; run `forge publish {game} "
            "--universe <id> --place <id>` once so this knows where to look")
    return entry


def _entry(universe_id: str, key: str, api_key: str) -> Any | None:
    """One day's events, or None if that day has none."""
    query = urllib.parse.urlencode({
        "datastoreName": STORE,
        "entryKey": key,
    })
    url = (f"https://apis.roblox.com/datastores/v1/universes/{universe_id}"
           f"/standard-datastores/datastore/entries/entry?{query}")
    status, body = publish._request("GET", url, api_key)

    if status == 204 or status == 404:
        return None
    if status == 403:
        raise AnalyticsError(
            "the key was refused (403). Publishing and reading are separate "
            "scopes: this needs datastore-api read on universe "
            f"{universe_id}, which is a different tick from universe.place:write")
    if status == 401:
        raise AnalyticsError("the key is not valid (401)")
    if status != 200:
        raise AnalyticsError(f"datastore read failed ({status}): {body[:200]}")

    try:
        return json.loads(body)
    except json.JSONDecodeError:
        raise AnalyticsError(f"the stored value is not JSON: {body[:160]}")


def fetch(game: str, days: int = 7) -> dict[str, Any]:
    """Every event this experience recorded over the last `days` days."""
    entry = target(game)
    api_key = publish.load_key()
    universe_id = entry["universeId"]

    events: list[dict[str, Any]] = []
    present, absent = [], []

    today = date.today()
    for offset in range(days):
        day = (today - timedelta(days=offset)).isoformat()
        rows = _entry(universe_id, KEY_PREFIX + day, api_key)
        if not rows:
            absent.append(day)
            continue
        present.append(day)
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict):
                    events.append({
                        "at": row.get("t"),
                        "name": row.get("n") or "?",
                        "props": row.get("p") or {},
                        "day": day,
                    })

    return {
        "game": game,
        "universeId": universe_id,
        "daysRequested": days,
        "daysWithData": present,
        "daysEmpty": absent,
        "events": events,
    }


# ============================== the four shapes ==============================

def sessions(events: list[dict]) -> dict[str, Any]:
    """How long people stay, which is the only retention number that matters.

    Reported as a median rather than a mean, because one player who idles for
    four hours moves a mean and tells you nothing about the median player's
    experience — and the median player's experience is the game.
    """
    lengths = [
        float(event["props"].get("seconds", 0))
        for event in events
        if event["name"] == "session.end" and event["props"].get("seconds") is not None
    ]
    starts = sum(1 for event in events if event["name"] == "session.start")

    if not lengths:
        return {"starts": starts, "completed": 0}

    lengths.sort()
    return {
        "starts": starts,
        "completed": len(lengths),
        "medianSeconds": round(statistics.median(lengths)),
        "meanSeconds": round(statistics.fmean(lengths)),
        "p90Seconds": round(lengths[min(len(lengths) - 1, int(len(lengths) * 0.9))]),
        # The single most diagnostic number in any Roblox game. A player who
        # leaves inside thirty seconds did not dislike your game; they never
        # saw it, and the cause is almost always load time or spawn.
        "underThirtySeconds": sum(1 for value in lengths if value < 30),
        "bounceRate": round(sum(1 for value in lengths if value < 30) / len(lengths), 3),
    }


def funnels(events: list[dict]) -> list[dict[str, Any]]:
    """Where people stop.

    Reconstructed from `funnel.<name>` events by taking each subject's
    furthest step, which is exactly what the Luau side records — so the
    read-back agrees with the in-game report instead of computing a second,
    subtly different number.
    """
    furthest: dict[str, dict[str, int]] = defaultdict(dict)
    for event in events:
        if not event["name"].startswith("funnel."):
            continue
        name = event["name"][len("funnel."):]
        props = event["props"]
        subject, step = props.get("subject"), props.get("step")
        if subject is None or step is None:
            continue
        current = furthest[name].get(str(subject), 0)
        furthest[name][str(subject)] = max(current, int(step))

    reports = []
    for name, subjects in sorted(furthest.items()):
        if not subjects:
            continue
        top = max(subjects.values())
        reached = [sum(1 for value in subjects.values() if value >= step)
                   for step in range(1, top + 1)]
        steps, previous = [], None
        for index, count in enumerate(reached, start=1):
            steps.append({
                "step": index,
                "reached": count,
                "lost": (previous - count) if previous is not None else 0,
                "retention": round(count / previous, 3) if previous else 1.0,
            })
            previous = count
        worst = min(steps[1:], key=lambda item: item["retention"], default=None)
        reports.append({
            "funnel": name,
            "subjects": len(subjects),
            "steps": steps,
            "worstStep": worst["step"] if worst else None,
        })
    return reports


def errors(events: list[dict]) -> list[dict[str, Any]]:
    """What breaks, most often first.

    The sink only carries the first of each signature, so a count here is a
    count of distinct outbreaks rather than of occurrences. That distinction
    matters: three rows is three separate faults, not three crashes.
    """
    grouped: dict[str, dict[str, Any]] = {}
    for event in events:
        if event["name"] != "error":
            continue
        signature = str(event["props"].get("signature") or "?")
        row = grouped.setdefault(signature, {
            "signature": signature,
            "occurrences": 0,
            "sample": str(event["props"].get("message") or "")[:200],
            "firstSeen": event.get("at"),
        })
        row["occurrences"] += 1
    return sorted(grouped.values(), key=lambda row: -row["occurrences"])


def behaviour(events: list[dict]) -> dict[str, Any]:
    """What players actually do, as opposed to what the design assumed.

    Deliberately just counts. The value is not in the arithmetic — it is in
    seeing that the ability nobody was worried about fires nine times more
    often than the one that was balanced three times.
    """
    counts = Counter(event["name"] for event in events)
    health = [event["props"] for event in events if event["name"] == "server.health"]

    summary: dict[str, Any] = {
        "totalEvents": len(events),
        "distinctEvents": len(counts),
        "top": [{"event": name, "count": count} for name, count in counts.most_common(15)],
    }

    if health:
        beats = [float(row.get("heartbeatMs") or 0) for row in health]
        players = [float(row.get("players") or 0) for row in health]
        instances = [float(row.get("instances") or 0) for row in health]
        summary["server"] = {
            "samples": len(health),
            "medianHeartbeatMs": round(statistics.median(beats), 2) if beats else None,
            # The worst frame is the one players remember, so it is reported
            # next to the median rather than averaged into it.
            "worstHeartbeatMs": round(max(beats), 2) if beats else None,
            "peakPlayers": int(max(players)) if players else 0,
            "peakInstances": int(max(instances)) if instances else 0,
        }
    return summary


def summarise(fetched: dict[str, Any]) -> dict[str, Any]:
    events = fetched["events"]
    return {
        "game": fetched["game"],
        "daysWithData": fetched["daysWithData"],
        "daysEmpty": fetched["daysEmpty"],
        "sessions": sessions(events),
        "funnels": funnels(events),
        "errors": errors(events),
        "behaviour": behaviour(events),
        "notes": observations(events),
    }


# ================================ the reading ================================

def observations(events: list[dict]) -> list[str]:
    """Say what the numbers mean, in words.

    This is the part that makes the module worth having. A summary hands back
    a bounce rate of 0.41; what an agent needs to know is that four in ten
    players leave before the game starts and that this is a spawn or load
    problem rather than a balance one.
    """
    notes: list[str] = []

    if not events:
        notes.append(
            "no events at all. Either nobody has played since the sink was "
            "installed, or the server never flushed — a session shorter than "
            "the 30s flush interval only writes on BindToClose.")
        return notes

    session = sessions(events)
    if session.get("completed"):
        if session["bounceRate"] > 0.3:
            notes.append(
                f"{session['bounceRate']:.0%} of sessions end inside thirty seconds. "
                "That is not a balance problem — players who leave that fast never "
                "saw the game. Look at load time and what is visible from spawn.")
        median = session.get("medianSeconds", 0)
        if median and median < 120:
            notes.append(
                f"the median session is {median}s. Under two minutes means the "
                "first loop is not landing, whatever the later ones do.")
    elif session.get("starts"):
        notes.append(
            f"{session['starts']} sessions started and none ended. Sessions close "
            "on PlayerRemoving and BindToClose, so this means the server is still "
            "running or the shutdown flush never reached the store.")

    for report in funnels(events):
        if report["worstStep"]:
            step = next(item for item in report["steps"] if item["step"] == report["worstStep"])
            if step["retention"] < 0.7:
                notes.append(
                    f"funnel '{report['funnel']}' loses {1 - step['retention']:.0%} of "
                    f"players at step {step['step']}. That step is where the game "
                    "asks something it has not taught.")

    faults = errors(events)
    if faults:
        notes.append(
            f"{len(faults)} distinct error signatures reached the sink. The most "
            f"frequent: {faults[0]['sample'][:110]}")

    stats = behaviour(events).get("server")
    if stats and stats.get("worstHeartbeatMs"):
        if stats["worstHeartbeatMs"] > 33:
            notes.append(
                f"the worst server heartbeat was {stats['worstHeartbeatMs']}ms against "
                "a 16.7ms budget. Players felt that as the game stuttering, and it "
                f"happened with {stats['peakPlayers']} players on "
                f"{stats['peakInstances']} instances.")

    counts = Counter(event["name"] for event in events)
    named = [(name, count) for name, count in counts.items()
             if not name.startswith(("session.", "server.", "funnel.", "mark.", "error"))]
    if len(named) >= 2:
        named.sort(key=lambda item: -item[1])
        most, least = named[0], named[-1]
        if least[1] > 0 and most[1] / least[1] > 20:
            notes.append(
                f"'{most[0]}' happens {most[1] // least[1]}x more often than "
                f"'{least[0]}'. If those were meant to be comparable choices, "
                "they are not being treated as one.")

    return notes


def render(summary: dict[str, Any]) -> str:
    lines: list[str] = []
    days = summary["daysWithData"]
    lines.append(f"  days with data   {len(days)}"
                 + (f"  ({days[-1]} .. {days[0]})" if days else ""))

    session = summary["sessions"]
    if session.get("completed"):
        lines.append(f"  sessions         {session['completed']} completed "
                     f"of {session['starts']} started")
        lines.append(f"  median length    {session['medianSeconds']}s   "
                     f"p90 {session['p90Seconds']}s")
        lines.append(f"  bounce (<30s)    {session['bounceRate']:.0%}")
    else:
        lines.append(f"  sessions         {session.get('starts', 0)} started, none closed")

    stats = summary["behaviour"]
    lines.append(f"  events           {stats['totalEvents']} "
                 f"across {stats['distinctEvents']} kinds")
    for row in stats["top"][:8]:
        lines.append(f"      {row['count']:>6}  {row['event']}")

    if stats.get("server"):
        server = stats["server"]
        lines.append(f"  heartbeat        {server['medianHeartbeatMs']}ms median, "
                     f"{server['worstHeartbeatMs']}ms worst")
        lines.append(f"  peak             {server['peakPlayers']} players, "
                     f"{server['peakInstances']} instances")

    for report in summary["funnels"]:
        lines.append(f"  funnel {report['funnel']} ({report['subjects']} subjects)")
        for step in report["steps"]:
            lines.append(f"      step {step['step']}  {step['reached']:>5} "
                         f"({step['retention']:.0%} kept)")

    if summary["errors"]:
        lines.append(f"  errors           {len(summary['errors'])} distinct")
        for row in summary["errors"][:5]:
            lines.append(f"      {row['occurrences']:>3}x  {row['sample'][:90]}")

    if summary["notes"]:
        lines.append("")
        for note in summary["notes"]:
            lines.append(f"  - {note}")

    return "\n".join(lines)
