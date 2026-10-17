"""Leases across processes, which is where the contention actually is.

The orchestrator guarded exclusive ownership with a `threading.RLock`. Two
agents are two processes, so it guarded nothing they could collide over: they
restarted the same Studio and photographed each other's game, and both runs
looked successful.

The subprocess test at the bottom is the one that matters. Everything above it
would pass against an in-process lock too.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from rqe.exits import CONFLICT
from rqe.exits import Problem
from rqe.workspace import (
    DEFAULT_HUB_PORT,
    HUB_PORT_VARIABLE,
    RESOURCES,
    Lease,
    Workspace,
    hub_port,
    hub_url,
)

REPO = Path(__file__).resolve().parents[1]


class LeaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Workspace(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_a_free_resource_has_no_holder(self):
        self.assertIsNone(self.workspace.holder("studio"))

    def test_taking_it_records_who_and_when(self):
        lease = self.workspace.acquire("studio", purpose="playtest")
        self.assertEqual(lease.pid, os.getpid())
        self.assertEqual(lease.host, socket.gethostname())
        self.assertEqual(lease.purpose, "playtest")
        self.assertEqual(self.workspace.holder("studio").pid, os.getpid())

    def test_taking_it_twice_in_one_process_is_allowed(self):
        # A command that takes the Studio and calls a helper that also takes it
        # must not deadlock against itself.
        first = self.workspace.acquire("studio")
        second = self.workspace.acquire("studio")
        self.assertEqual(first.pid, second.pid)

    def test_releasing_frees_it(self):
        self.workspace.acquire("studio")
        self.assertTrue(self.workspace.release("studio"))
        self.assertIsNone(self.workspace.holder("studio"))

    def test_an_unknown_resource_is_a_typo_not_a_new_lease(self):
        with self.assertRaises(KeyError):
            self.workspace.acquire("studioo")

    def test_the_context_manager_gives_it_back_even_on_an_exception(self):
        with self.assertRaises(RuntimeError):
            with self.workspace.lease("build"):
                raise RuntimeError("deliberate")
        self.assertIsNone(self.workspace.holder("build"))

    def test_every_named_resource_can_be_taken(self):
        for resource in RESOURCES:
            with self.subTest(resource=resource):
                with self.workspace.lease(resource):
                    self.assertIsNotNone(self.workspace.holder(resource))

    def test_held_lists_what_is_out(self):
        with self.workspace.lease("studio"), self.workspace.lease("hub"):
            names = {item.resource for item in self.workspace.held()}
        self.assertEqual(names, {"studio", "hub"})


class StalenessTests(unittest.TestCase):
    """A dead holder must not block forever; a live one must never be stolen."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.workspace = Workspace(self._tmp.name)
        self.workspace.directory.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _write(self, resource: str, **fields) -> None:
        payload = {
            "resource": resource, "pid": 999999,
            "host": socket.gethostname(), "takenAt": 0.0, "purpose": "",
        }
        payload.update(fields)
        self.workspace.path(resource).write_text(json.dumps(payload),
                                                encoding="utf-8")

    def test_a_lease_held_by_a_dead_process_is_reclaimable(self):
        # An agent killed mid-run must not require somebody to delete a file.
        self._write("studio", pid=999999)
        self.assertIsNone(self.workspace.holder("studio"))
        self.assertEqual(self.workspace.acquire("studio").pid, os.getpid())

    def test_a_lease_held_by_a_live_process_is_not_reclaimable(self):
        self._write("studio", pid=os.getppid() or os.getpid())
        held = self.workspace.holder("studio")
        self.assertIsNotNone(held, "a live holder was reported as stale")

    def test_a_lease_from_another_host_is_never_stolen(self):
        # Its pid cannot be checked from here, and guessing takes a live
        # agent's Studio away.
        self._write("studio", pid=1, host="some-other-machine")
        held = self.workspace.holder("studio")
        self.assertIsNotNone(held)
        self.assertFalse(held.stale)

    def test_a_lease_that_is_not_json_does_not_wedge_the_workspace(self):
        self.workspace.path("studio").write_text("{ truncated", encoding="utf-8")
        self.assertIsNone(self.workspace.holder("studio"))
        self.assertEqual(self.workspace.acquire("studio").pid, os.getpid())

    def test_an_age_alone_never_makes_a_lease_stale(self):
        # A Studio restart legitimately blocks for minutes. A timeout-based
        # lease would take it away mid-restart.
        self._write("studio", pid=os.getpid(), takenAt=0.0)
        held = self.workspace.holder("studio")
        self.assertIsNotNone(held)
        self.assertGreater(held.held_for, 60 * 60)
        self.assertFalse(held.stale)

    def test_only_the_holder_may_release(self):
        self._write("studio", pid=os.getppid() or os.getpid())
        self.assertFalse(self.workspace.release("studio"),
                         "a process released a lease it did not hold")


