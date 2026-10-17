import unittest

from rqe.observe import (
    DEFAULT_OBSERVE_CONFIG,
    Observation,
    _measure_logs,
    _measure_regions,
    _measure_runtime,
    _measure_world,
)


_SUMMARY_PROBES = ("instance_budget", "parts_below_floor", "unanchored_parts")


class WorldSummaryTests(unittest.TestCase):
    def measure(self, summary):
        observation = Observation(run_id="summary", started_at="now", context="server", place={})

        class Collector:
            def call(self, method, timeout=30):
                self.method = method
                return summary

            def find_all(self, _params):
                return None

        _measure_world(Collector(), observation, {}, DEFAULT_OBSERVE_CONFIG["budgets"])
        return observation

    def records(self, observation):
        return {item.probe: item for item in observation.evidence if item.probe in _SUMMARY_PROBES}

    def test_omitted_counts_are_not_a_measurement_of_zero(self):
        observation = self.measure({})
        found = self.records(observation)
        self.assertEqual(set(found), set(_SUMMARY_PROBES))
        self.assertEqual(observation.findings, [])
        for probe, item in found.items():
            self.assertNotEqual(item.status, "PASS", probe)
            self.assertNotEqual(item.status, "FAIL", probe)
            self.assertFalse(item.conclusive, probe)
            self.assertIn("was not in the world summary", item.message)
            self.assertEqual(item.source, "studio-bridge")

        counted = self.measure({"partsBelowY": {"threshold": -20}})
        below = self.records(counted)["parts_below_floor"]
        self.assertEqual(below.status, "WARN")
        self.assertFalse(below.conclusive)
        self.assertIn("partsBelowY.count", below.message)
        self.assertEqual(counted.findings, [])

    def test_a_reported_zero_still_passes(self):
        observation = self.measure({
            "workspaceDescendants": 0,
            "partsBelowY": {"count": 0, "threshold": -20},
            "unanchoredParts": 0,
        })
        found = self.records(observation)
        self.assertEqual(found["instance_budget"].status, "PASS")
        self.assertEqual(found["parts_below_floor"].status, "PASS")
        self.assertEqual(found["unanchored_parts"].status, "PASS")
        self.assertEqual(observation.findings, [])

    def test_a_reported_count_over_budget_still_fails_or_warns(self):
        observation = self.measure({
            "workspaceDescendants": 25001,
            "partsBelowY": {"count": 2, "threshold": -20},
            "unanchoredParts": 201,
        })
        found = self.records(observation)
        self.assertEqual(found["instance_budget"].status, "FAIL")
        self.assertEqual(found["parts_below_floor"].status, "FAIL")
        self.assertEqual(found["unanchored_parts"].status, "WARN")
        self.assertEqual(len(observation.findings), 2)


class GroundSupportTests(unittest.TestCase):
    def measure(self, support):
        observation = Observation(run_id="ground", started_at="now", context="server", place={})

        class Collector:
            def call(self, method, params=None, timeout=30):
                if method == "world.summary":
                    return {
                        "workspaceDescendants": 0,
                        "partsBelowY": {"count": 0},
                        "unanchoredParts": 0,
                    }
                if method == "world.ground_support":
                    return support
                return None

            def find_all(self, _params):
                return {"results": [{"path": "Workspace.Spawn", "ref": "spawn1"}], "truncated": False}

        _measure_world(
            Collector(),
            observation,
            {"groundSupportSamples": 9, "groundSupportMaxGap": 1.5},
            DEFAULT_OBSERVE_CONFIG["budgets"],
        )
        return observation

    def ground(self, observation):
        return next(item for item in observation.evidence if item.probe == "ground_support")

    def test_omitted_supported_is_not_a_failure(self):
        for support in ({"sampledPoints": 4}, {"supported": 1}, {"supported": "yes"}):
            observation = self.measure(support)
            item = self.ground(observation)
            self.assertNotEqual(item.status, "PASS")
            self.assertNotEqual(item.status, "FAIL")
            self.assertFalse(item.conclusive)
            self.assertEqual(observation.findings, [])

    def test_an_unsupported_spawn_still_fails(self):
        observation = self.measure({"supported": False, "unsupportedPoints": [{"gap": 3}]})
        item = self.ground(observation)
        self.assertEqual(item.status, "FAIL")
        self.assertEqual(len(observation.findings), 1)
        self.assertIn("Workspace.Spawn", observation.findings[0]["location"])

    def test_a_supported_spawn_still_passes(self):
        observation = self.measure({"supported": True, "sampledPoints": 4, "supportCoverage": 1})
        item = self.ground(observation)
        self.assertEqual(item.status, "PASS")
        self.assertEqual(observation.findings, [])


