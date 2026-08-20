from __future__ import annotations

import tempfile
import unittest
import hashlib
from pathlib import Path

from PIL import Image

from rqe.capture import Shot, WindowIdentity, capture_set
from rqe.hub.protocol import BridgeError, Response


BUILD_BYTES = b"exact rbxlx build bytes"
SPEC_BYTES = b'{"schemaVersion":1,"specId":"capture-test"}'
BUILD_HASH = hashlib.sha256(BUILD_BYTES).hexdigest()
SPEC_HASH = hashlib.sha256(SPEC_BYTES).hexdigest()
PLACE = "QualityBuild.rbxlx"
SESSION = "sess_capture"


class FakeCaptureBackend:
    def __init__(self, windows: list[WindowIdentity] | None = None) -> None:
        self.windows = windows or [WindowIdentity(101, 202, f"C:\\builds\\{PLACE} - Roblox Studio")]
        self.current: WindowIdentity | None = self.windows[0] if self.windows else None
        self.foreground_sequence: list[WindowIdentity | None] = []

    def studio_windows(self) -> list[WindowIdentity]:
        return list(self.windows)

    def focus(self, window: WindowIdentity) -> None:
        self.current = window

    def foreground(self) -> WindowIdentity | None:
        if self.foreground_sequence:
            return self.foreground_sequence.pop(0)
        return self.current

    def grab(self, _window: WindowIdentity, output: Path) -> tuple[int, int]:
        output.parent.mkdir(parents=True, exist_ok=True)
        img = Image.new("RGB", (32, 18))
        for x in range(32):
            for y in range(18):
                img.putpixel((x, y), (x * 7 % 256, y * 13 % 256, (x + y) * 5 % 256))
        img.save(output, "PNG")
        return 32, 18


class FakeBridge:
    def __init__(self) -> None:
        self.pinned_session: str | None = None
        self.camera_gets = 0
        self.fail_camera_get: int | None = None
        self.drift = False
        self.camera_session = SESSION
        self.calls: list[tuple[str, dict]] = []

    def pin_to_running(self, timeout: float = 30) -> str:
        self.pinned_session = SESSION
        return SESSION

    def call_response(self, method: str, _params=None, timeout: float = 15) -> Response:
        params = _params or {}
        self.calls.append((method, params))
        if method == "studio.info":
            return Response(
                id="info",
                ok=True,
                result={"placeName": PLACE},
                context="run",
                place=PLACE,
                session=SESSION,
            )
        if method == "camera.focus":
            return Response(
                id="focus",
                ok=True,
                result={
                    "boundingBox": {"center": [0, 0, 0], "size": [10, 5, 10]},
                    "distance": 20,
                    "camera": self._camera(),
                },
                context="run",
                place=PLACE,
                session=self.camera_session,
            )
        if method == "world.bounds":
            return Response(
                id="bounds",
                ok=True,
                result={"center": [1, 0, 0], "size": [10, 5, 10]},
                context="run",
                place=PLACE,
                session=self.camera_session,
            )
        if method == "camera.set":
            return Response(
                id="set",
                ok=True,
                result={"applied": True, "camera": self._camera()},
                context="run",
                place=PLACE,
                session=self.camera_session,
            )
        if method == "camera.get":
            self.camera_gets += 1
            if self.fail_camera_get == self.camera_gets:
                raise BridgeError("E_EXEC", "camera unavailable")
            camera = self._camera()
            if self.drift and self.camera_gets >= 2:
                camera["position"] = [1, 2, 4]
            return Response(
                id=f"camera-{self.camera_gets}",
                ok=True,
                result=camera,
                context="run",
                place=PLACE,
                session=self.camera_session,
            )
        raise AssertionError(method)

    @staticmethod
    def _camera() -> dict:
        return {
            "position": [1, 2, 3],
            "lookVector": [0, 0, -1],
            "fieldOfView": 70,
            "viewportSize": [1280, 720],
            "cameraType": "Enum.CameraType.Scriptable",
        }


def viewpoints() -> list[dict]:
    return [{"name": "world-overview", "target": "game.Workspace.Map", "required": True, "settleSeconds": 0}]


