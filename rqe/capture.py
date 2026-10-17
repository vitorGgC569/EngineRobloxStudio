"""Reproducible Studio screenshots with fail-closed provenance.

Desktop pixels are only visual evidence when the engine can prove which Studio
window, bridge session, build, camera pose and viewpoint produced them.  Every
integrity check in this module contributes to ``trustworthy``; callers cannot
set that flag through metadata.
"""

from __future__ import annotations

import base64
import ctypes
import io
import hashlib
import json
import math
import os
import re
import time
from ctypes import wintypes
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Protocol

from .hub.client import StudioBridge
from .hub.protocol import BridgeError, Response


CAPTURE_SCHEMA_VERSION = 1
_VIEWPOINT_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")


def _timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class WindowIdentity:
    hwnd: int
    pid: int
    title: str

    def to_dict(self) -> dict[str, Any]:
        return {"hwnd": self.hwnd, "pid": self.pid, "title": self.title}


class CaptureBackend(Protocol):
    """OS boundary, injected so integrity behavior is testable without Studio."""

    def studio_windows(self) -> list[WindowIdentity]: ...

    #: Studio notices that may be closed without a decision. Matched
    #: case-insensitively against the window title, in any UI language.
    #:
    #: An allowlist rather than "close whatever is modal". A dialog is where
    #: Studio asks a question, and an agent that dismisses every question will
    #: eventually discard somebody's work by answering one it never read. These

    def focus(self, window: WindowIdentity) -> None: ...

    def foreground(self) -> WindowIdentity | None: ...

    def grab(self, window: WindowIdentity, output: Path) -> tuple[int, int]: ...


class Win32CaptureBackend:
    """Capture exact Win32 HWNDs; never select a window by enumeration order."""

    def __init__(self) -> None:
        if os.name != "nt":
            raise RuntimeError("Studio window capture is implemented for Windows only")
        self.user32 = ctypes.windll.user32
        self.kernel32 = ctypes.windll.kernel32

    def _identity(self, hwnd: int) -> WindowIdentity:
        length = self.user32.GetWindowTextLengthW(hwnd)
        buffer = ctypes.create_unicode_buffer(length + 1)
        self.user32.GetWindowTextW(hwnd, buffer, length + 1)
        pid = wintypes.DWORD()
        self.user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        return WindowIdentity(int(hwnd), int(pid.value), buffer.value)

    def studio_windows(self) -> list[WindowIdentity]:
        found: list[WindowIdentity] = []
        callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

        @callback_type
        def callback(hwnd, _lparam):
            identity = self._identity(int(hwnd))
            if self.user32.IsWindowVisible(hwnd) and "roblox studio" in identity.title.lower():
                found.append(identity)
            return True

        self.user32.EnumWindows(callback, 0)
        return sorted(found, key=lambda item: (item.pid, item.hwnd))

    #: five are notices: they inform and their only action is acknowledgement.
    DISMISSABLE_TITLES = (
        "lighting technology migration", "tecnologia de migração de iluminação",
        "migração", "migration",
        "what's new", "novidades",
        "beta features", "recursos beta",
        "notification", "notificação",
        # Studio offers to restore an autosave after any hard exit, and an
        # agentic loop restarts Studio constantly -- so this is the dialog it
        # meets most. Declining it is safe: the place on disk is the one the
        # factory just built, and the recovery file is from the session that
        # was replaced.
        "auto-recovery", "recuperação automática", "recuperacao automatica",
        "recovery",
    )

    def modal_windows(self, owner: WindowIdentity) -> list[WindowIdentity]:
        """Visible owned popups sitting over a Studio window.

        These are what make a screenshot untrustworthy: the frame is of Studio,
        and a panel in the middle of it is not the game.
        """

        found: list[WindowIdentity] = []
        callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

        @callback_type
        def callback(hwnd, _lparam):
            handle = int(hwnd)
            if handle == owner.hwnd or not self.user32.IsWindowVisible(handle):
                return True
            identity = self._identity(handle)
            if owner.pid and identity.pid != owner.pid:
                return True
            # Owned windows and dialog-class windows only: the main window and
            # its docked panels are not popups.
            owner_hwnd = int(self.user32.GetWindow(handle, 4) or 0)  # GW_OWNER
            if owner_hwnd == 0:
                return True
            found.append(identity)
            return True

        self.user32.EnumWindows(callback, 0)
        return found

    def dismiss_notices(self, owner: WindowIdentity) -> dict[str, list[str]]:
        """Close known Studio notices so they stop occluding the viewport.

        Sent as WM_CLOSE rather than a click at coordinates. A click assumes a
        button is where it was last time and in the language it was last time,
        and when it is not, the click lands on the page behind it.

        Anything not on the allowlist is left alone and reported. A capture over
        an unknown dialog stays untrustworthy, which is the correct outcome: the
        alternative is an agent that clears its own obstacles by pressing
        buttons nobody read.
        """

        dismissed: list[str] = []
        left: list[str] = []
        for popup in self.modal_windows(owner):
            title = popup.title.strip()
            lowered = title.lower()
            if any(known in lowered for known in self.DISMISSABLE_TITLES):
                self.user32.PostMessageW(popup.hwnd, 0x0010, 0, 0)  # WM_CLOSE
                dismissed.append(title or f"<untitled {popup.hwnd}>")
            elif title:
                left.append(title)
        if dismissed:
            time.sleep(0.4)
        return {"dismissed": dismissed, "left": left}
    def focus(self, window: WindowIdentity) -> None:
        if not self.user32.IsWindow(window.hwnd):
            raise RuntimeError(f"Studio HWND {window.hwnd} no longer exists")
        self.user32.ShowWindow(window.hwnd, 9)  # SW_RESTORE
        foreground = self.user32.GetForegroundWindow()
        current_thread = self.kernel32.GetCurrentThreadId()
        foreground_thread = self.user32.GetWindowThreadProcessId(foreground, None) if foreground else 0
        attached = False
        if foreground_thread and foreground_thread != current_thread:
            attached = bool(self.user32.AttachThreadInput(foreground_thread, current_thread, True))
        try:
            # Windows grants foreground only to a process that received the last
            # input event, and an agent driving Studio in a loop never has. The
            # documented way through is to be the source of an input event
            # first: a press and release of a modifier that changes nothing.
            #
            # Without this the whole agentic path stops at "Windows refused the
            # focus change. Click the Studio window once" -- which is exactly
            # the manual step the loop exists to remove.
            KEYEVENTF_KEYUP = 0x0002
            VK_MENU = 0x12
            self.user32.keybd_event(VK_MENU, 0, 0, 0)
            self.user32.keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, 0)
            self.user32.BringWindowToTop(window.hwnd)
            self.user32.SetForegroundWindow(window.hwnd)
        finally:
            if attached:
                self.user32.AttachThreadInput(foreground_thread, current_thread, False)

        # Retried, because one refusal is not a verdict. Whether Windows grants
        # the change depends on what the desktop is doing at that instant, and
        # a Studio busy running a game is often slow to come forward.
        for _ in range(6):
            time.sleep(0.25)
            current = self.foreground()
            if current is not None and current.hwnd == window.hwnd:
                return
            self.user32.keybd_event(0x12, 0, 0, 0)
            self.user32.keybd_event(0x12, 0, 0x0002, 0)
            self.user32.AllowSetForegroundWindow(-1)   # ASFW_ANY
            self.user32.ShowWindow(window.hwnd, 9)     # SW_RESTORE
            self.user32.SetForegroundWindow(window.hwnd)
            self.user32.SwitchToThisWindow(window.hwnd, True)

        current = self.foreground()
        if current is None or current.hwnd != window.hwnd:
            raise RuntimeError("Windows refused to focus the selected Roblox Studio window")

    def foreground(self) -> WindowIdentity | None:
        hwnd = int(self.user32.GetForegroundWindow() or 0)
        return self._identity(hwnd) if hwnd else None

    def grab(self, window: WindowIdentity, output: Path) -> tuple[int, int]:
        try:
            from PIL import ImageGrab
        except ImportError as exc:  # pragma: no cover - environment dependency
            raise RuntimeError("Pillow is required for screenshots: pip install pillow") from exc
        if self.user32.IsIconic(window.hwnd):
            raise RuntimeError("the selected Studio window is minimized")
        rect = wintypes.RECT()
        if not self.user32.GetWindowRect(window.hwnd, ctypes.byref(rect)):
            raise RuntimeError("could not read the selected Studio window rectangle")
        if rect.right <= rect.left or rect.bottom <= rect.top:
            raise RuntimeError("the selected Studio window has an empty rectangle")
        image = ImageGrab.grab(
            bbox=(rect.left, rect.top, rect.right, rect.bottom),
            include_layered_windows=True,
        )
        output.parent.mkdir(parents=True, exist_ok=True)
        image.save(output, "PNG", optimize=True)
        return image.width, image.height


