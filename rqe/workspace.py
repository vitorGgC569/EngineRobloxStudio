"""The machine's shared things, and who is allowed to touch them right now.

The problem
-----------

There is one Roblox Studio on a machine, one hub, and one port. The orchestrator
protects exclusive write ownership with

    rqe/orchestrator/ownership.py:68   self._lock = threading.RLock()

which is a lock **inside one process**. Two agents running as two processes --
which is the only way anybody actually runs two agents -- do not see each
other's lock at all. They restart the same Studio, open two places into it, and
photograph each other's game.

The failure mode is the bad one: not an error, but two runs that each look
successful and describe a game neither of them built.

What this is
------------

A lease on a named resource, held in a file, keyed by process id. Cross-process
because that is where the contention is, and file-based because the contending
processes share a filesystem and nothing else -- no daemon, no registry, no
service to install, which matters for a tool that has to work on a fresh
checkout.

Three properties it has to have, and each was chosen against a specific way
file locks go wrong:

  * **A dead holder does not block forever.** A lease records the pid that took
    it, and a lease whose pid is gone is stale and reclaimable. An agent killed
    mid-run must not require somebody to delete a file by hand.

  * **A live holder is never stolen.** Staleness is decided by asking the
    operating system whether that pid exists, never by a timeout -- a run that
    legitimately takes twenty minutes must not lose its Studio at minute
    fifteen.

  * **Taking it is atomic.** `O_CREAT | O_EXCL` decides the winner in the
    kernel. Two processes that check-then-write both see it free.

What it does not do
-------------------

It does not coordinate across machines, and it says so rather than pretending:
the lease file lives beside the repository, so two checkouts on two machines
sharing nothing will both proceed. That is correct for what it guards -- the
resources are local, one Studio per machine -- and stating the boundary is what
stops somebody trusting it for something else.
"""

from __future__ import annotations

import json
import os
import socket
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

from .exits import CONFLICT, Problem


#: Where leases live. Beside the repository rather than in the system temp
#: directory, so two checkouts are two workspaces -- which is the unit somebody
#: running two agents actually wants to separate.
LEASE_DIRECTORY = Path(".rqe") / "leases"

#: The resources worth serialising. Named rather than free-form so a typo is a
#: `KeyError` here instead of a lease nobody else respects.
RESOURCES = {
    "studio": "the Roblox Studio process, its open place and its session",
    "hub": "the bridge hub and its port",
    "build": "writing a place file into a game directory",
    "publish": "uploading to a Roblox experience",
}


def _alive(pid: int) -> bool:
    """Whether a process id still exists.

    Asked of the operating system rather than inferred from a timestamp. A
    heartbeat would be more precise and would need the holder to keep writing
    one; a run that blocks for four minutes inside a Studio restart writes
    nothing, and a timeout-based lease would take its Studio away mid-restart.
    """

    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes

        #: PROCESS_QUERY_LIMITED_INFORMATION. The broader
        #: PROCESS_QUERY_INFORMATION is refused for processes at a higher
        #: integrity level, which would report a live holder as dead.
        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        ctypes.windll.kernel32.CloseHandle(handle)
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        #: It exists and belongs to somebody else. Existing is the question.
        return True
    return True


