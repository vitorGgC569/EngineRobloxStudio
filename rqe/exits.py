"""What went wrong, in a form a caller can branch on.

The problem
-----------

Every command in this repository exits `0`, `1` or `2`. There are exactly two
non-zero codes across 33 `forge` commands, 12 `rqe` commands and 186 MCP tools,
and they are used interchangeably. So an agent driving this platform cannot
tell these four situations apart:

    the game is broken            -> fix the game
    Roblox Studio is not running  -> start Studio, then run this again
    the Open Cloud key is missing -> ask the operator for a credential
    the instrument could not look -> this says nothing about the game at all

Those need four different next actions, and the difference is the whole
difference between an agent that recovers and one that loops. Today it reads
the English prose on stderr and guesses.

The taxonomy
------------

Eight codes, and the test for whether a code deserves to exist is not "is this a
different cause" but **"does the caller do something different"**. Two causes
that lead to the same action share a code.

The distinction between `FINDINGS` and `BLOCKED` is the same one `evidence.py`
draws between a product failure and a measurement failure, raised to the process
level -- because that confusion costs the same either way. An agent that reads
"could not measure" as "the game is wrong" goes and debugs code that works.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from typing import Any, NoReturn


#: Everything asked for was done.
OK = 0

#: The thing was measured and it is not good enough. The *product* is at fault:
#: a probe failed, a scenario did not pass, a gate refused a release.
#: -> Fix the game and run this again.
FINDINGS = 1

#: The command itself was wrong: an unknown flag, a path that is not a project,
#: two options that contradict each other.
#: -> Fix the call. Running it again unchanged cannot help.
USAGE = 2

#: The installation is incomplete: a missing dependency, an absent Luau
#: toolchain, a plugin that was never installed.
#: -> `forge preflight` names what is missing and how to get it.
ENVIRONMENT = 3

#: No live Roblox Studio, no hub, or no session in the context the command
#: needs. Nothing is wrong with the game or the machine.
#: -> Start Studio (`rqe studio restart`) or a client (`studio play_solo`).
NO_STUDIO = 4

#: A credential is absent, expired, or lacks the scope this command needs.
#: -> Supply or widen the key. Never retried automatically.
NO_CREDENTIAL = 5

#: The instrument could not answer. **Not a verdict about the product.**
#: The viewport could not be located, the client never replied, the capture was
#: of an occluded window.
#: -> Fix the measurement, and do not report anything about the game.
BLOCKED = 6

#: Something else holds the resource: another agent owns the Studio, the hub
#: port is taken, a lease is live.
#: -> Wait, or work somewhere else. Retrying immediately will collide again.
CONFLICT = 7

#: A service outside this repository failed -- Roblox, Open Cloud, the network,
#: a CDN. Transient by assumption.
#: -> Retry with backoff.
UPSTREAM = 8

#: The operator stopped the process. This is 128+SIGINT, the code a shell
#: already uses for a killed command, so it stays outside `MEANINGS`: those
#: codes have to stay at or below 125 or a shell can truncate them into a
#: different action. It is not retryable and it is not a verdict about the game.
INTERRUPTED = 130


#: Code -> (short name, what the caller should do about it).
MEANINGS: dict[int, tuple[str, str]] = {
    OK: ("ok", "nothing to do"),
    FINDINGS: ("findings", "fix the game, then run this again"),
    USAGE: ("usage", "fix the command; running it again unchanged cannot help"),
    ENVIRONMENT: ("environment", "run `forge preflight` to see what is missing"),
    NO_STUDIO: ("no-studio", "start Studio with `rqe studio restart`"),
    NO_CREDENTIAL: ("no-credential", "supply a key with the scope this needs"),
    BLOCKED: ("blocked", "the instrument could not measure; this says nothing "
                         "about the game"),
    CONFLICT: ("conflict", "another agent holds this resource; wait or use "
                           "another workspace"),
    UPSTREAM: ("upstream", "a service outside this repository failed; retry "
                           "with backoff"),
}

#: Codes where retrying the identical command can succeed without anything
#: being changed first. Everything else is the caller's move.
RETRYABLE = frozenset({NO_STUDIO, CONFLICT, UPSTREAM})

#: Codes that say nothing about the product under test. An agent must not
#: report a verdict about a game from any of these.
INCONCLUSIVE = frozenset({USAGE, ENVIRONMENT, NO_STUDIO, NO_CREDENTIAL,
                          BLOCKED, CONFLICT, UPSTREAM})


def name(code: int) -> str:
    if code == INTERRUPTED:
        return "interrupted"
    return MEANINGS.get(code, ("unknown", ""))[0]


def remedy(code: int) -> str:
    if code == INTERRUPTED:
        return "the operator stopped this command; do not retry it"
    return MEANINGS.get(code, ("unknown", "no remedy is known for this code"))[1]


def conclusive(code: int) -> bool:
    """Whether this outcome is evidence about the game rather than the harness."""

    if code == INTERRUPTED:
        return False
    return code not in INCONCLUSIVE


@dataclass
class Problem(Exception):
    """One failure, classified, with what to do about it.

    Raised rather than printed, so a command's failure path is one `raise` and
    the envelope, the exit code and the human message are decided in one place
    instead of at every call site.
    """

    code: int
    message: str
    detail: str = ""
    remedy_override: str = ""
    context: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        Exception.__init__(self, self.message)
        if self.code == OK:
            raise ValueError("a Problem cannot carry the success code")

    @property
    def remedy(self) -> str:
        return self.remedy_override or remedy(self.code)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": False,
            "code": self.code,
            "kind": name(self.code),
            "message": self.message,
            "detail": self.detail,
            "remedy": self.remedy,
            "retryable": self.code in RETRYABLE,
            "conclusive": conclusive(self.code),
            "context": dict(self.context),
        }

    def render(self, command: str = "") -> str:
        head = f"{command}: " if command else ""
        lines = [f"{head}{self.message}"]
        if self.detail:
            lines.append(f"  {self.detail}")
        lines.append(f"  [{name(self.code)}] {self.remedy}")
        if not conclusive(self.code):
            lines.append("  this is a failure of the measurement, not a verdict "
                         "about the game")
        return "\n".join(lines)


def succeed(payload: dict[str, Any] | None = None) -> dict[str, Any]:
    """The success half of the same envelope, so both shapes are one shape."""

    body: dict[str, Any] = {"ok": True, "code": OK, "kind": "ok"}
    if payload:
        body.update(payload)
    return body


def report(problem: Problem, *, command: str = "", as_json: bool = False,
           stream: Any = None) -> int:
    """Print a problem the way the caller asked for it, and return its code."""

    out = stream if stream is not None else sys.stderr
    if as_json:
        print(json.dumps(problem.to_dict(), indent=2), file=out)
    else:
        print(problem.render(command), file=out)
    return problem.code


def guard(command: str, *, as_json: bool = False):
    """Wrap a command function so an unclassified crash still exits sensibly.

    An unhandled exception is `USAGE`-shaped in a CLI only by accident. It is
    reported here as its own failure with the traceback in `detail`, because the
    alternative -- a Python traceback on stderr and exit code 1 -- is
    indistinguishable from the game having findings.
    """

    import functools
    import traceback

    def decorate(function):
        @functools.wraps(function)
        def run(*args: Any, **kwargs: Any) -> int:
            try:
                return function(*args, **kwargs)
            except Problem as problem:
                return report(problem, command=command, as_json=as_json)
            except KeyboardInterrupt:
                # CONFLICT is retryable. An agent that restarts every retryable
                # exit would relaunch the command the operator just cancelled.
                print(f"{command}: interrupted", file=sys.stderr)
                return INTERRUPTED
            except Exception as exc:  # noqa: BLE001 - the point is to classify it
                problem = Problem(
                    code=USAGE,
                    message=f"{type(exc).__name__}: {exc}",
                    detail=traceback.format_exc(limit=4).strip(),
                    remedy_override="this is a defect in the tool, not in the "
                                    "game; the traceback is in `detail`",
                )
                return report(problem, command=command, as_json=as_json)

        return run

    return decorate


# --------------------------------------------------------------------------
# Classifying what the existing code already raises.


def classify(error: BaseException) -> Problem:
    """Turn one of this repository's own exceptions into a classified Problem.

    A translation table rather than a rewrite of every raise site. The modules
    that fail already say *what* went wrong in their exception types and
    messages; what they never carried was *what the caller should do*, and that
    is what this adds.
    """

    text = str(error)
    lowered = text.lower()
    kind = type(error).__name__

    if isinstance(error, (ModuleNotFoundError, ImportError)):
        return Problem(ENVIRONMENT, f"a dependency is missing: {text}",
                       remedy_override="pip install -e .[dev], then "
                                       "`forge preflight`")
    if isinstance(error, FileNotFoundError):
        return Problem(ENVIRONMENT, f"a required file is missing: {text}")

    #: Matched on the message rather than the type, because the hub reports
    #: every wire failure as one exception class and the difference between
    #: "Studio is not running" and "your key was refused" is only in the text.
    if any(token in lowered for token in
           ("no studio", "no session", "cannot reach the hub", "connection refused",
            "bridge did not return", "hub at", "no running session",
            #: The hub's own words for it. `E_DISCONNECTED` is what every
            #: command sees when Studio is open but the plugin is not loaded,
            #: which is the single most common way a live command fails.
            "e_disconnected", "no roblox studio plugin", "plugin is connected",
            "bridge returned nothing")):
        return Problem(NO_STUDIO, text or kind)
    if any(token in lowered for token in
           ("credential", "api key", "unauthorized", "401", "403", "scope")):
        return Problem(NO_CREDENTIAL, text or kind)
    if any(token in lowered for token in
           ("could not be located", "not validated", "occluded", "minimized",
            "minimised", "could not measure", "no client answered")):
        return Problem(BLOCKED, text or kind)
    if any(token in lowered for token in ("lease", "already held", "in use",
                                          "address already in use", "locked by")):
        return Problem(CONFLICT, text or kind)
    if any(token in lowered for token in ("timed out", "timeout", "temporarily",
                                          "503", "502", "bad gateway")):
        return Problem(UPSTREAM, text or kind)
    if isinstance(error, (ValueError, TypeError, KeyError)):
        return Problem(USAGE, f"{kind}: {text}")

    return Problem(USAGE, f"{kind}: {text}")