@dataclass
class Shot:
    """One frame plus the complete integrity trail needed to trust it."""

    path: Path
    width: int = 0
    height: int = 0
    occluded: bool = True
    foreground_window: str = ""
    camera: dict[str, Any] = field(default_factory=dict)
    metadata: dict[str, Any] = field(default_factory=dict)
    viewpoint: str = ""
    required: bool = True
    sha256: str | None = None
    bytes: int = 0
    trustworthy: bool = False
    integrity_issues: list[str] = field(default_factory=list)
    window: WindowIdentity | None = None
    foreground_before: WindowIdentity | None = None
    foreground_after: WindowIdentity | None = None
    camera_before: dict[str, Any] = field(default_factory=dict)
    camera_after: dict[str, Any] = field(default_factory=dict)
    framing: dict[str, Any] = field(default_factory=dict)
    session_id: str = ""
    context: str = "unknown"
    place: str = ""
    run_id: str = ""
    build_hash: str = ""
    place_hash: str = ""
    spec_hash: str = ""
    target: str | None = None
    expected_device: str | None = None
    expected_resolution: tuple[int, int] | None = None

    def to_dict(self) -> dict[str, Any]:
        # Metadata stays nested so it can never overwrite integrity fields.
        return {
            "id": self.viewpoint,
            "file": self.path.name,
            "path": self.path.name,
            "width": self.width,
            "height": self.height,
            "bytes": self.bytes,
            "sha256": self.sha256,
            "required": self.required,
            "occluded": self.occluded,
            "trustworthy": self.trustworthy,
            "integrityIssues": list(self.integrity_issues),
            "window": self.window.to_dict() if self.window else None,
            "foregroundBefore": self.foreground_before.to_dict() if self.foreground_before else None,
            "foregroundAfter": self.foreground_after.to_dict() if self.foreground_after else None,
            "foregroundWindow": self.foreground_window,
            "camera": {
                "before": self.camera_before,
                "after": self.camera_after,
                "framing": self.framing,
            },
            "sessionId": self.session_id,
            "context": self.context,
            "place": self.place,
            "runId": self.run_id,
            "buildHash": self.build_hash,
            "placeHash": self.place_hash,
            "specHash": self.spec_hash,
            "target": self.target,
            "device": {
                "requested": self.expected_device,
                # The bridge currently exposes viewport size, but not Studio's
                # device-emulator identity.  Never infer phone/tablet merely
                # from pixel dimensions.
                "verified": self.expected_device in (None, "desktop"),
            },
            "resolution": {
                "requested": list(self.expected_resolution) if self.expected_resolution else None,
                "measuredViewport": self.camera_before.get("viewportSize"),
            },
            "metadata": dict(self.metadata),
        }


def _select_window(
    backend: CaptureBackend,
    *,
    expected_place: str,
    expected_hwnd: int | None,
    expected_pid: int | None,
) -> WindowIdentity:
    candidates = backend.studio_windows()
    if expected_hwnd is not None:
        candidates = [item for item in candidates if item.hwnd == expected_hwnd]
    if expected_pid is not None:
        candidates = [item for item in candidates if item.pid == expected_pid]
    if expected_place:
        place_name = Path(expected_place).name.lower()
        candidates = [item for item in candidates if place_name in item.title.lower()]
    if not candidates:
        raise RuntimeError("no Roblox Studio window matches the pinned session/place/PID/HWND")
    if len(candidates) != 1:
        identities = [item.to_dict() for item in candidates]
        raise RuntimeError(f"Studio window identity is ambiguous: {identities}")
    return candidates[0]