@dataclass(frozen=True)
class Lease:
    """One held resource: what, by whom, since when."""

    resource: str
    pid: int
    host: str
    taken_at: float
    purpose: str = ""

    @property
    def held_for(self) -> float:
        return max(0.0, time.time() - self.taken_at)

    @property
    def stale(self) -> bool:
        #: A lease taken by a process on another host cannot be checked, so it
        #: is never stale from here. Reclaiming it would be a guess, and the
        #: guess that goes wrong takes a live agent's Studio away.
        if self.host != socket.gethostname():
            return False
        return not _alive(self.pid)

    def to_dict(self) -> dict[str, Any]:
        return {
            "resource": self.resource,
            "pid": self.pid,
            "host": self.host,
            "takenAt": self.taken_at,
            "heldForSeconds": round(self.held_for, 1),
            "purpose": self.purpose,
            "stale": self.stale,
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "Lease":
        return cls(
            resource=str(payload["resource"]),
            pid=int(payload["pid"]),
            host=str(payload.get("host", "")),
            taken_at=float(payload.get("takenAt", 0.0)),
            purpose=str(payload.get("purpose", "")),
        )


class Workspace:
    """One checkout's leases."""

    def __init__(self, root: Path | str = ".") -> None:
        self.root = Path(root).resolve()
        self.directory = self.root / LEASE_DIRECTORY

    def path(self, resource: str) -> Path:
        if resource not in RESOURCES:
            raise KeyError(
                f"unknown resource {resource!r}; known: {', '.join(sorted(RESOURCES))}")
        return self.directory / f"{resource}.lease"

    def holder(self, resource: str) -> Lease | None:
        """Who holds it, or `None` if it is free or the holder is gone."""

        path = self.path(resource)
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        try:
            lease = Lease.from_dict(payload)
        except (KeyError, TypeError, ValueError):
            #: A lease file this process cannot parse was written by something
            #: else or truncated by a crash. Treated as free rather than as a
            #: permanent block, because the alternative is a repository nobody
            #: can use until a file is deleted by hand.
            return None
        return None if lease.stale else lease

    def acquire(self, resource: str, *, purpose: str = "") -> Lease:
        """Take the lease, or raise `Problem(CONFLICT)` naming who has it."""

        self.directory.mkdir(parents=True, exist_ok=True)
        path = self.path(resource)

        held = self.holder(resource)
        if held is not None:
            if held.pid == os.getpid():
                return held  # re-entrant within one process
            raise Problem(
                CONFLICT,
                f"{resource} is held by another agent",
                detail=(f"pid {held.pid} on {held.host} has held it for "
                        f"{held.held_for:.0f}s"
                        + (f" ({held.purpose})" if held.purpose else "")),
                remedy_override=(
                    "wait for it to finish, or run in a separate checkout -- "
                    "leases are per-workspace"),
                context={"resource": resource, "holder": held.to_dict()},
            )

        lease = Lease(resource=resource, pid=os.getpid(),
                      host=socket.gethostname(), taken_at=time.time(),
                      purpose=purpose)
        payload = json.dumps(lease.to_dict(), indent=2).encode("utf-8")

        try:
            #: The kernel decides the winner. A read-then-write would let two
            #: processes both see it free, which is the exact race this exists
            #: to close.
            handle = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            #: Lost the race, or the previous holder was stale and its file is
            #: still there. `holder` above already treated stale as free, so
            #: reclaim it -- and re-check, because the reclaim itself races.
            stale = self.holder(resource)
            if stale is not None:
                raise Problem(
                    CONFLICT, f"{resource} was taken while this was starting",
                    context={"resource": resource, "holder": stale.to_dict()},
                ) from None
            path.write_bytes(payload)
            return lease

        with os.fdopen(handle, "wb") as file:
            file.write(payload)
        return lease

    def release(self, resource: str) -> bool:
        """Give it back. Only the holder may, so a crash cannot free somebody
        else's lease on the way out."""

        held = self.holder(resource)
        if held is not None and held.pid != os.getpid():
            return False
        try:
            self.path(resource).unlink()
        except OSError:
            return False
        return True

    def held(self) -> list[Lease]:
        """Every live lease in this workspace."""

        out: list[Lease] = []
        for resource in sorted(RESOURCES):
            lease = self.holder(resource)
            if lease is not None:
                out.append(lease)
        return out

    @contextmanager
    def lease(self, resource: str, *, purpose: str = "") -> Iterator[Lease]:
        """Hold it for the duration of a block, and give it back on the way out.

        Released in a `finally`, so an exception inside the block does not leave
        a lease behind. A crash that skips the `finally` is covered by the
        staleness check instead -- there is no path that blocks the next run
        forever.
        """

        taken = self.acquire(resource, purpose=purpose)
        try:
            yield taken
        finally:
            self.release(resource)


# --------------------------------------------------------------------------
# The port, in one place instead of twenty-six.


#: The default the whole repository grew up with.
DEFAULT_HUB_PORT = 8790

#: The environment variable that moves it.
#:
#: The literal `8790` appears in twenty-six places, so a second agent on the
#: same machine had no way to run its own hub. One variable is the smallest
#: change that makes two workspaces possible; the literals are being migrated
#: to `hub_url()` and each one that moves is one fewer place to disagree.
HUB_PORT_VARIABLE = "RQE_HUB_PORT"


def hub_port() -> int:
    raw = os.environ.get(HUB_PORT_VARIABLE, "")
    if not raw:
        return DEFAULT_HUB_PORT
    try:
        port = int(raw)
    except ValueError:
        raise Problem(
            2, f"{HUB_PORT_VARIABLE} is not a number: {raw!r}",
            remedy_override=f"set {HUB_PORT_VARIABLE} to a port, or unset it",
        ) from None
    if not (1 <= port <= 65535):
        raise Problem(2, f"{HUB_PORT_VARIABLE} is out of range: {port}")
    return port


#: The variable the MCP tools already honoured, kept as the outer override.
#:
#: There were two conventions and neither knew about the other: six MCP tools
#: read `RQE_HUB_URL`, and twenty other call sites had `http://127.0.0.1:8790`
#: written into them. A whole URL wins over a port because it is the more
#: specific statement -- somebody who set it meant a host as well.
HUB_URL_VARIABLE = "RQE_HUB_URL"


def hub_url() -> str:
    """Where the bridge hub is, from one place instead of twenty-six."""

    explicit = os.environ.get(HUB_URL_VARIABLE, "").strip()
    if explicit:
        return explicit.rstrip("/")
    return f"http://127.0.0.1:{hub_port()}"