class TheCrossProcessGuarantee(unittest.TestCase):
    """The test an in-process lock cannot pass."""

    def test_a_second_process_is_refused_and_told_who_holds_it(self):
        with tempfile.TemporaryDirectory() as raw:
            workspace = Workspace(raw)
            workspace.acquire("studio", purpose="playtest carvewood")

            script = textwrap.dedent(f"""
                import json, sys
                sys.path.insert(0, {str(REPO)!r})
                from rqe.exits import Problem
                from rqe.workspace import Workspace
                try:
                    Workspace({raw!r}).acquire("studio")
                except Problem as problem:
                    print(json.dumps(problem.to_dict()))
                    sys.exit(problem.code)
                print(json.dumps({{"ok": True}}))
            """)
            done = subprocess.run([sys.executable, "-c", script],
                                  capture_output=True, text=True, timeout=60)

        self.assertEqual(done.returncode, CONFLICT,
                         f"a second process took a held lease\n{done.stdout}{done.stderr}")
        payload = json.loads(done.stdout.strip().splitlines()[-1])
        self.assertEqual(payload["kind"], "conflict")
        self.assertTrue(payload["retryable"])
        self.assertFalse(payload["conclusive"],
                         "a lease conflict says nothing about the game")
        self.assertEqual(payload["context"]["holder"]["pid"], os.getpid())
        self.assertIn("playtest carvewood", payload["detail"])

    def test_two_workspaces_do_not_contend(self):
        # Leases are per-checkout on purpose: running a second agent in a second
        # workspace is the supported way to run two at once.
        with tempfile.TemporaryDirectory() as one, tempfile.TemporaryDirectory() as two:
            Workspace(one).acquire("studio")
            Workspace(two).acquire("studio")  # must not raise


class HubPortTests(unittest.TestCase):
    def setUp(self) -> None:
        self._saved = os.environ.pop(HUB_PORT_VARIABLE, None)

    def tearDown(self) -> None:
        os.environ.pop(HUB_PORT_VARIABLE, None)
        if self._saved is not None:
            os.environ[HUB_PORT_VARIABLE] = self._saved

    def test_the_default_is_what_the_repository_grew_up_with(self):
        self.assertEqual(hub_port(), DEFAULT_HUB_PORT)
        self.assertEqual(hub_url(), f"http://127.0.0.1:{DEFAULT_HUB_PORT}")

    def test_the_variable_moves_it(self):
        os.environ[HUB_PORT_VARIABLE] = "8801"
        self.assertEqual(hub_port(), 8801)
        self.assertEqual(hub_url(), "http://127.0.0.1:8801")

    def test_a_port_that_is_not_a_number_is_a_usage_error_not_a_crash(self):
        os.environ[HUB_PORT_VARIABLE] = "eight thousand"
        with self.assertRaises(Problem) as raised:
            hub_port()
        self.assertEqual(raised.exception.code, 2)

    def test_a_port_out_of_range_is_refused(self):
        os.environ[HUB_PORT_VARIABLE] = "99999"
        with self.assertRaises(Problem):
            hub_port()


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