def _camera_response(bridge: StudioBridge, method: str, params: dict[str, Any], timeout: float = 15) -> tuple[dict[str, Any], Response]:
    response = bridge.call_response(method, params, timeout=timeout)
    result = response.unwrap()
    if not isinstance(result, dict):
        raise RuntimeError(f"{method} returned no structured camera state")

    # The entire pose must come from the rendered client. Replacing only a
    # server camera's 1x1 viewport made unrelated server coordinates look valid.
    if response.context in {"run", "server"} and method.startswith("camera."):
        client_params = {"player": params["player"]} if params.get("player") else {}
        if method == "camera.get":
            client_method = "client.camera_get"
        else:
            pose = result.get("camera", result)
            position, look = pose.get("position"), pose.get("lookVector")
            if not isinstance(position, list) or not isinstance(look, list) or len(position) != 3 or len(look) != 3:
                raise RuntimeError(f"{method} returned no usable requested framing")
            client_method = "client.camera_set"
            client_params.update({"position": position,
                                  "lookAt": [p + v for p, v in zip(position, look)],
                                  "fieldOfView": pose["fieldOfView"]})
        client_response = bridge.call_response(client_method, client_params, timeout=timeout)
        client_pose = client_response.unwrap()
        if client_response.session != response.session:
            raise RuntimeError("camera relay changed the pinned Studio session")
        if not isinstance(client_pose, dict) or client_pose.get("cameraSource") != "client":
            raise RuntimeError("rendered client camera could not be measured")
        if method == "camera.get":
            result = client_pose
        else:
            result["camera"] = client_pose
        response = client_response
    return result, response


def _same_pose(before: dict[str, Any], after: dict[str, Any]) -> bool:
    def close_sequence(left: Any, right: Any, tolerance: float) -> bool:
        if not isinstance(left, list) or not isinstance(right, list) or len(left) != len(right):
            return False
        return all(
            isinstance(a, (int, float)) and isinstance(b, (int, float)) and math.isclose(float(a), float(b), abs_tol=tolerance)
            for a, b in zip(left, right)
        )

    return (
        close_sequence(before.get("position"), after.get("position"), 0.01)
        and close_sequence(before.get("lookVector"), after.get("lookVector"), 0.001)
        and math.isclose(float(before.get("fieldOfView", -1)), float(after.get("fieldOfView", -2)), abs_tol=0.01)
        and before.get("viewportSize") == after.get("viewportSize")
        and before.get("cameraType") == after.get("cameraType")
        and before.get("cameraSource") == after.get("cameraSource")
        and before.get("player") == after.get("player")
    )


def _validate_png(path: Path, expected_width: int, expected_height: int) -> tuple[int, str]:
    try:
        from PIL import Image, UnidentifiedImageError
    except ImportError as exc:  # pragma: no cover - environment dependency
        raise RuntimeError("Pillow is required to validate captured PNG files") from exc
    try:
        with Image.open(path) as image:
            image.verify()
        with Image.open(path) as image:
            if image.format != "PNG":
                raise RuntimeError("capture backend did not produce a PNG")
            if image.width <= 0 or image.height <= 0:
                raise RuntimeError("captured PNG has empty dimensions")
            if image.width != expected_width or image.height != expected_height:
                raise RuntimeError("captured PNG dimensions differ from the backend result")
    except (OSError, UnidentifiedImageError) as exc:
        raise RuntimeError(f"captured PNG could not be decoded: {exc}") from exc
    size = path.stat().st_size
    if size <= 0:
        raise RuntimeError("captured PNG is empty")
    return size, _sha256_file(path)