class CaptureIntegrityTests(unittest.TestCase):
    def capture(self, directory: Path, bridge: FakeBridge | None = None, backend: FakeCaptureBackend | None = None, **kwargs):
        build_path = directory / PLACE
        spec_path = directory / "visual-spec.json"
        build_path.write_bytes(BUILD_BYTES)
        spec_path.write_bytes(SPEC_BYTES)
        return capture_set(
            bridge or FakeBridge(),
            kwargs.pop("viewpoints", viewpoints()),
            directory,
            "run-capture",
            build_hash=kwargs.pop("build_hash", BUILD_HASH),
            place_hash=kwargs.pop("place_hash", BUILD_HASH),
            spec_hash=kwargs.pop("spec_hash", SPEC_HASH),
            build_path=kwargs.pop("build_path", build_path),
            spec_path=kwargs.pop("spec_path", spec_path),
            backend=backend or FakeCaptureBackend(),
            **kwargs,
        )

    def test_an_empty_capture_set_is_not_trustworthy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), viewpoints=[])
        self.assertFalse(manifest["trustworthy"])
        self.assertEqual(manifest["shots"], [])
        self.assertTrue(any("at least one viewpoint" in item["error"] for item in manifest["failures"]))

    def test_camera_metadata_failure_invalidates_the_shot(self) -> None:
        bridge = FakeBridge()
        bridge.fail_camera_get = 2
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), bridge=bridge)
        self.assertFalse(manifest["trustworthy"])
        self.assertFalse(manifest["shots"][0]["trustworthy"])
        self.assertTrue(any("camera.get after" in issue for issue in manifest["shots"][0]["integrityIssues"]))

    def test_metadata_cannot_override_capture_integrity(self) -> None:
        shot = Shot(
            path=Path("frame.png"),
            occluded=True,
            trustworthy=False,
            metadata={"occluded": False, "trustworthy": True, "camera": {"forged": True}},
        ).to_dict()
        self.assertTrue(shot["occluded"])
        self.assertFalse(shot["trustworthy"])
        self.assertEqual(shot["metadata"]["trustworthy"], True)
        self.assertNotIn("forged", shot["camera"])

    def test_foreground_change_during_grab_invalidates_the_shot(self) -> None:
        backend = FakeCaptureBackend()
        backend.foreground_sequence = [backend.windows[0], WindowIdentity(999, 303, "Another Game")]
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), backend=backend)
        self.assertFalse(manifest["trustworthy"])
        self.assertTrue(manifest["shots"][0]["occluded"])

    def test_wrong_window_pid_cannot_match_the_pinned_place(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), expected_pid=9999)
        self.assertFalse(manifest["trustworthy"])
        self.assertTrue(any(item["scope"] == "identity" for item in manifest["failures"]))

    def test_build_and_spec_hashes_must_match_the_exact_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), build_hash="e" * 64, place_hash="e" * 64, spec_hash="f" * 64)
        self.assertFalse(manifest["trustworthy"])
        errors = "\n".join(item["error"] for item in manifest["failures"])
        self.assertIn("placeHash differs", errors)
        self.assertIn("specHash differs", errors)

    def test_missing_required_viewpoint_blocks_capture_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), required_viewpoints=["world-overview", "shop"])
        self.assertFalse(manifest["trustworthy"])
        self.assertIn("shop", manifest["missingRequiredViewpoints"])
        self.assertLess(manifest["coverage"], 1)

    def test_camera_drift_invalidates_the_shot(self) -> None:
        bridge = FakeBridge()
        bridge.drift = True
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), bridge=bridge)
        self.assertFalse(manifest["trustworthy"])
        self.assertTrue(any("camera pose changed" in issue for issue in manifest["shots"][0]["integrityIssues"]))

    def test_manifest_records_identity_and_png_hash(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory))
            png = Path(directory) / manifest["shots"][0]["file"]
            self.assertTrue(png.exists())
        self.assertTrue(manifest["trustworthy"], manifest["failures"])
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["runId"], "run-capture")
        self.assertEqual(manifest["buildHash"], BUILD_HASH)
        self.assertEqual(manifest["placeHash"], BUILD_HASH)
        self.assertEqual(manifest["specHash"], SPEC_HASH)
        self.assertEqual(manifest["sessionId"], SESSION)
        self.assertEqual(len(manifest["shots"][0]["sha256"]), 64)
        self.assertGreater(manifest["shots"][0]["bytes"], 0)
        self.assertEqual(manifest["coverage"], 1.0)

    def test_camera_response_from_another_session_is_rejected(self) -> None:
        bridge = FakeBridge()
        bridge.camera_session = "sess_other"
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), bridge=bridge)
        self.assertFalse(manifest["trustworthy"])
        self.assertTrue(any("pinned session" in item["error"] for item in manifest["failures"]))

    def test_declarative_camera_applies_distance_height_fov_and_yaw_exactly(self) -> None:
        bridge = FakeBridge()
        configured = [{
            "name": "world-overview",
            "target": "game.Workspace.Map",
            "required": True,
            "settleSeconds": 0,
            "device": "desktop",
            "resolution": [1280, 720],
            "camera": {
                "mode": "look-at-landmark",
                "distance": 3,
                "height": 2,
                "fieldOfView": 70,
                "yawDegrees": 0,
            },
        }]
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), bridge=bridge, viewpoints=configured)
        self.assertTrue(manifest["trustworthy"], manifest["failures"])
        request = next(params for method, params in bridge.calls if method == "camera.set")
        self.assertEqual([1.0, 2.0, 3.0], request["position"])
        self.assertEqual([1, 0, 0], request["lookAt"])
        self.assertEqual(70.0, request["fieldOfView"])

    def test_mobile_capture_cannot_pass_without_device_emulator_identity(self) -> None:
        configured = [{
            "name": "mobile-store",
            "target": "game.Workspace.Store",
            "required": True,
            "settleSeconds": 0,
            "device": "phone",
            "resolution": [1280, 720],
        }]
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), viewpoints=configured)
        self.assertFalse(manifest["trustworthy"])
        self.assertTrue(any(
            "device-emulator identity" in issue
            for issue in manifest["shots"][0]["integrityIssues"]
        ))

    def test_requested_viewport_must_match_camera_viewport(self) -> None:
        configured = [{
            "name": "desktop-store",
            "target": "game.Workspace.Store",
            "required": True,
            "settleSeconds": 0,
            "device": "desktop",
            "resolution": [1920, 1080],
        }]
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.capture(Path(directory), viewpoints=configured)
        self.assertFalse(manifest["trustworthy"])
        self.assertTrue(any(
            "viewport does not match" in issue
            for issue in manifest["shots"][0]["integrityIssues"]
        ))


if __name__ == "__main__":
    unittest.main()
