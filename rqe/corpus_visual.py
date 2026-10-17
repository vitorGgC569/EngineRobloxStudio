"""Opening the corpus, not just building it.

Twenty briefs build. Not one of them was ever opened, photographed or scored --
`corpus.py` has no reference to `play_solo`, `capture_frame` or `scenario`,
because it evaluates *stages* and a stage is a claim about a pipeline, not about
a game. A brief that "passes" the corpus has proven that the factory did not
error. Nobody has looked.

That gap is the whole reason a run of twenty green builds could sit beside a
screenshot of a green box with a floating character.

**This is slow and says so.** Each place costs a Studio restart, a capture and a
critique -- tens of seconds, not milliseconds. So it samples rather than sweeps
by default, and the sample is deterministic: the same seed opens the same games,
so a regression is comparable against the run before it.

**A place that will not open is a finding, not an error.** The most useful thing
this can report is that a game the corpus called green cannot be opened at all,
and that has to come back as data rather than as a traceback.

**It has to run the game, not just open it.** The first version captured in edit
context, and the result was three different games scoring 82.7 with byte-identical
findings -- 13% clipped, 28% primitive, the same four complaints. The frames were
empty sky: these games assemble their worlds at runtime, so the editor viewport
shows nothing and the critic was measuring Studio's own UI chrome. A sweep like
that produces confident numbers about nothing, forever, and looks like it is
working. So Play Solo starts before the shutter.
"""

from __future__ import annotations

import random
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


#: The part of a Studio screenshot that is the game, as fractions of the frame.
#:
#: `critique_scene` has always taken a `viewport` and its docstring has always
#: said why -- "without it the ribbon and the property panel are measured as
#: part of the scene, and a busy editor makes an empty world look detailed" --
#: and **not one caller in the repository passed it**. A documented trap that
#: nobody honoured.
#:
#: The cost is not subtle. The horror game measured 44% of the frame clipped,
#: most of it Studio's own dark toolbar and property panel rather than the night
#: it was actually rendering.
#:
#: Measured off captures from this machine's Studio layout at 1296x930. A
#: different window arrangement needs a different crop, which is why it is a
#: parameter rather than a constant buried in the call.
STUDIO_VIEWPORT = (0.133, 0.185, 0.856, 0.919)


@dataclass
class Look:
    """What one game looked like when somebody opened it."""

    id: str
    genre: str
    opened: bool
    #: Whether the game was actually running when the shutter fired. False means
    #: the frame is an editor viewport, which for a runtime-assembled world is
    #: a photograph of nothing.
    ran: bool = False
    score: float | None = None
    axes: dict[str, float] = field(default_factory=dict)
    findings: list[str] = field(default_factory=list)
    frame: str = ""
    error: str = ""
    seconds: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "genre": self.genre,
            "opened": self.opened,
            "ran": self.ran,
            "score": None if self.score is None else round(self.score, 1),
            "axes": {name: round(value, 1) for name, value in self.axes.items()},
            "findings": self.findings[:8],
            "frame": self.frame,
            "error": self.error,
            "seconds": round(self.seconds, 1),
        }


def place_for(root: Path, game_id: str) -> Path | None:
    """The built place file, or nothing if this game was never built."""

    folder = root / "games" / game_id
    if not folder.is_dir():
        return None
    for suffix in (".rbxlx", ".rbxl"):
        found = sorted(folder.glob(f"*{suffix}"))
        if found:
            return found[0]
    return None


