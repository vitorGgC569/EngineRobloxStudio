"""Product primitives for first-session direction and semantic targeting.

These tests execute the shipped Luau. In particular, the target guard never
counts Models named ``Tower``: generated catalogue ids rename built towers, so
that instrument cannot prove a purchase moved.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from rqe.luau_check import ToolchainUnavailable, ensure_compiler
from rqe.luau_harness import run_or_raise


ROOT = Path(__file__).resolve().parents[1]
GAMEKIT = "roblox/lib/GameKit"
WORLDKIT = "roblox/lib/WorldKit"


def _tokens() -> dict:
    return json.loads((ROOT / "tokens/brickfarm.json").read_text(encoding="utf-8"))


class ProductPrimitiveCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        try:
            ensure_compiler(ROOT)
        except ToolchainUnavailable as exc:
            raise AssertionError(f"Luau runtime unavailable: {exc}") from exc

    def values(self, body: str, *, libraries: tuple[str, ...], data=None) -> dict:
        result = run_or_raise(ROOT, libraries=libraries, body=body, data=data or {})
        decoded = result.json_lines()
        self.assertTrue(decoded, result.stdout)
        return decoded[-1]


class TestOnboarding(ProductPrimitiveCase):
    SETUP = """
        local Onboarding = Require("Onboarding")
        local player = Harness.makePlayer(41, "Builder")
        local flow = Onboarding.define({
            id = "first-loop",
            steps = {
                { id = "earn", instruction = "Collect supplies", event = "reward_collected", targetId = "supply-core" },
                { id = "build", instruction = "Build a defender", event = "purchase_committed", targetId = "build-site-primary",
                  accept = function(detail) return detail.kind == "tower" end },
            },
        })
    """

    def test_out_of_order_effect_is_consumed_without_advancing(self) -> None:
        body = self.SETUP + """
            flow.start(player)
            local early = flow.observe(player, "purchase_committed", "purchase:7", { kind = "tower" })
            local earned = flow.observe(player, "reward_collected", "reward:3", {})
            local replay = flow.observe(player, "purchase_committed", "purchase:7", { kind = "tower" })
            local snapshot = flow.snapshot(player)
            print(string.format('{"early":"%s","earned":"%s","replay":"%s","step":"%s","complete":%s}',
                early.outcome, earned.outcome, replay.outcome, snapshot.currentStepId, tostring(snapshot.finished)))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertEqual(result["early"], "OUT_OF_ORDER")
        self.assertEqual(result["earned"], "ADVANCED")
        self.assertEqual(result["replay"], "DUPLICATE_EFFECT")
        self.assertEqual(result["step"], "build")
        self.assertFalse(result["complete"])

    def test_only_the_named_authoritative_effect_completes_the_step(self) -> None:
        body = self.SETUP + """
            local first = flow.observe(player, "reward_collected", "reward:1", {})
            local wrongKind = flow.observe(player, "purchase_committed", "purchase:1", { kind = "wall" })
            local bought = flow.observe(player, "purchase_committed", "purchase:2", { kind = "tower" })
            local snapshot = flow.snapshot(player)
            print(string.format('{"first":"%s","wrong":"%s","bought":"%s","revision":%d,"complete":%s,"completed":%d}',
                first.outcome, wrongKind.outcome, bought.outcome, snapshot.revision,
                tostring(snapshot.finished), #snapshot.completed))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertEqual(result["first"], "ADVANCED")
        self.assertEqual(result["wrong"], "OUT_OF_ORDER")
        self.assertEqual(result["bought"], "COMPLETED")
        self.assertTrue(result["complete"])
        self.assertEqual(result["completed"], 2)
        self.assertGreaterEqual(result["revision"], 3)

    def test_duplicate_step_ids_are_refused_before_a_session_starts(self) -> None:
        body = """
            local Onboarding = Require("Onboarding")
            local ok, message = pcall(function()
                Onboarding.define({ id = "bad", steps = {
                    { id = "same", instruction = "One", event = "one" },
                    { id = "same", instruction = "Two", event = "two" },
                }})
            end)
            print(string.format('{"ok":%s,"named":%s}', tostring(ok),
                tostring(string.find(tostring(message), "declared twice") ~= nil)))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertFalse(result["ok"])
        self.assertTrue(result["named"])

    def test_server_publishes_a_black_box_progress_surface(self) -> None:
        body = """
            local Onboarding = Require("Onboarding")
            local attributes = {}
            local player = { UserId = 73 }
            function player:SetAttribute(name, value) attributes[name] = value end
            local flow = Onboarding.define({ id = "intro", steps = {
                { id = "interact", instruction = "Use the console", event = "console_used", targetId = "console-primary" },
            }})
            flow.start(player)
            local before = attributes.RQEOnboardingRevision
            flow.observe(player, "console_used", "console:73:1", {})
            print(string.format('{"before":%d,"after":%d,"complete":%s,"effect":"%s","id":"%s"}',
                before, attributes.RQEOnboardingRevision, tostring(attributes.RQEOnboardingComplete),
                attributes.RQEOnboardingLastEffect, attributes.RQEOnboardingId))
        """
        result = self.values(body, libraries=(GAMEKIT,))
        self.assertGreater(result["after"], result["before"])
        self.assertTrue(result["complete"])
        self.assertEqual(result["effect"], "console:73:1")
        self.assertEqual(result["id"], "intro")