class SpawnSearchTests(unittest.TestCase):
    def measure(self, spawns):
        observation = Observation(run_id="spawns", started_at="now", context="server", place={})

        class Collector:
            def call(self, method, params=None, timeout=30):
                if method == "world.summary":
                    return {
                        "workspaceDescendants": 0,
                        "partsBelowY": {"count": 0},
                        "unanchoredParts": 0,
                    }
                return None

            def find_all(self, _params):
                return spawns

        _measure_world(
            Collector(),
            observation,
            {"groundSupportSamples": 9, "groundSupportMaxGap": 1.5},
            DEFAULT_OBSERVE_CONFIG["budgets"],
        )
        return observation

    def spawn(self, observation):
        return next(item for item in observation.evidence if item.probe == "spawn_exists")

    def test_omitted_results_are_not_zero_spawns(self):
        observation = self.measure({"truncated": False})
        item = self.spawn(observation)
        self.assertNotEqual(item.status, "FAIL")
        self.assertNotEqual(item.status, "PASS")
        self.assertFalse(item.conclusive)
        self.assertFalse(any("SpawnLocation" in finding["finding"] for finding in observation.findings))

    def test_an_empty_result_list_still_fails(self):
        observation = self.measure({"results": [], "truncated": False})
        item = self.spawn(observation)
        self.assertEqual(item.status, "FAIL")
        self.assertTrue(any("no SpawnLocation" in finding["finding"] for finding in observation.findings))

    def test_a_spawn_result_still_passes(self):
        observation = self.measure({
            "results": [{"path": "Workspace.Spawn", "ref": "spawn1"}],
            "truncated": False,
        })
        item = self.spawn(observation)
        self.assertEqual(item.status, "PASS")
        self.assertTrue(observation.measurements["spawnDiscoveryComplete"])

    def test_omitted_truncated_is_not_complete_discovery(self):
        observation = self.measure({"results": [{"path": "Workspace.Spawn", "ref": "spawn1"}]})
        self.assertIsNot(observation.measurements.get("spawnDiscoveryComplete"), True)


class RegionOverlapTests(unittest.TestCase):
    def measure(self, overlaps):
        observation = Observation(run_id="regions", started_at="now", context="server", place={})

        class Collector:
            def call(self, method, params=None, timeout=30):
                if method == "dm.find":
                    return {
                        "results": [
                            {"path": "Workspace.PlotA", "ref": "a"},
                            {"path": "Workspace.PlotB", "ref": "b"},
                        ],
                    }
                if method == "world.overlaps":
                    return overlaps
                return None

        _measure_regions(Collector(), observation, {
            "regionTag": "QARegion",
            "regionNamePattern": "^Plot",
            "regionRoot": "game.Workspace",
        })
        return observation

    def overlap(self, observation):
        return next(item for item in observation.evidence if item.probe == "spatial_overlap")

    def test_omitted_clean_is_not_a_collision(self):
        for overlaps in ({"regions": 2}, {"clean": 1}, {"clean": "yes"}):
            observation = self.measure(overlaps)
            item = self.overlap(observation)
            self.assertNotEqual(item.status, "PASS")
            self.assertNotEqual(item.status, "FAIL")
            self.assertFalse(item.conclusive)
            self.assertEqual(observation.findings, [])

    def test_reported_overlap_still_fails(self):
        observation = self.measure({"clean": False, "regions": 2, "overlapping": 1})
        self.assertEqual(self.overlap(observation).status, "FAIL")

    def test_clean_regions_still_pass(self):
        observation = self.measure({"clean": True, "regions": 2, "overlapping": 0})
        item = self.overlap(observation)
        self.assertEqual(item.status, "PASS")
        self.assertEqual(observation.findings, [])