def look_at(root: Path, game_id: str, *, genre: str = "",
            viewpoint: str = "corpus", run: bool = True,
            viewport: tuple[float, float, float, float] | None = None,
            allow_cold_launch: bool = False) -> Look:
    """Open one built game, photograph it, and score the picture.

    Every failure is caught and returned. A corpus sweep that stops on the first
    game with no place file tells you about one game; this tells you about all
    of them, which is the only version worth running.
    """

    started = time.monotonic()
    look = Look(id=game_id, genre=genre, opened=False)

    place = place_for(root, game_id)
    if place is None:
        look.error = f"no built place in games/{game_id}"
        look.seconds = time.monotonic() - started
        return look

    try:
        from .capture import capture_native_viewpoint
        from .hub.client import StudioBridge
        from .hub.lifecycle import ensure_studio_session
    except Exception as error:  # noqa: BLE001
        look.error = f"cannot reach the Studio layer: {error}"
        look.seconds = time.monotonic() - started
        return look

    try:
        bridge = StudioBridge()
        ensured = ensure_studio_session(
            place,
            root / ".tmp" / "corpus-recovery",
            bridge,
            wait_seconds=45,
            background=True,
            allow_cold_launch=allow_cold_launch,
        )
        if not ensured.get("ready"):
            look.error = (
                "no compatible persistent Studio session for this place; "
                "cold launch is disabled"
            )
            look.seconds = time.monotonic() - started
            return look
        session = bridge.pin_to_any()
        look.opened = True
    except Exception as error:  # noqa: BLE001
        look.error = f"the place did not open: {error}"
        look.seconds = time.monotonic() - started
        return look

    if run:
        try:
            from .hub.lifecycle import start_play_solo

            started_play = start_play_solo(
                bridge,
                allow_foreground_fallback=False,
            )
            if not started_play.get("started"):
                raise RuntimeError(
                    started_play.get("reason")
                    or "StudioTestService did not start Play Mode"
                )
            # Re-pin. The session pinned before Play Solo is the *editor*, and
            # a play session is a different one -- so every bridge call kept
            # landing in the editor while the game ran beside it, and the
            # capture's own integrity check caught it: "camera.focus ran in the
            # editor, and this capture was asked for as gameplay evidence".
            session = bridge.pin_to_running()
            look.ran = True
        except Exception as error:  # noqa: BLE001
            # Worth reporting rather than falling back silently to an edit
            # capture, which is what produced identical scores for every game.
            look.error = f"opened but would not run: {error}"
            look.seconds = time.monotonic() - started
            return look

    output = root / ".tmp" / "corpus-frames"
    output.mkdir(parents=True, exist_ok=True)
    frame = output / f"{game_id}.png"

    try:
        with bridge.lease_scope(
            agent_id="corpus-visual-capture",
            session_id=session,
            ttl_seconds=120.0,
        ):
            capture_native_viewpoint(
                bridge, world_only=not run, target="",
                output=frame, viewpoint=viewpoint,
                expected_place="", expected_session=session,
                include_ui=True)
        look.frame = str(frame)
    except Exception as error:  # noqa: BLE001
        look.error = f"opened but could not be photographed: {error}"
        look.seconds = time.monotonic() - started
        return look

    try:
        from .scene.critic import critique_scene

        critique = critique_scene({viewpoint: frame}, viewport=viewport)
        look.score = critique.overall
        look.axes = dict(critique.scores)
        # `Finding.finding`, not `.message`. Reading a field name from memory
        # instead of the dataclass cost a whole sweep: every game opened,
        # photographed and scored, and then reported as unjudgeable.
        look.findings = [
            f"{item.axis}: {item.finding}" for item in critique.findings
        ]
    except Exception as error:  # noqa: BLE001
        look.error = f"photographed but could not be judged: {error}"

    look.seconds = time.monotonic() - started
    return look


def sweep(root: Path, games: list[tuple[str, str]], *,
          sample: int = 4, seed: int = 1, run: bool = True,
          viewport: tuple[float, float, float, float] | None = None,
          allow_cold_launch: bool = False,
          ) -> dict[str, Any]:
    """Open a deterministic sample of built games and report what they look like.

    `sample=0` means all of them, which is the honest full sweep and costs
    minutes per game. The default is small because a sample that runs is worth
    more than a sweep that nobody starts.
    """

    chosen = list(games)
    if sample and sample < len(chosen):
        # Seeded, so two runs open the same games and their scores can be
        # compared. An unseeded sample makes every regression look like noise.
        chosen = random.Random(seed).sample(chosen, sample)
    chosen.sort()

    looks = [
        look_at(
            root,
            game_id,
            genre=genre,
            run=run,
            viewport=viewport,
            allow_cold_launch=allow_cold_launch,
        )
        for game_id, genre in chosen
    ]
    opened = [look for look in looks if look.opened]
    ran = [look for look in opened if look.ran]
    # Only frames from a running game are counted: an edit-context frame of a
    # runtime-assembled world scores whatever Studio's UI happens to score.
    scored = [look for look in (ran if run else opened) if look.score is not None]

    return {
        "schemaVersion": 1,
        "asked": len(games),
        "sampled": len(chosen),
        "seed": seed,
        "viewport": list(viewport) if viewport else None,
        "opened": len(opened),
        "ran": len(ran),
        "scored": len(scored),
        "meanScore": (
            round(sum(look.score or 0 for look in scored) / len(scored), 1)
            if scored else None
        ),
        "worst": min(
            (look.to_dict() for look in scored),
            key=lambda entry: entry["score"], default=None),
        "looks": [look.to_dict() for look in looks],
        "note": (
            "Building is not looking. A brief that passes the corpus has proven "
            "the factory did not error; this is the only part that reports what "
            "a person would actually see."
        ),
    }