def capture(
    output: Path,
    bridge: StudioBridge | None = None,
    metadata: dict[str, Any] | None = None,
    focus: bool = True,
    *,
    backend: CaptureBackend | None = None,
    window: WindowIdentity | None = None,
    expected_place: str = "",
    expected_hwnd: int | None = None,
    expected_pid: int | None = None,
    expected_session: str = "",
    run_id: str = "",
    build_hash: str = "",
    place_hash: str = "",
    spec_hash: str = "",
    viewpoint: str = "adhoc",
    required: bool = True,
    target: str | None = None,
    framing: dict[str, Any] | None = None,
    expected_device: str | None = None,
    expected_resolution: tuple[int, int] | None = None,
) -> Shot:
    """Capture one exact Studio window and verify its identity before/after."""

    capture_backend = backend or Win32CaptureBackend()
    selected = window or _select_window(
        capture_backend,
        expected_place=expected_place,
        expected_hwnd=expected_hwnd,
        expected_pid=expected_pid,
    )
    issues: list[str] = []
    dismissed_notices: list[str] = []
    shot = Shot(
        path=output,
        viewpoint=viewpoint,
        required=required,
        window=selected,
        run_id=run_id,
        build_hash=build_hash,
        place_hash=place_hash,
        spec_hash=spec_hash,
        target=target,
        framing=framing or {},
        expected_device=expected_device,
        expected_resolution=expected_resolution,
        # Caller metadata is informational and nested in the manifest; the
        # engine-owned timestamp is written last so it cannot be forged.
        metadata={**(metadata or {}), "capturedAt": _timestamp()},
    )

    if focus:
        # Notices first. A modal panel over the viewport makes every later check
        # meaningless: the frame is of Studio and the middle of it is a dialog.
        # Only known notices are closed, and anything else is reported so the
        # frame stays untrustworthy rather than being cleared by an agent
        # pressing buttons nobody read.
        dismiss = getattr(capture_backend, "dismiss_notices", None)
        if dismiss is not None:
            try:
                outcome = dismiss(selected)
                if outcome["dismissed"]:
                    dismissed_notices.extend(outcome["dismissed"])
                for title in outcome["left"]:
                    issues.append(
                        f"a dialog is open over the viewport and was not dismissed: {title!r}"
                    )
            except Exception as exc:  # noqa: BLE001 - never fail the capture on cleanup
                issues.append(f"could not check for open dialogs: {exc}")

        try:
            capture_backend.focus(selected)
        except RuntimeError as exc:
            issues.append(f"focus: {exc}")

    before_response: Response | None = None
    after_response: Response | None = None
    if bridge is None:
        issues.append("camera.get unavailable: no Studio bridge supplied")
    else:
        try:
            shot.camera_before, before_response = _camera_response(bridge, "camera.get", {})
        except (BridgeError, RuntimeError, ValueError) as exc:
            issues.append(f"camera.get before capture failed: {exc}")

    # Re-assert the focus immediately before the picture.
    #
    # `focus` ran several bridge round trips ago — reading the camera, and
    # asking the client for its viewport — and seconds are long enough for
    # something else to come forward. The assertion below is what guarantees
    # the photograph is of Studio rather than of whatever replaced it, so the
    # window is brought back right next to it rather than hopefully earlier.
    try:
        capture_backend.focus(selected)
    except RuntimeError as exc:
        issues.append(f"focus before capture: {exc}")

    shot.foreground_before = capture_backend.foreground()
    if shot.foreground_before is None or shot.foreground_before.hwnd != selected.hwnd:
        issues.append("selected Studio window was not foreground before capture")

    try:
        shot.width, shot.height = capture_backend.grab(selected, output)
    except (OSError, RuntimeError, ValueError) as exc:
        issues.append(f"PNG capture failed: {exc}")

    shot.foreground_after = capture_backend.foreground()
    if shot.foreground_after is None or shot.foreground_after.hwnd != selected.hwnd:
        issues.append("selected Studio window was not foreground after capture")

    if bridge is not None:
        try:
            shot.camera_after, after_response = _camera_response(bridge, "camera.get", {})
        except (BridgeError, RuntimeError, ValueError) as exc:
            issues.append(f"camera.get after capture failed: {exc}")

    responses = [item for item in (before_response, after_response) if item is not None]
    if responses:
        shot.session_id = responses[0].session
        shot.context = responses[0].context
        shot.place = responses[0].place
    if len(responses) != 2:
        issues.append("camera provenance is incomplete")
    else:
        if any(item.session != expected_session for item in responses) or not expected_session:
            issues.append("camera response did not come from the pinned session")
        if len({item.session for item in responses}) != 1:
            issues.append("camera responses came from different sessions")
        if len({item.context for item in responses}) != 1:
            issues.append("Studio context changed during capture")
        if any(item.context not in {"run", "server", "client"} for item in responses):
            issues.append("camera capture did not run in a live game context")
        if len({item.place for item in responses}) != 1:
            issues.append("Studio place changed during capture")
        if expected_place and any(Path(item.place).name.lower() != Path(expected_place).name.lower() for item in responses):
            issues.append("camera response place differs from the selected Studio window")
        requested_pose = shot.framing.get("camera") if isinstance(shot.framing, dict) else None
        if isinstance(requested_pose, dict) and not _same_pose(requested_pose, shot.camera_before):
            issues.append("camera pose differs from the requested viewpoint framing")
        if not _same_pose(shot.camera_before, shot.camera_after):
            issues.append("camera pose changed during capture")

    if expected_device not in (None, "desktop"):
        issues.append(
            f"Studio device-emulator identity is unavailable for requested device {expected_device!r}"
        )
    if expected_resolution is not None:
        measured_viewport = shot.camera_before.get("viewportSize")
        if measured_viewport != list(expected_resolution):
            issues.append(
                "camera viewport does not match requested resolution "
                f"{list(expected_resolution)} (measured {measured_viewport!r})"
            )

    if output.exists() and shot.width > 0 and shot.height > 0:
        try:
            shot.bytes, shot.sha256 = _validate_png(output, shot.width, shot.height)
        except RuntimeError as exc:
            issues.append(str(exc))
        # The pixels, last, because everything above can pass on a frame of
        # nothing. A blank capture that reports itself trustworthy is worse than
        # a failed capture: it becomes evidence.
        drawn, why = _frame_has_content(output)
        if not drawn:
            issues.append(why)
        elif why:
            shot.notes = getattr(shot, "notes", "") or why
    else:
        issues.append("captured PNG is missing")

    shot.foreground_window = shot.foreground_after.title if shot.foreground_after else ""
    shot.occluded = any("foreground" in issue for issue in issues)
    shot.integrity_issues = issues
    shot.trustworthy = not issues
    # Compatibility field: it is derived from the verified pre-capture pose.
    shot.camera = dict(shot.camera_before)
    return shot


def _allowed_contexts(world_only: bool) -> set[str]:
    """Which Studio contexts a frame may come from.

    A play session for gameplay evidence; the editor as well when the question
    is only about the built world. Conflating them blocked every iteration on
    world composition behind a play session -- which needs a foreground grab
    Windows refuses to a background process.
    """

    live = {"run", "server", "client"}
    return live | {"edit"} if world_only else live


def _frame_has_content(path: Path) -> tuple[bool, str]:
    """Does this image contain a picture, or a rectangle of nothing?

    A window that is minimised, occluded, or still compositing photographs as a
    flat fill. Every other integrity check passes on such a frame: the session
    is right, the place is right, the pose did not move, the PNG is the declared
    size. Only the pixels know.

    Two signals, both cheap: how much of the frame sits at one extreme, and how
    many distinct tones exist at all. A real Studio frame has hundreds; the
    blank ones measured here had **two**.
    """

    try:
        from PIL import Image
    except Exception:  # noqa: BLE001
        # Without Pillow this check cannot run, and saying so is better than
        # silently returning "fine" -- which is the failure being fixed.
        return True, "pixel content unchecked: Pillow is unavailable"

    try:
        with Image.open(path) as image:
            grey = image.convert("L")
            counts = grey.histogram()
    except Exception as error:  # noqa: BLE001
        return False, f"the captured image could not be read: {error}"

    total = sum(counts)
    if total == 0:
        return False, "the captured image has no pixels"

    distinct = sum(1 for count in counts if count > 0)
    darkest = sum(counts[:5]) / total
    brightest = sum(counts[250:]) / total

    if distinct <= 8:
        return False, (
            f"the capture has only {distinct} distinct tones in the whole frame; "
            "this is a picture of a minimised or uncomposited window, not of the game"
        )
    if darkest > 0.97:
        return False, (
            f"{darkest:.0%} of the capture is pure black -- the window was not "
            "drawn when the shutter fired"
        )
    if brightest > 0.97:
        return False, (
            f"{brightest:.0%} of the capture is pure white -- the window was not "
            "drawn when the shutter fired"
        )
    return True, ""



