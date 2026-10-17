import unittest
from rqe.observe import Observation, _Collector, _measure_navigation


class NavigationCoverageTests(unittest.TestCase):
    def observation(self):
        result = Observation(run_id="coverage", started_at="now", context="server", place={})
        result.measurements["spawns"] = [{"path": "same-name", "ref": "spawn1"}, {"path": "same-name", "ref": "spawn2"}]
        return result

    def test_every_origin_and_objective_and_failed_probe_reduce_coverage(self):
        observation = self.observation()
        # The coverage arithmetic is for a finished spawn search. An omitted
        # flag is not that claim.
        observation.measurements["spawnDiscoveryComplete"] = True
        class Collector:
            calls = []
            def find_all(self, _):
                return {"results": [{"path": "duplicate", "ref": str(i)} for i in range(15)], "truncated": False}
            def call(self, _method, params, **_kwargs):
                self.calls.append(params)
                if params["fromPath"] == "ref:spawn2" and params["toPath"] == "ref:14":
                    return None
                return {"conclusive": True, "reachable": True}
        collector = Collector()
        _measure_navigation(collector, observation)
        self.assertEqual(len(collector.calls), 30)
        evidence = observation.evidence[-1]
        self.assertEqual(evidence.status, "WARN")
        self.assertAlmostEqual(evidence.coverage, 29 / 30)
        self.assertFalse(evidence.conclusive)

    def test_expired_page_cannot_report_complete_discovery(self):
        observation = self.observation()
        collector = _Collector(None, observation)
        pages = iter([{"snapshotId": "first", "truncated": True, "nextCursor": "next", "results": [{"ref": "one"}]},
                      {"snapshotId": "different", "truncated": False, "results": [{"ref": "two"}]}])
        collector.call = lambda *_a, **_k: next(pages)
        result = collector.find_all({"className": "ProximityPrompt"})
        self.assertTrue(result["truncated"])
        self.assertEqual(result["matched"], 1)
        self.assertIn("snapshot changed", result["enumerationError"])

    def test_pages_from_the_same_snapshot_are_combined(self):
        collector = _Collector(None, self.observation())
        pages = iter([{"snapshotId": "one", "truncated": True, "nextCursor": "next", "results": [{"ref": "a"}]},
                      {"snapshotId": "one", "truncated": False, "results": [{"ref": "b"}]}])
        collector.call = lambda *_a, **_k: next(pages)
        result = collector.find_all({"className": "ProximityPrompt"})
        self.assertFalse(result["truncated"])
        self.assertEqual(result["matched"], 2)

    def test_omitted_results_are_not_rewritten_as_empty(self):
        collector = _Collector(None, self.observation())
        calls = []

        def call(*_args, **_kwargs):
            calls.append(1)
            return {"snapshotId": "one", "truncated": True, "nextCursor": "next"}

        collector.call = call
        result = collector.find_all({"className": "ProximityPrompt"})
        self.assertNotIn("results", result)
        self.assertNotIn("matched", result)
        self.assertEqual(calls, [1])

    def test_explicit_empty_list_is_zero_matches(self):
        collector = _Collector(None, self.observation())
        collector.call = lambda *_args, **_kwargs: {"results": [], "truncated": False}
        result = collector.find_all({"className": "ProximityPrompt"})
        self.assertEqual(result["results"], [])
        self.assertEqual(result["matched"], 0)

    def test_later_page_without_results_stops_the_walk(self):
        collector = _Collector(None, self.observation())
        pages = iter([
            {"snapshotId": "one", "truncated": True, "nextCursor": "next", "results": [{"ref": "a"}]},
            {"snapshotId": "one", "truncated": True, "nextCursor": "after"},
        ])
        calls = []

        def call(*_args, **_kwargs):
            calls.append(1)
            return next(pages)

        collector.call = call
        result = collector.find_all({"className": "ProximityPrompt"})
        self.assertEqual(calls, [1, 1])
        self.assertTrue(result["truncated"])
        self.assertEqual(result["results"], [{"ref": "a"}])
        self.assertEqual(result["matched"], 1)
        self.assertIn("omitted results", result["enumerationError"])

    def test_later_page_without_truncated_stays_incomplete(self):
        collector = _Collector(None, self.observation())
        pages = iter([
            {"snapshotId": "one", "truncated": True, "nextCursor": "next", "results": [{"ref": "a"}]},
            {"snapshotId": "one", "results": [{"ref": "b"}], "nextCursor": "after"},
        ])
        calls = []

        def call(*_args, **_kwargs):
            calls.append(1)
            return next(pages)

        collector.call = call
        result = collector.find_all({"className": "ProximityPrompt"})
        self.assertEqual(calls, [1, 1])
        self.assertTrue(result["truncated"])
        self.assertIsNot(result["truncated"], False)
        self.assertEqual(result["results"], [{"ref": "a"}, {"ref": "b"}])
        self.assertEqual(result["matched"], 2)
        self.assertIn("whether discovery finished", result["enumerationError"])

    def test_explicit_truncated_page_continues_the_walk(self):
        collector = _Collector(None, self.observation())
        pages = iter([
            {"snapshotId": "one", "truncated": True, "nextCursor": "next", "results": [{"ref": "a"}]},
            {"snapshotId": "one", "truncated": True, "nextCursor": "after", "results": [{"ref": "b"}]},
            {"snapshotId": "one", "truncated": False, "results": [{"ref": "c"}]},
        ])
        collector.call = lambda *_args, **_kwargs: next(pages)
        result = collector.find_all({"className": "ProximityPrompt"})
        self.assertFalse(result["truncated"])
        self.assertEqual(result["matched"], 3)


