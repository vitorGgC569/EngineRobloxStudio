"""What a failure means, in a form a caller can branch on.

There were two non-zero exit codes across 33 `forge` commands, 12 `rqe`
commands and 186 MCP tools, used interchangeably. The four situations these
tests separate needed four different next actions and were indistinguishable
without reading English prose on stderr.
"""

from __future__ import annotations

import io
import json
import unittest
from unittest import mock

from rqe.exits import (
    BLOCKED,
    CONFLICT,
    ENVIRONMENT,
    FINDINGS,
    INCONCLUSIVE,
    INTERRUPTED,
    MEANINGS,
    NO_CREDENTIAL,
    NO_STUDIO,
    OK,
    RETRYABLE,
    UPSTREAM,
    USAGE,
    Problem,
    classify,
    conclusive,
    guard,
    name,
    remedy,
    report,
    succeed,
)


class TheTaxonomyItselfTests(unittest.TestCase):
    def test_every_code_is_distinct(self):
        codes = [OK, FINDINGS, USAGE, ENVIRONMENT, NO_STUDIO, NO_CREDENTIAL,
                 BLOCKED, CONFLICT, UPSTREAM]
        self.assertEqual(len(codes), len(set(codes)))

    def test_every_code_has_a_name_and_a_remedy(self):
        for code in MEANINGS:
            with self.subTest(code=code):
                self.assertTrue(name(code))
                self.assertTrue(remedy(code))

    def test_every_code_fits_a_posix_exit_status(self):
        # A code above 255 is truncated by the shell, and a truncated code is
        # a different code.
        for code in MEANINGS:
            self.assertLessEqual(code, 125, code)

    def test_only_success_is_conclusive_among_the_harness_failures(self):
        # The distinction `evidence.py` draws between a product failure and a
        # measurement failure, at the process level.
        self.assertTrue(conclusive(OK))
        self.assertTrue(conclusive(FINDINGS))
        for code in (USAGE, ENVIRONMENT, NO_STUDIO, NO_CREDENTIAL, BLOCKED,
                     CONFLICT, UPSTREAM):
            with self.subTest(code=name(code)):
                self.assertFalse(conclusive(code))

    def test_only_the_codes_a_bare_retry_can_fix_are_retryable(self):
        self.assertEqual(RETRYABLE, {NO_STUDIO, CONFLICT, UPSTREAM})
        # Retrying these unchanged can never help, so an agent that loops on
        # them loops forever.
        for code in (FINDINGS, USAGE, ENVIRONMENT, NO_CREDENTIAL, BLOCKED):
            self.assertNotIn(code, RETRYABLE)

    def test_inconclusive_and_retryable_are_different_questions(self):
        # BLOCKED is inconclusive and not retryable; NO_STUDIO is both.
        self.assertIn(BLOCKED, INCONCLUSIVE)
        self.assertNotIn(BLOCKED, RETRYABLE)
        self.assertIn(NO_STUDIO, INCONCLUSIVE)
        self.assertIn(NO_STUDIO, RETRYABLE)


class ProblemTests(unittest.TestCase):
    def test_a_problem_cannot_carry_success(self):
        with self.assertRaises(ValueError):
            Problem(OK, "this went fine")

    def test_the_envelope_carries_what_a_caller_branches_on(self):
        payload = Problem(NO_STUDIO, "no session answered").to_dict()
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["code"], NO_STUDIO)
        self.assertEqual(payload["kind"], "no-studio")
        self.assertTrue(payload["retryable"])
        self.assertFalse(payload["conclusive"])
        self.assertTrue(payload["remedy"])

    def test_a_caller_can_override_the_remedy_with_a_specific_one(self):
        problem = Problem(NO_CREDENTIAL, "the key has no datastore scope",
                          remedy_override="widen the key to datastore-api read")
        self.assertIn("datastore-api", problem.remedy)

    def test_the_human_rendering_says_it_is_not_about_the_game(self):
        text = Problem(BLOCKED, "the viewport could not be located").render("forge playtest")
        self.assertIn("forge playtest:", text)
        self.assertIn("[blocked]", text)
        self.assertIn("not a verdict about the game", text)

    def test_a_findings_failure_does_not_disclaim_itself(self):
        text = Problem(FINDINGS, "three probes failed").render()
        self.assertNotIn("not a verdict", text)

    def test_success_uses_the_same_envelope_shape(self):
        body = succeed({"shots": 2})
        self.assertTrue(body["ok"])
        self.assertEqual(body["code"], OK)
        self.assertEqual(body["shots"], 2)