def capture_native_viewpoint(
    bridge: StudioBridge,
    target: str,
    output: Path,
    pitch_degrees: float = 35.0,
    yaw_degrees: float = 45.0,
    margin: float = 1.35,
    metadata: dict[str, Any] | None = None,
    settle_seconds: float = 0.8,
    *,
    expected_place: str = "",
    expected_session: str = "",
    run_id: str = "",
    build_hash: str = "",
    place_hash: str = "",
    spec_hash: str = "",
    viewpoint: str = "adhoc",
    required: bool = True,
    expected_device: str | None = None,
    expected_resolution: tuple[int, int] | None = None,
    world_only: bool = False,
    include_ui: bool = True,
) -> Shot:
    """Capture Studio's rendered viewport through StudioCaptureService.

    This backend never focuses, restores, raises, or screenshots a desktop
    window. The bytes originate inside Studio and are normalised to PNG before
    entering the same Shot integrity model used by the legacy window backend.
    """

    issues: list[str] = []

    if not target:
        framing, framing_response = _camera_response(bridge, "camera.get", {})
    else:
        framing, framing_response = _camera_response(
            bridge,
            "camera.focus",
            {
                "path": target,
                "pitchDegrees": pitch_degrees,
                "yawDegrees": yaw_degrees,
                "margin": margin,
            },
        )

    if framing_response.session != expected_session or not expected_session:
        raise RuntimeError("camera framing did not run on the pinned session")
    if framing_response.context not in _allowed_contexts(world_only):
        raise RuntimeError(
            "camera framing did not run in an allowed Studio context for this capture"
        )
    if (
        expected_place
        and Path(framing_response.place).name.lower()
        != Path(expected_place).name.lower()
    ):
        raise RuntimeError("camera framing ran against a different place")

    time.sleep(max(0.0, settle_seconds))

    before_response: Response | None = None
    after_response: Response | None = None
    camera_before: dict[str, Any] = {}
    camera_after: dict[str, Any] = {}

    try:
        camera_before, before_response = _camera_response(bridge, "camera.get", {})
    except (BridgeError, RuntimeError, ValueError) as exc:
        issues.append(f"camera.get before native capture failed: {exc}")

    native_response: Response | None = None
    native_result: dict[str, Any] = {}
    try:
        native_response = bridge.call_response(
            "studio.capture_background",
            {"includeUi": bool(include_ui)},
            timeout=30,
        )
        result = native_response.unwrap()
        if not isinstance(result, dict):
            raise RuntimeError("studio.capture_background returned no structured result")
        native_result = result
    except (BridgeError, RuntimeError, ValueError) as exc:
        issues.append(f"StudioCaptureService capture failed: {exc}")

    output.parent.mkdir(parents=True, exist_ok=True)
    width = 0
    height = 0

    if native_result:
        if native_result.get("supported") is not True:
            issues.append("StudioCaptureService backend is not supported")
        if native_result.get("canCapture") is not True:
            issues.append(
                str(
                    native_result.get("message")
                    or "StudioCaptureService cannot capture in this context"
                )
            )

        native_errors = native_result.get("errors") or []
        if native_errors:
            issues.extend(
                f"StudioCaptureService: {item}" for item in native_errors
            )

        encoded = native_result.get("dataBase64")
        if native_result.get("canCapture") is True and not isinstance(encoded, str):
            issues.append("StudioCaptureService returned no base64 image buffer")
        elif isinstance(encoded, str):
            try:
                raw = base64.b64decode(encoded, validate=True)
                from PIL import Image

                with Image.open(io.BytesIO(raw)) as image:
                    width, height = image.size
                    image.convert("RGB").save(output, "PNG", optimize=True)
            except Exception as exc:  # noqa: BLE001
                issues.append(f"native screenshot buffer could not be decoded: {exc}")

    try:
        camera_after, after_response = _camera_response(bridge, "camera.get", {})
    except (BridgeError, RuntimeError, ValueError) as exc:
        issues.append(f"camera.get after native capture failed: {exc}")

    shot = Shot(
        path=output,
        width=width,
        height=height,
        occluded=False,
        foreground_window="",
        camera=dict(camera_before),
        metadata={
            **(metadata or {}),
            "capturedAt": _timestamp(),
            "captureBackend": "StudioCaptureService",
            "nativeCapture": {
                key: value
                for key, value in native_result.items()
                if key != "dataBase64"
            },
        },
        viewpoint=viewpoint,
        required=required,
        camera_before=dict(camera_before),
        camera_after=dict(camera_after),
        framing=framing,
        run_id=run_id,
        build_hash=build_hash,
        place_hash=place_hash,
        spec_hash=spec_hash,
        target=target,
        expected_device=expected_device,
        expected_resolution=expected_resolution,
    )

    responses = [
        item
        for item in (before_response, native_response, after_response)
        if item is not None
    ]
    if responses:
        shot.session_id = responses[0].session
        shot.context = responses[0].context
        shot.place = responses[0].place

    if len(responses) != 3:
        issues.append("native capture provenance is incomplete")
    else:
        if any(item.session != expected_session for item in responses):
            issues.append("native capture responses did not come from the pinned session")
        if len({item.session for item in responses}) != 1:
            issues.append("native capture responses came from different sessions")
        if len({item.context for item in responses}) != 1:
            issues.append("Studio context changed during native capture")
        if any(item.context not in _allowed_contexts(world_only) for item in responses):
            issues.append("native capture ran in a disallowed Studio context")
        if len({item.place for item in responses}) != 1:
            issues.append("Studio place changed during native capture")
        if (
            expected_place
            and any(
                Path(item.place).name.lower() != Path(expected_place).name.lower()
                for item in responses
            )
        ):
            issues.append("native capture place differs from expected place")

    requested_pose = framing.get("camera") if isinstance(framing, dict) else None
    if isinstance(requested_pose, dict) and camera_before:
        if not _same_pose(requested_pose, camera_before):
            issues.append("camera pose differs from requested native capture framing")
    if camera_before and camera_after and not _same_pose(camera_before, camera_after):
        issues.append("camera pose changed during native capture")

    if expected_resolution is not None:
        measured = [width, height]
        if measured != list(expected_resolution):
            issues.append(
                "native capture resolution does not match requested resolution "
                f"{list(expected_resolution)} (measured {measured})"
            )

    if output.exists() and width > 0 and height > 0:
        try:
            shot.bytes, shot.sha256 = _validate_png(output, width, height)
        except RuntimeError as exc:
            issues.append(str(exc))
        drawn, why = _frame_has_content(output)
        if not drawn:
            issues.append(why)
    else:
        issues.append("native captured PNG is missing")

    shot.integrity_issues = issues
    shot.trustworthy = not issues
    return shot


