from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from forge.cli import playtest, publish, rollback
from rqe.orchestrator.metrics import MetricsError, verify_finalized_run
from rqe.release import _build_place, _needs_play_session
from rqe.release_authority import verify_release_payload
from rqe.run_artifacts import RunArtifacts


def release_run(root: Path, payload: bytes, *, allowed=True, gate_build="build") -> Path:
    run = RunArtifacts.create(root / "artifacts", "release-test")
    digest = hashlib.sha256(payload).hexdigest()
    run.write_bytes("build/game.rbxlx", payload)
    run.write_json("gate.json", {"runId":run.run_id,"buildHash":gate_build,
                                "releaseAllowed":allowed,"blockers":[]})
    run.write_json("build-manifest.json", {"buildId":"build","hashes":{"place":digest},
        "place":{"sha256":digest,"bytes":len(payload)}})
    run.finalize({"status":"PASS" if allowed else "BLOCKED", "releaseAllowed":allowed,
                  "buildId":"build","gate":"gate.json","provenance":"build-manifest.json"})
    return run.directory


class ReleaseAuthorityTests(unittest.TestCase):
    def test_additional_release_scenario_can_require_play_session(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "scenario.json").write_text(
                json.dumps({"id": "player-e2e", "requires": {"playSession": True}, "steps": [{"attach": {}}]}),
                encoding="utf-8",
            )
            project = SimpleNamespace(
                root=root,
                config={"releaseScenarios": ["scenario.json"]},
            )
            visual = SimpleNamespace(data={"evaluationStates": {}})
            self.assertTrue(_needs_play_session(project, visual))

    def test_release_requires_an_explicit_project_local_rojo_file(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            project = SimpleNamespace(root=root, config={})
            with self.assertRaisesRegex(RuntimeError, "explicit .*rojoProject"):
                _build_place(project, None, None)

            project.config = {"rojoProject": "../other/default.project.json"}
            with self.assertRaisesRegex(RuntimeError, "escapes the selected project root"):
                _build_place(project, None, None)

    def test_changed_bytes_with_identical_size_and_timestamp_are_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw)
            run=release_run(root,b"before")
            self.assertEqual(verify_release_payload(run,b"before")["bytes"],6)
            with self.assertRaisesRegex(MetricsError,"publication bytes"):
                verify_release_payload(run,b"after!")

    def test_blocked_or_cross_build_gate_never_authorizes(self):
        for params in ({"allowed":False},{"gate_build":"other"}):
            with self.subTest(params=params), tempfile.TemporaryDirectory() as raw:
                run=release_run(Path(raw),b"data",**params)
                with self.assertRaises(MetricsError): verify_release_payload(run,b"data")

    def test_artifact_changed_after_verification_is_not_read(self):
        with tempfile.TemporaryDirectory() as raw:
            run=release_run(Path(raw),b"data")
            verified=verify_finalized_run(run)
            (run/"gate.json").write_text('{}',encoding="utf8")
            with self.assertRaisesRegex(MetricsError,"changed after verification"):
                verified.read_json_artifact("gate.json")

    def test_direct_publisher_without_run_cannot_reach_network(self):
        with patch.object(publish,"_request") as request:
            with self.assertRaises(publish.PublishError): publish.publish("g")
        request.assert_not_called()

    def test_publisher_retains_frozen_payload_even_if_build_changes_during_upload(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw)
            run=release_run(root,b"reviewed")
            source=root/"g.rbxlx";source.write_bytes(b"reviewed")
            def upload(*args, **kwargs):
                self.assertEqual(kwargs["body"],b"reviewed")
                source.write_bytes(b"changed")
                return 200,json.dumps({"versionNumber":1})
            original=rollback.keep
            with patch.object(publish,"REPO",root), patch.object(publish,"targets",return_value={}), \
                 patch.object(publish,"load_key",return_value="fake"), patch.object(publish,"_request",side_effect=upload), \
                 patch.object(publish,"remember"), patch.object(rollback,"keep",wraps=rollback.keep) as keep:
                # Redirect retention inside this fixture, not the real repository.
                keep.side_effect=lambda *a,**kw: original(*a,**kw,root=root)
                result=publish.publish("g",universe_id="1",place_id="2",source=source,run_directory=run)
            self.assertTrue(result["ok"])
            self.assertEqual(rollback.history("g",root)[0].kept_path(root).read_bytes(),b"reviewed")

    def test_empty_playtest_and_timestamp_collision_are_diagnostics_only(self):
        with tempfile.TemporaryDirectory() as raw, patch.object(playtest,"RECEIPTS",Path(raw)):
            path=Path(raw)/"g.rbxlx";path.write_bytes(b"before")
            playtest.write_receipt("g",path,playtest.Report("g"))
            self.assertFalse(playtest.read_receipt("g",path)[0])
            old=playtest.stamp(path);stat=path.stat();path.write_bytes(b"after!")
            os.utime(path,ns=(stat.st_atime_ns,stat.st_mtime_ns))
            self.assertNotEqual(old,playtest.stamp(path))


if __name__ == "__main__": unittest.main()