class ClassifyTests(unittest.TestCase):
    """The four situations that used to share one exit code."""

    CASES = [
        (ModuleNotFoundError("No module named 'numpy'"), ENVIRONMENT),
        (FileNotFoundError("luau-compile is absent"), ENVIRONMENT),
        (RuntimeError("cannot reach the hub at http://127.0.0.1:8790"), NO_STUDIO),
        (RuntimeError("no running session answered after starting one"), NO_STUDIO),
        (RuntimeError("the bridge did not return JSON"), NO_STUDIO),
        (RuntimeError("HTTP 401 unauthorized"), NO_CREDENTIAL),
        (RuntimeError("the key has no datastore-api scope"), NO_CREDENTIAL),
        (RuntimeError("the viewport could not be located"), BLOCKED),
        (RuntimeError("the selected Studio window is minimized"), BLOCKED),
        (RuntimeError("address already in use"), CONFLICT),
        (RuntimeError("the request timed out"), UPSTREAM),
        (RuntimeError("502 bad gateway"), UPSTREAM),
        (ValueError("depth must be a number"), USAGE),
    ]

    def test_each_situation_gets_the_code_its_remedy_belongs_to(self):
        for error, expected in self.CASES:
            with self.subTest(error=str(error)[:40]):
                self.assertEqual(classify(error).code, expected)

    def test_an_unrecognised_failure_is_usage_not_findings(self):
        # The important half: an unclassified crash must never read as "the
        # game has findings", which is what `return 1` made every one of them.
        problem = classify(Exception("something nobody anticipated"))
        self.assertNotEqual(problem.code, FINDINGS)

    def test_the_original_message_survives(self):
        self.assertIn("datastore-api",
                      classify(RuntimeError("the key has no datastore-api scope")).message)


class GuardTests(unittest.TestCase):
    def test_a_raised_problem_becomes_its_own_exit_code(self):
        @guard("forge probe")
        def command() -> int:
            raise Problem(NO_STUDIO, "nothing answered")

        self.assertEqual(command(), NO_STUDIO)

    def test_an_unhandled_exception_is_classified_rather_than_dumped(self):
        @guard("forge probe")
        def command() -> int:
            raise KeyError("shots")

        code = command()
        self.assertNotEqual(code, FINDINGS)
        self.assertIn(code, INCONCLUSIVE)

    def test_a_successful_command_passes_its_own_code_through(self):
        @guard("forge probe")
        def command() -> int:
            return OK

        self.assertEqual(command(), OK)

    def test_an_interrupt_is_not_reported_as_the_game_failing(self):
        @guard("forge probe")
        def command() -> int:
            raise KeyboardInterrupt

        code = command()
        self.assertEqual(code, INTERRUPTED)
        self.assertNotEqual(code, FINDINGS)
        self.assertNotEqual(code, CONFLICT)
        self.assertNotIn(code, RETRYABLE)
        self.assertFalse(conclusive(code))
        self.assertEqual(name(code), "interrupted")
        self.assertIn("do not retry", remedy(code))


class CliInterruptTests(unittest.TestCase):
    def test_main_returns_interrupted_instead_of_success(self):
        import rqe.cli as cli

        with mock.patch.object(cli, "_dispatch", side_effect=KeyboardInterrupt):
            code = cli.main([])

        self.assertEqual(code, INTERRUPTED)
        self.assertNotEqual(code, OK)
        self.assertFalse(conclusive(code))


class ReportTests(unittest.TestCase):
    def test_json_output_is_parseable_and_complete(self):
        stream = io.StringIO()
        code = report(Problem(BLOCKED, "no client answered"),
                      command="forge inspect", as_json=True, stream=stream)
        payload = json.loads(stream.getvalue())
        self.assertEqual(code, BLOCKED)
        self.assertEqual(payload["kind"], "blocked")
        self.assertFalse(payload["conclusive"])

    def test_human_output_names_the_command_that_failed(self):
        stream = io.StringIO()
        report(Problem(ENVIRONMENT, "rojo is not on PATH"),
               command="forge build", stream=stream)
        self.assertIn("forge build:", stream.getvalue())


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