class RegionDiscoveryTests(unittest.TestCase):
    def measure(self, replies, name_pattern="^Plot"):
        observation = Observation(run_id="region-discovery", started_at="now", context="server", place={})
        pending = list(replies)

        class Collector:
            def __init__(self):
                self.finds = []

            def call(self, method, params=None, timeout=30):
                if method == "dm.find":
                    self.finds.append(params or {})
                    return pending.pop(0)
                if method == "world.overlaps":
                    return {"clean": True, "regions": 2, "overlapping": 0}
                return None

        collector = Collector()
        config = {"regionTag": "QARegion", "regionRoot": "game.Workspace"}
        if name_pattern is not None:
            config["regionNamePattern"] = name_pattern
        _measure_regions(collector, observation, config)
        return observation, collector

    def overlap(self, observation):
        return next(item for item in observation.evidence if item.probe == "spatial_overlap")

    def test_missing_tag_results_are_not_zero_regions(self):
        for reply in (None, {}):
            observation, collector = self.measure([reply, {"results": [
                {"path": "Workspace.PlotA", "ref": "a"},
                {"path": "Workspace.PlotB", "ref": "b"},
            ]}])
            item = self.overlap(observation)
            self.assertEqual(item.status, "WARN")
            self.assertNotEqual(item.status, "PASS")
            self.assertNotEqual(item.status, "FAIL")
            self.assertFalse(item.conclusive)
            self.assertNotIn("only", item.message)
            self.assertEqual(len(collector.finds), 1)
            self.assertNotIn("regions", observation.measurements)

    def test_empty_tag_list_still_uses_the_name_pattern(self):
        observation, collector = self.measure([
            {"results": []},
            {"results": [
                {"path": "Workspace.PlotA", "ref": "a"},
                {"path": "Workspace.PlotB", "ref": "b"},
            ]},
        ])
        self.assertEqual(len(collector.finds), 2)
        self.assertEqual(self.overlap(observation).status, "PASS")

    def test_missing_name_pattern_results_are_not_zero_regions(self):
        for reply in (None, {}):
            observation, _collector = self.measure([{"results": []}, reply])
            item = self.overlap(observation)
            self.assertEqual(item.status, "WARN")
            self.assertFalse(item.conclusive)
            self.assertNotIn("only", item.message)
            self.assertNotIn("regions", observation.measurements)

    def test_explicit_empty_lists_keep_the_region_count_warning(self):
        observation, _collector = self.measure([{"results": []}, {"results": []}])
        item = self.overlap(observation)
        self.assertIn("only 0 exclusive region", item.message)
        self.assertTrue(item.conclusive)
        self.assertEqual(observation.measurements["regions"]["count"], 0)


class LogMeasurementTests(unittest.TestCase):
    def measure(self, tail, client):
        observation = Observation(run_id="logs", started_at="now", context="server", place={})

        class Collector:
            def call(self, method, params=None, timeout=30):
                if method == "log.tail":
                    return tail
                if method == "client.logs":
                    return client
                return None

        _measure_logs(Collector(), observation)
        return observation

    def record(self, observation, evidence_id):
        return next(item for item in observation.evidence if item.id == evidence_id)

    def test_omitted_server_error_count_is_not_zero(self):
        boom = {"severity": "error", "message": "boom", "timestamp": 1}
        for tail in ({}, {"counts": {}}, {"entries": [boom]}):
            observation = self.measure(tail, {"available": True, "counts": {"error": 0}})
            item = self.record(observation, "runtime.console_errors")
            self.assertNotEqual(item.status, "PASS")
            self.assertNotEqual(item.status, "FAIL")
            self.assertFalse(item.conclusive)
            self.assertEqual(observation.findings, [])

    def test_a_reported_server_zero_still_passes(self):
        observation = self.measure({"counts": {"error": 0}}, {"available": True, "counts": {"error": 0}})
        self.assertEqual(self.record(observation, "runtime.console_errors").status, "PASS")
        self.assertEqual(observation.findings, [])

    def test_reported_server_errors_still_fail(self):
        observation = self.measure(
            {"counts": {"error": 2}, "entries": [{"severity": "error", "message": "boom", "timestamp": 1}]},
            {"available": True, "counts": {"error": 0}},
        )
        self.assertEqual(self.record(observation, "runtime.console_errors").status, "FAIL")
        self.assertTrue(any("boom" in finding["finding"] for finding in observation.findings))

    def test_omitted_client_error_count_is_not_zero(self):
        boom = {"severity": "error", "message": "client boom", "timestamp": 1}
        for client in ({"available": True}, {"available": True, "counts": {}}, {"available": True, "entries": [boom]}):
            observation = self.measure({"counts": {"error": 0}}, client)
            item = self.record(observation, "runtime.client_errors")
            self.assertNotEqual(item.status, "PASS")
            self.assertNotEqual(item.status, "FAIL")
            self.assertFalse(item.conclusive)
            self.assertEqual(observation.findings, [])

    def test_a_reported_client_zero_still_passes(self):
        observation = self.measure({"counts": {"error": 0}}, {"available": True, "counts": {"error": 0}})
        self.assertEqual(self.record(observation, "runtime.client_errors").status, "PASS")

    def test_reported_client_errors_still_fail(self):
        observation = self.measure(
            {"counts": {"error": 0}},
            {
                "available": True,
                "counts": {"error": 1},
                "entries": [{"severity": "error", "message": "client boom", "timestamp": 2}],
                "player": "PlayerOne",
            },
        )
        self.assertEqual(self.record(observation, "runtime.client_errors").status, "FAIL")
        self.assertTrue(any("client boom" in finding["finding"] for finding in observation.findings))

    def test_missing_client_availability_stays_a_warning(self):
        observation = self.measure({"counts": {"error": 0}}, {})
        item = self.record(observation, "runtime.client_errors")
        self.assertEqual(item.status, "WARN")
        self.assertFalse(item.conclusive)