def capture_viewpoint(
    bridge: StudioBridge,
    target: str,
    output: Path,
    pitch_degrees: float = 35.0,
    yaw_degrees: float = 45.0,
    margin: float = 1.35,
    metadata: dict[str, Any] | None = None,
    settle_seconds: float = 0.8,
    *,
    backend: CaptureBackend | None = None,
    window: WindowIdentity | None = None,
    expected_place: str = "",
    expected_session: str = "",
    run_id: str = "",
    build_hash: str = "",
    place_hash: str = "",
    spec_hash: str = "",
    viewpoint: str = "adhoc",
    required: bool = True,
    expected_device: str | None = None,
    expected_resolution: tuple[int, int] | None = None,
    world_only: bool = False,
) -> Shot:
    """Frame a target, wait for rendering, then capture with pose continuity.

    `world_only` photographs the built place from the editor. The geometry and
    the lighting are the ones the place ships, so it is real evidence about the
    world -- and none at all about gameplay, which is why it is a named argument
    rather than a fallback.
    """

    # An empty target means "photograph where the camera already is". Framing a
    # target is how a viewpoint stays comparable between runs, but it also
    # overrides any pose a caller set deliberately -- which made every attempt
    # to photograph the world from a player's eye come back as the same aerial
    # shot of the whole map.
    if not target:
        framing, framing_response = _camera_response(bridge, "camera.get", {})
    else:
        framing, framing_response = _camera_response(bridge, "camera.focus", {
            "path": target,
            "pitchDegrees": pitch_degrees,
            "yawDegrees": yaw_degrees,
            "margin": margin,
        })
    if framing_response.session != expected_session or not expected_session:
        raise RuntimeError("camera.focus did not run on the pinned session")
    if framing_response.context not in _allowed_contexts(world_only):
        raise RuntimeError(
            "camera.focus ran in the editor, and this capture was asked for as "
            "gameplay evidence. Start the game, or ask for a world-only frame."
            if not world_only else
            "camera.focus did not run in any recognised Studio context"
        )
    if expected_place and Path(framing_response.place).name.lower() != Path(expected_place).name.lower():
        raise RuntimeError("camera.focus ran against a different place")
    time.sleep(max(0.0, settle_seconds))
    return capture(
        output,
        bridge=bridge,
        metadata={
            "pitchDegrees": pitch_degrees,
            "yawDegrees": yaw_degrees,
            "margin": margin,
            "settleSeconds": settle_seconds,
            **(metadata or {}),
        },
        backend=backend,
        window=window,
        expected_place=expected_place,
        expected_session=expected_session,
        run_id=run_id,
        build_hash=build_hash,
        place_hash=place_hash,
        spec_hash=spec_hash,
        viewpoint=viewpoint,
        required=required,
        target=target,
        framing=framing,
        expected_device=expected_device,
        expected_resolution=expected_resolution,
    )


