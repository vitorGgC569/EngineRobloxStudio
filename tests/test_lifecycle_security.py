from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from rqe.hub import lifecycle


class StudioLifecycleSecurityTests(unittest.TestCase):
    def test_unowned_studio_is_reported_and_never_killed_by_image_name(self) -> None:
        with (
            patch.object(lifecycle, "studio_running", return_value=True),
            patch.object(lifecycle, "_owned_studio_processes", return_value=([], [])),
            patch.object(lifecycle.subprocess, "run") as run,
        ):
            result = lifecycle.stop_studio()
        self.assertFalse(result["stopped"])
        self.assertTrue(result["wasRunning"])
        self.assertIn("no matching RQE-owned", result["reason"])
        run.assert_not_called()

    def test_owned_shutdown_targets_only_the_receipted_pid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "4242.json"
            receipt.write_text("{}", encoding="utf-8")
            owned = [{"pid": 4242, "receipt": str(receipt)}]
            with (
                patch.object(lifecycle, "studio_running", return_value=True),
                patch.object(lifecycle, "_owned_studio_processes", return_value=(owned, [])),
                patch.object(lifecycle, "_pid_alive", return_value=False),
                patch.object(lifecycle.subprocess, "run") as run,
            ):
                result = lifecycle.stop_studio(wait_seconds=0.1)
        self.assertTrue(result["stopped"])
        command = run.call_args.args[0]
        self.assertEqual(command[:3], ["taskkill", "/PID", "4242"])
        self.assertNotIn("/IM", command)

    def test_recycled_pid_receipt_is_discarded_not_trusted(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            "os.environ", {"LOCALAPPDATA": directory}
        ):
            receipts = Path(directory) / "RQE" / lifecycle.PROCESS_RECEIPT_DIRECTORY
            receipts.mkdir(parents=True)
            receipt = receipts / "55.json"
            receipt.write_text(json.dumps({
                "pid": 55,
                "path": "C:/Roblox/RobloxStudioBeta.exe",
                "startedAt": "old-start",
            }), encoding="utf-8")
            with patch.object(lifecycle, "_process_identity", return_value={
                "pid": 55,
                "path": "C:/Roblox/RobloxStudioBeta.exe",
                "startedAt": "new-start",
            }):
                owned, ignored = lifecycle._owned_studio_processes()
            self.assertEqual(owned, [])
            self.assertEqual(ignored[0]["pid"], 55)
            self.assertFalse(receipt.exists())

    def test_restart_stops_before_touching_files_when_studio_is_unowned(self) -> None:
        bridge = Mock()
        bridge.status.return_value = {"sessions": []}
        with (
            patch.object(lifecycle, "ensure_hub", return_value={"alive": True}),
            patch.object(lifecycle, "stop_studio", return_value={
                "stopped": False,
                "wasRunning": True,
                "reason": "unowned",
            }),
            patch.object(lifecycle, "archive_recovery_files") as archive,
            patch.object(lifecycle, "launch_studio") as launch,
        ):
            result = lifecycle.restart_for_bridge("place.rbxlx", "archive", bridge=bridge)
        self.assertTrue(result["blocked"])
        archive.assert_not_called()
        launch.assert_not_called()

    def test_executable_selection_uses_signed_file_version_not_mtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            "os.environ", {"LOCALAPPDATA": directory}
        ):
            versions = Path(directory) / "Roblox" / "Versions"
            older = versions / "version-newer-mtime" / lifecycle.STUDIO_PROCESS
            newer = versions / "version-older-mtime" / lifecycle.STUDIO_PROCESS
            older.parent.mkdir(parents=True)
            newer.parent.mkdir(parents=True)
            older.write_bytes(b"older")
            newer.write_bytes(b"newer")
            older.touch()

            def metadata(path: Path) -> dict:
                version = (1, 0, 0) if path.parent.name == "version-newer-mtime" else (2, 0, 0)
                return {"path": str(path.resolve()), "versionTuple": version}

            with (
                patch.object(lifecycle, "_studio_binary_metadata", side_effect=metadata),
                patch.object(lifecycle.shutil, "which", return_value=None),
            ):
                selected = lifecycle.studio_executable()
            self.assertEqual(selected, newer.resolve())


if __name__ == "__main__":
    unittest.main()