class NavigationDiscoveryTests(unittest.TestCase):
    def measure(self, prompts, path=None, spawn_complete="omit"):
        observation = Observation(run_id="navigation", started_at="now", context="server", place={})
        observation.measurements["spawns"] = [{"path": "Spawn", "ref": "spawn"}]
        if spawn_complete != "omit":
            observation.measurements["spawnDiscoveryComplete"] = spawn_complete

        class Collector:
            def find_all(self, _params):
                return prompts

            def call(self, _method, params=None, timeout=30):
                return path

        _measure_navigation(Collector(), observation)
        return observation

    def record(self, observation):
        return next(item for item in observation.evidence if item.id == "navigation.objective_reachable")

    def test_omitted_truncated_does_not_pass(self):
        prompts = {"results": [{"path": "Prompt", "ref": "prompt"}]}
        observation = self.measure(prompts, {"conclusive": True, "reachable": True}, spawn_complete=True)
        item = self.record(observation)
        self.assertNotEqual(item.status, "PASS")
        self.assertEqual(item.status, "WARN")
        self.assertFalse(item.conclusive)

    def test_omitted_spawn_discovery_does_not_pass(self):
        prompts = {"results": [{"path": "Prompt", "ref": "prompt"}], "truncated": False}
        observation = self.measure(prompts, {"conclusive": True, "reachable": True})
        item = self.record(observation)
        self.assertNotEqual(item.status, "PASS")
        self.assertFalse(item.conclusive)

    def test_truncated_search_does_not_pass(self):
        prompts = {"results": [{"path": "Prompt", "ref": "prompt"}], "truncated": True}
        observation = self.measure(prompts, {"conclusive": True, "reachable": True}, spawn_complete=True)
        self.assertNotEqual(self.record(observation).status, "PASS")

    def test_finished_reachable_search_still_passes(self):
        prompts = {"results": [{"path": "Prompt", "ref": "prompt"}], "truncated": False}
        observation = self.measure(prompts, {"conclusive": True, "reachable": True}, spawn_complete=True)
        item = self.record(observation)
        self.assertEqual(item.status, "PASS")
        self.assertTrue(item.conclusive)

    def test_unreachable_pairs_still_fail(self):
        prompts = {"results": [{"path": "Prompt", "ref": "prompt"}]}
        observation = self.measure(
            prompts,
            {"conclusive": True, "reachable": False, "status": "NoPath"},
            spawn_complete=True,
        )
        self.assertEqual(self.record(observation).status, "FAIL")
        self.assertTrue(observation.findings)

    def test_omitted_results_are_not_zero_objectives(self):
        observation = self.measure({}, spawn_complete=True)
        item = self.record(observation)
        self.assertEqual(item.status, "WARN")
        self.assertFalse(item.conclusive)
        self.assertNotIn("no objectives were discovered", item.message)
        self.assertNotIn("objectives", observation.measurements)

    def test_empty_results_still_report_no_objectives(self):
        observation = self.measure({"results": [], "truncated": False}, spawn_complete=True)
        item = self.record(observation)
        self.assertEqual(item.status, "WARN")
        self.assertIn("no objectives were discovered", item.message)
        self.assertEqual(observation.measurements["objectives"], [])

    def test_omitted_reachable_is_not_unreachable(self):
        prompts = {"results": [{"path": "Prompt", "ref": "prompt"}], "truncated": False}
        for path in ({"conclusive": True}, {"conclusive": True, "reachable": "yes"}, {"conclusive": True, "reachable": 0}):
            observation = self.measure(prompts, path, spawn_complete=True)
            item = self.record(observation)
            self.assertNotEqual(item.status, "FAIL")
            self.assertNotEqual(item.status, "PASS")
            self.assertEqual(observation.findings, [])