def capture_configured_viewpoint(
    bridge: StudioBridge,
    target: str,
    output: Path,
    camera_spec: dict[str, Any],
    *,
    metadata: dict[str, Any] | None = None,
    settle_seconds: float = 0.8,
    backend: CaptureBackend | None = None,
    window: WindowIdentity | None = None,
    expected_place: str = "",
    expected_session: str = "",
    run_id: str = "",
    build_hash: str = "",
    place_hash: str = "",
    spec_hash: str = "",
    viewpoint: str = "adhoc",
    required: bool = True,
    expected_device: str | None = None,
    expected_resolution: tuple[int, int] | None = None,
    native: bool = False,
) -> Shot:
    """Apply the exact declarative look-at camera rather than approximating it.

    ``camera.focus`` derives distance from a bounding sphere.  A visual spec,
    however, declares distance, height and field of view explicitly.  Treating
    the two as equivalent makes a deterministic-looking receipt for the wrong
    frame.  Player-follow needs a separate player/device camera provider and is
    therefore rejected until that identity can be measured.
    """

    if camera_spec.get("mode") != "look-at-landmark":
        raise RuntimeError(
            f"camera mode {camera_spec.get('mode')!r} is not executable by the deterministic landmark provider"
        )
    try:
        distance = float(camera_spec["distance"])
        height = float(camera_spec["height"])
        field_of_view = float(camera_spec["fieldOfView"])
        yaw_degrees = float(camera_spec.get("yawDegrees", 0))
    except (KeyError, TypeError, ValueError) as exc:
        raise RuntimeError(f"invalid declarative camera: {exc}") from exc
    if distance <= 0 or height < 0 or not 1 <= field_of_view <= 120:
        raise RuntimeError("declarative camera distance/height/fieldOfView are outside executable bounds")

    bounds, bounds_response = _camera_response(
        bridge, "world.bounds", {"path": target}, timeout=20
    )
    if bounds_response.session != expected_session or not expected_session:
        raise RuntimeError("world.bounds did not run on the pinned session")
    if bounds_response.context not in {"run", "server", "client"}:
        raise RuntimeError("world.bounds did not run in a live game context")
    center = bounds.get("center")
    if (
        not isinstance(center, list)
        or len(center) != 3
        or any(isinstance(item, bool) or not isinstance(item, (int, float)) for item in center)
    ):
        raise RuntimeError("world.bounds returned no numeric landmark centre")

    yaw = math.radians(yaw_degrees)
    position = [
        float(center[0]) + math.sin(yaw) * distance,
        float(center[1]) + height,
        float(center[2]) + math.cos(yaw) * distance,
    ]
    applied, set_response = _camera_response(
        bridge,
        "camera.set",
        {"position": position, "lookAt": center, "fieldOfView": field_of_view},
        timeout=20,
    )
    if set_response.session != expected_session:
        raise RuntimeError("camera.set did not run on the pinned session")
    if set_response.context not in {"run", "server", "client"}:
        raise RuntimeError("camera.set did not run in a live game context")
    if expected_place and Path(set_response.place).name.lower() != Path(expected_place).name.lower():
        raise RuntimeError("camera.set ran against a different place")
    applied_camera = applied.get("camera")
    if applied.get("applied") is not True or not isinstance(applied_camera, dict):
        raise RuntimeError("camera.set did not return the applied camera pose")

    time.sleep(max(0.0, settle_seconds))
    if native:
        measured_camera, measured_response = _camera_response(bridge, "camera.get", {})
        if measured_response.session != expected_session:
            raise RuntimeError("camera.get after configured framing did not run on the pinned session")
        if measured_response.context not in {"run", "server", "client"}:
            raise RuntimeError("camera.get after configured framing did not run in a live game context")
        if expected_place and Path(measured_response.place).name.lower() != Path(expected_place).name.lower():
            raise RuntimeError("configured camera verification ran against a different place")
        if not _same_pose(applied_camera, measured_camera):
            raise RuntimeError("configured camera pose was not preserved before native capture")
        shot = capture_native_viewpoint(
            bridge,
            "",
            output,
            metadata={
                "settleSeconds": settle_seconds,
                "configuredCamera": dict(camera_spec),
                **(metadata or {}),
            },
            settle_seconds=0,
            expected_place=expected_place,
            expected_session=expected_session,
            run_id=run_id,
            build_hash=build_hash,
            place_hash=place_hash,
            spec_hash=spec_hash,
            viewpoint=viewpoint,
            required=required,
            expected_device=expected_device,
            expected_resolution=expected_resolution,
        )
        shot.target = target
        shot.framing = {
            "camera": applied_camera,
            "request": dict(camera_spec),
            "landmarkBounds": bounds,
        }
        return shot
    return capture(
        output,
        bridge=bridge,
        metadata={"settleSeconds": settle_seconds, **(metadata or {})},
        backend=backend,
        window=window,
        expected_place=expected_place,
        expected_session=expected_session,
        run_id=run_id,
        build_hash=build_hash,
        place_hash=place_hash,
        spec_hash=spec_hash,
        viewpoint=viewpoint,
        required=required,
        target=target,
        framing={
            "camera": applied_camera,
            "request": dict(camera_spec),
            "landmarkBounds": bounds,
        },
        expected_device=expected_device,
        expected_resolution=expected_resolution,
    )