class FrameRateTests(unittest.TestCase):
    def measure(self, runtime, is_running="omit"):
        observation = Observation(run_id="runtime", started_at="now", context="server", place={})
        state = {"context": "play" if is_running else "edit", "runtime": runtime}
        if is_running != "omit":
            state["isRunning"] = is_running

        class Response:
            ok = False
            result = None

        class Bridge:
            def call_response(self, method, params=None, timeout=30):
                return Response()

        class Collector:
            bridge = Bridge()

            def call(self, method, params=None, timeout=30):
                if method == "run.state":
                    return state
                return None

        # No readiness marker and no quiet period: these tests describe the
        # verdict from a sample, not how the sample got taken. The settle has
        # its own coverage in `test_performance_settle.py`.
        config = {
            **DEFAULT_OBSERVE_CONFIG,
            "runtimeReadyPath": "",
            "runtimeSettleSeconds": 0.0,
        }
        _measure_runtime(Collector(), observation, DEFAULT_OBSERVE_CONFIG["budgets"], config)
        return observation

    def frame_rate(self, observation):
        return next(item for item in observation.evidence if item.id == "runtime.frame_rate")

    def test_omitted_frame_time_does_not_fail_a_met_frame_rate(self):
        observation = self.measure({"fps": 60, "sampleSeconds": 0.6}, True)
        item = self.frame_rate(observation)
        self.assertEqual(item.status, "WARN")
        self.assertNotEqual(item.status, "PASS")
        self.assertNotEqual(item.status, "FAIL")
        self.assertFalse(item.conclusive)
        self.assertEqual(observation.findings, [])

    def test_omitted_frame_time_still_fails_a_missed_frame_rate(self):
        observation = self.measure({"fps": 10, "sampleSeconds": 0.6}, True)
        item = self.frame_rate(observation)
        self.assertEqual(item.status, "FAIL")
        self.assertTrue(observation.findings)
        for finding in observation.findings:
            self.assertNotIn("ms", finding["finding"])
            self.assertNotIn("worst", finding["finding"].lower())
            self.assertNotIn("worstFrameMs", finding["evidence"])
        self.assertIn("FPS", observation.findings[0]["finding"])

    def test_edit_mode_without_frame_time_stays_a_warning(self):
        observation = self.measure({"fps": 10, "sampleSeconds": 0.6}, False)
        item = self.frame_rate(observation)
        self.assertEqual(item.status, "WARN")
        self.assertEqual(observation.findings, [])

    def test_a_slow_frame_still_fails(self):
        observation = self.measure({"fps": 60, "worstFrameMs": 50, "sampleSeconds": 0.6}, True)
        self.assertEqual(self.frame_rate(observation).status, "FAIL")
        self.assertTrue(any("ms frame budget" in finding["finding"] for finding in observation.findings))

    def test_within_budget_still_passes(self):
        observation = self.measure({"fps": 60, "worstFrameMs": 16, "sampleSeconds": 0.6}, True)
        item = self.frame_rate(observation)
        self.assertEqual(item.status, "PASS")
        self.assertEqual(observation.findings, [])

    def test_omitted_is_running_does_not_pass_a_sample_inside_budget(self):
        observation = self.measure({"fps": 60, "worstFrameMs": 16, "sampleSeconds": 0.6})
        item = self.frame_rate(observation)
        self.assertNotEqual(item.status, "PASS")
        self.assertNotEqual(item.status, "FAIL")
        self.assertFalse(item.conclusive)
        self.assertEqual(observation.findings, [])

    def test_non_boolean_is_running_does_not_fail_a_missed_budget(self):
        observation = self.measure({"fps": 10, "worstFrameMs": 50, "sampleSeconds": 0.6}, 1)
        item = self.frame_rate(observation)
        self.assertNotEqual(item.status, "PASS")
        self.assertNotEqual(item.status, "FAIL")
        self.assertFalse(item.conclusive)
        self.assertEqual(observation.findings, [])

    def test_edit_mode_inside_budget_still_passes(self):
        observation = self.measure({"fps": 60, "worstFrameMs": 16, "sampleSeconds": 0.6}, False)
        self.assertEqual(self.frame_rate(observation).status, "PASS")