class TestGuidance(ProductPrimitiveCase):
    SETUP = """
        local Tokens = Require("Tokens")
        local Guidance = Require("Guidance")
        local tokens = Tokens.define(TOKENS)
        local world = Instance.new("Folder")
        world.Name = "World"
        local target = Instance.new("Part")
        target.Name = "Pad_1"
        target.Size = Vector3.new(10, 1, 10)
        target.Parent = world
    """

    def test_probe_uses_semantic_identity_after_the_target_is_renamed(self) -> None:
        body = self.SETUP + """
            local handle = Guidance.focus(tokens, target, {
                id = "build-site-primary", action = "Build defender", maxDistance = 60,
            })
            target.Name = "catalogue_archer_t1"
            local probe = Guidance.probe(world, "build-site-primary")
            print(string.format('{"status":"%s","observable":%s,"active":%s,"targets":%d,"cues":%d,"revision":%d}',
                probe.status, tostring(probe.observable), tostring(probe.active),
                probe.targets, probe.cues, probe.revision or -1))
        """
        result = self.values(body, libraries=(WORLDKIT,), data={"TOKENS": _tokens()})
        self.assertEqual(result["status"], "ACTIVE")
        self.assertTrue(result["observable"])
        self.assertTrue(result["active"])
        self.assertEqual(result["targets"], 1)
        self.assertEqual(result["cues"], 1)

    def test_probe_distinguishes_inactive_from_not_observable(self) -> None:
        body = self.SETUP + """
            Guidance.focus(tokens, target, { id = "first-purchase", action = "Buy" })
            Guidance.clear(target, "first-purchase")
            local inactive = Guidance.probe(world, "first-purchase")
            local blind = Guidance.probe(world, "never-marked")
            print(string.format('{"inactive":"%s","inactiveObservable":%s,"blind":"%s","blindObservable":%s}',
                inactive.status, tostring(inactive.observable), blind.status, tostring(blind.observable)))
        """
        result = self.values(body, libraries=(WORLDKIT,), data={"TOKENS": _tokens()})
        self.assertEqual(result["inactive"], "INACTIVE")
        self.assertTrue(result["inactiveObservable"])
        self.assertEqual(result["blind"], "NOT_OBSERVABLE")
        self.assertFalse(result["blindObservable"])

    def test_duplicate_semantic_targets_are_ambiguous_not_a_pass(self) -> None:
        body = self.SETUP + """
            Guidance.focus(tokens, target, { id = "purchase", action = "Buy" })
            local other = Instance.new("Part")
            other.Name = "UnrelatedName"
            other.Parent = world
            Guidance.focus(tokens, other, { id = "purchase", action = "Buy" })
            local probe = Guidance.probe(world, "purchase")
            print(string.format('{"status":"%s","active":%s,"targets":%d}',
                probe.status, tostring(probe.active), probe.targets))
        """
        result = self.values(body, libraries=(WORLDKIT,), data={"TOKENS": _tokens()})
        self.assertEqual(result["status"], "AMBIGUOUS")
        self.assertFalse(result["active"])
        self.assertEqual(result["targets"], 2)


if __name__ == "__main__":
    unittest.main()