def capture_set(
    bridge: StudioBridge,
    viewpoints: list[dict[str, Any]],
    directory: Path,
    run_id: str,
    *,
    build_hash: str = "",
    place_hash: str = "",
    spec_hash: str = "",
    build_path: Path | None = None,
    spec_path: Path | None = None,
    required_viewpoints: list[str] | None = None,
    expected_place: str | None = None,
    expected_session: str | None = None,
    expected_hwnd: int | None = None,
    expected_pid: int | None = None,
    backend: CaptureBackend | None = None,
) -> dict[str, Any]:
    """Capture a required named set and persist a versioned integrity manifest."""

    directory.mkdir(parents=True, exist_ok=True)
    failures: list[dict[str, Any]] = []
    shots: list[dict[str, Any]] = []
    names: list[str] = []

    if not run_id:
        failures.append({"scope": "manifest", "error": "runId is required"})
    if not _SHA256.fullmatch(build_hash):
        failures.append({"scope": "manifest", "error": "buildHash must be a lowercase SHA-256"})
    if not _SHA256.fullmatch(place_hash):
        failures.append({"scope": "manifest", "error": "placeHash must be a lowercase SHA-256"})
    if build_path is None or not build_path.is_file():
        failures.append({"scope": "manifest", "error": "buildPath must identify the exact captured build"})
    elif _sha256_file(build_path) != place_hash:
        failures.append({"scope": "manifest", "error": "placeHash differs from buildPath"})
    if not _SHA256.fullmatch(spec_hash):
        failures.append({"scope": "manifest", "error": "specHash must be a lowercase SHA-256"})
    if spec_path is None or not spec_path.is_file():
        failures.append({"scope": "manifest", "error": "specPath must identify the exact visual spec"})
    elif _sha256_file(spec_path) != spec_hash:
        failures.append({"scope": "manifest", "error": "specHash differs from specPath"})
    if not viewpoints:
        failures.append({"scope": "coverage", "error": "at least one viewpoint is required"})

    for index, viewpoint in enumerate(viewpoints, start=1):
        name = str(viewpoint.get("name") or "")
        if not _VIEWPOINT_NAME.fullmatch(name):
            failures.append({"scope": "viewpoint", "step": index, "error": f"invalid viewpoint name: {name!r}"})
            continue
        if name in names:
            failures.append({"scope": "viewpoint", "step": index, "error": f"duplicate viewpoint name: {name}"})
            continue
        names.append(name)

    required = list(required_viewpoints) if required_viewpoints is not None else [
        str(item.get("name")) for item in viewpoints if item.get("required", True)
    ]
    if not required:
        failures.append({"scope": "coverage", "error": "at least one required viewpoint is needed"})
    missing_definitions = sorted(set(required) - set(names))
    if missing_definitions:
        failures.append({"scope": "coverage", "error": f"required viewpoints are undefined: {missing_definitions}"})

    pinned_session = ""
    place = expected_place or (build_path.name if build_path is not None else "")
    selected: WindowIdentity | None = None
    capture_backend = backend
    use_native_capture = backend is None
    try:
        pinned_session = bridge.pinned_session or bridge.pin_to_running(timeout=30)
        if expected_session is not None and pinned_session != expected_session:
            raise RuntimeError(
                f"capture pinned session {pinned_session!r} differs from expected session {expected_session!r}"
            )
        info_response = bridge.call_response("studio.info", {}, timeout=15)
        info = info_response.unwrap()
        if info_response.session != pinned_session:
            raise RuntimeError("studio.info did not answer from the pinned session")
        if info_response.context not in {"run", "server", "client"}:
            raise RuntimeError("pinned Studio session is not running the game")
        if not isinstance(info, dict):
            raise RuntimeError("studio.info returned no structured place identity")
        live_place = str(info.get("placeName") or info_response.place or "")
        if info_response.place and Path(info_response.place).name.lower() != Path(live_place).name.lower():
            raise RuntimeError("studio.info result and response envelope identify different places")
        if place and Path(place).name.lower() != Path(live_place).name.lower():
            raise RuntimeError(f"requested place {place!r} differs from pinned place {live_place!r}")
        place = live_place
        if not use_native_capture:
            capture_backend = capture_backend or Win32CaptureBackend()
            selected = _select_window(
                capture_backend,
                expected_place=place,
                expected_hwnd=expected_hwnd,
                expected_pid=expected_pid,
            )
    except (BridgeError, OSError, RuntimeError, ValueError) as exc:
        failures.append({"scope": "identity", "error": str(exc)})

    if not failures and (use_native_capture or (selected is not None and capture_backend is not None)):
        valid_names = set(names)
        for index, viewpoint in enumerate(viewpoints, start=1):
            name = str(viewpoint.get("name") or "")
            if name not in valid_names:
                continue
            target = viewpoint.get("target")
            if not isinstance(target, str) or not target:
                failures.append({"viewpoint": name, "error": "a deterministic target is required"})
                continue
            output = directory / f"{index:02d}-{name}.png"
            try:
                common = {
                    "metadata": {"step": index},
                    "settle_seconds": float(viewpoint.get("settleSeconds", 0.8)),
                    "expected_place": place,
                    "expected_session": pinned_session,
                    "run_id": run_id,
                    "build_hash": build_hash,
                    "place_hash": place_hash,
                    "spec_hash": spec_hash,
                    "viewpoint": name,
                    "required": name in required,
                    "expected_device": (
                        str(viewpoint.get("device"))
                        if viewpoint.get("device") is not None
                        else None
                    ),
                    "expected_resolution": (
                        (int(viewpoint["resolution"][0]), int(viewpoint["resolution"][1]))
                        if isinstance(viewpoint.get("resolution"), list)
                        and len(viewpoint["resolution"]) == 2
                        else None
                    ),
                }
                camera_spec = viewpoint.get("camera")
                legacy_window = {"backend": capture_backend, "window": selected} if not use_native_capture else {}
                if isinstance(camera_spec, dict):
                    shot = capture_configured_viewpoint(
                        bridge,
                        target,
                        output,
                        camera_spec,
                        native=use_native_capture,
                        **legacy_window,
                        **common,
                    )
                elif use_native_capture:
                    shot = capture_native_viewpoint(
                        bridge,
                        target,
                        output,
                        float(viewpoint.get("pitchDegrees", 35)),
                        float(viewpoint.get("yawDegrees", 45)),
                        float(viewpoint.get("margin", 1.35)),
                        **common,
                    )
                else:
                    shot = capture_viewpoint(
                        bridge,
                        target,
                        output,
                        float(viewpoint.get("pitchDegrees", 35)),
                        float(viewpoint.get("yawDegrees", 45)),
                        float(viewpoint.get("margin", 1.35)),
                        **legacy_window,
                        **common,
                    )
                shots.append(shot.to_dict())
                if not shot.trustworthy:
                    failures.append({"viewpoint": name, "error": "capture integrity failed", "issues": shot.integrity_issues})
            except (BridgeError, OSError, RuntimeError, TypeError, ValueError) as exc:
                failures.append({"viewpoint": name, "error": str(exc)})

    captured_required = sorted({str(item.get("id")) for item in shots if item.get("required") and item.get("trustworthy")})
    required_unique = sorted(set(required))
    missing_required = sorted(set(required_unique) - set(captured_required))
    coverage = len(captured_required) / len(required_unique) if required_unique else 0.0
    occluded = [item for item in shots if item.get("occluded")]
    manifest = {
        "schemaVersion": CAPTURE_SCHEMA_VERSION,
        "runId": run_id,
        "buildHash": build_hash,
        "placeHash": place_hash,
        "specHash": spec_hash,
        "buildFile": build_path.name if build_path is not None else None,
        "specFile": spec_path.name if spec_path is not None else None,
        "sessionId": pinned_session,
        "place": place,
        "capturedAt": _timestamp(),
        "captureType": "studio-native" if use_native_capture else "studio-window",
        "window": selected.to_dict() if selected else None,
        "requiredViewpoints": required_unique,
        "capturedRequiredViewpoints": captured_required,
        "missingRequiredViewpoints": missing_required,
        "coverage": round(coverage, 6),
        "shots": shots,
        "failures": failures,
        "occludedShots": len(occluded),
        "trustworthy": bool(shots) and coverage == 1.0 and not failures and not occluded and all(item.get("trustworthy") is True for item in shots),
    }
    _atomic_json(directory / "manifest.json", manifest)
    return manifest
