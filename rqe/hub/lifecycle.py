"""Managed Roblox Studio lifecycle.

Restarting Studio is a routine step for this platform -- installing a plugin,
resetting a place contaminated by a previous run -- and it has to be
deterministic. Two things break that:

* a stale ``.lock`` beside the place after an unclean exit;
* the **auto-recovery dialog**, which Studio raises modally on the next start
  after an unclean exit and which no automated cycle can answer.

So the engine owns the sequence: stop, archive recovery files, clear the lock,
launch, wait for the bridge handshake. Recovery files are *archived*, never
deleted -- they can hold unsaved work, and suppressing a dialog is not a licence
to destroy the data behind it.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

STUDIO_PROCESS = "RobloxStudioBeta.exe"
RECOVERY_GLOB = "*_AutoRecovery_*.rbx*"


def studio_executable() -> Path:
    """Locate RobloxStudioBeta.exe, preferring the newest installed version."""
    local_app_data = os.environ.get("LOCALAPPDATA")
    candidates: list[Path] = []
    if local_app_data:
        versions = Path(local_app_data) / "Roblox" / "Versions"
        if versions.exists():
            found = sorted(
                versions.glob(f"version-*/{STUDIO_PROCESS}"),
                key=lambda path: path.stat().st_mtime,
                reverse=True,
            )
            candidates.extend(found)
    resolved = shutil.which(STUDIO_PROCESS)
    if resolved:
        candidates.append(Path(resolved))
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError("Roblox Studio was not found on this machine")


def autosave_dir() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if not local_app_data:
        raise RuntimeError("LOCALAPPDATA is not set")
    return Path(local_app_data) / "Roblox" / "RobloxStudio" / "AutoSaves"


def studio_running() -> bool:
    try:
        result = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {STUDIO_PROCESS}", "/FO", "CSV", "/NH"],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return STUDIO_PROCESS in result.stdout


def stop_studio(wait_seconds: float = 15.0) -> dict[str, Any]:
    """Terminate Studio and wait for the process to actually disappear."""
    if not studio_running():
        return {"stopped": False, "wasRunning": False}
    subprocess.run(
        ["taskkill", "/F", "/IM", STUDIO_PROCESS],
        capture_output=True, text=True, timeout=20, check=False,
    )
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if not studio_running():
            return {"stopped": True, "wasRunning": True}
        time.sleep(0.5)
    return {"stopped": False, "wasRunning": True, "reason": "process did not exit in time"}


def archive_recovery_files(archive_root: Path) -> dict[str, Any]:
    """Move auto-recovery files aside so Studio starts without the modal.

    Studio shows "Um arquivo de recuperação automática foi detectado" whenever
    these exist after an unclean exit. The dialog blocks the viewport until a
    human answers it, so any automated restart has to clear them first -- by
    moving, not deleting, because they may be the only copy of unsaved work.
    """
    source = autosave_dir()
    if not source.exists():
        return {"archived": 0, "files": [], "autoSaveDir": str(source)}

    files = sorted(source.glob(RECOVERY_GLOB))
    if not files:
        return {"archived": 0, "files": [], "autoSaveDir": str(source)}

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    destination = archive_root / f"studio-autorecovery-{stamp}"
    destination.mkdir(parents=True, exist_ok=True)

    moved: list[dict[str, Any]] = []
    for path in files:
        target = destination / path.name
        shutil.move(str(path), str(target))
        moved.append({"name": path.name, "bytes": target.stat().st_size, "archivedTo": str(target)})

    return {"archived": len(moved), "files": moved, "autoSaveDir": str(source), "archiveDir": str(destination)}


def clear_place_lock(place: Path) -> bool:
    """Remove the stale lock Studio leaves beside a place after a hard exit."""
    lock = place.with_suffix(place.suffix + ".lock")
    if lock.exists():
        lock.unlink()
        return True
    return False


#: ShowWindow constants used to keep Studio out of the user's way.
SW_SHOWMINNOACTIVE = 7
SW_MINIMIZE = 6


def foreground_window() -> tuple[int, str]:
    """Whatever window is actually on top right now."""
    import ctypes

    user32 = ctypes.windll.user32
    hwnd = user32.GetForegroundWindow()
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buffer, length + 1)
    return int(hwnd), buffer.value


def capture_is_clean(hwnd: int) -> tuple[bool, str]:
    """Is the target window the one a screen grab would actually capture?

    Screen-region capture reads pixels, not a window's own buffer, so anything
    overlapping the target ends up in the evidence. Observed for real: a capture
    aimed at Studio returned a completely different Roblox game that happened to
    be on top. A screenshot has to be able to say it is untrustworthy.
    """
    top, title = foreground_window()
    if top == hwnd:
        return True, title
    return False, title


def studio_windows() -> list[tuple[int, str]]:
    """Enumerate visible Roblox Studio top-level windows."""
    if os.name != "nt":
        return []
    import ctypes

    user32 = ctypes.windll.user32
    found: list[tuple[int, str]] = []
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    @callback_type
    def callback(hwnd, _lparam):
        length = user32.GetWindowTextLengthW(hwnd)
        if length > 0:
            buffer = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buffer, length + 1)
            if user32.IsWindowVisible(hwnd) and "roblox studio" in buffer.value.lower():
                found.append((int(hwnd), buffer.value))
        return True

    user32.EnumWindows(callback, 0)
    return found


def minimize_studio() -> int:
    """Push every Studio window out of the way without closing anything."""
    if os.name != "nt":
        return 0
    import ctypes

    user32 = ctypes.windll.user32
    count = 0
    for hwnd, _title in studio_windows():
        user32.ShowWindow(hwnd, SW_MINIMIZE)
        count += 1
    return count


def launch_studio(place: Path, background: bool = True) -> dict[str, Any]:
    """Open a place, passing it as an argument rather than driving the UI.

    ``background`` keeps Studio from stealing focus: the process is asked to
    start minimised and inactive. Studio can still raise itself once its own
    windows are up, so callers should minimise again after the handshake.
    """
    if not place.exists():
        raise FileNotFoundError(f"place not found: {place}")
    executable = studio_executable()

    startupinfo = None
    if background and os.name == "nt":
        startupinfo = subprocess.STARTUPINFO()
        startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startupinfo.wShowWindow = SW_SHOWMINNOACTIVE

    subprocess.Popen(
        [str(executable), str(place)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "DETACHED_PROCESS", 0),
        startupinfo=startupinfo,
    )
    return {"launched": True, "executable": str(executable), "place": str(place), "background": background}


def _focus_studio() -> tuple[Any, int, str]:
    """Bring Studio to the foreground, and verify it actually got there.

    Windows refuses `SetForegroundWindow` from a process that is not already
    foreground, and it fails *silently*. A keystroke sent after a refused focus
    lands in whatever the user was typing into -- so focus is attached to the
    current foreground thread first, and then confirmed.
    """
    import ctypes

    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32

    windows = studio_windows()
    if not windows:
        raise RuntimeError("no Roblox Studio window found")
    hwnd, title = windows[0]

    user32.ShowWindow(hwnd, 9)  # SW_RESTORE

    foreground = user32.GetForegroundWindow()
    target_thread = user32.GetWindowThreadProcessId(hwnd, None)
    current_thread = kernel32.GetCurrentThreadId()
    foreground_thread = user32.GetWindowThreadProcessId(foreground, None) if foreground else 0

    attached = False
    if foreground_thread and foreground_thread != current_thread:
        attached = bool(user32.AttachThreadInput(foreground_thread, current_thread, True))

    # Notices first, and this is where it mattered most. The window holding
    # foreground was Studio's own "lighting technology migration" dialog: every
    # focus attempt was refused because the thing refusing was a modal nobody
    # had closed. The dismissal existed and was only wired into the capture
    # path, so the one place that actually needed it never called it.
    try:
        from ..capture import Win32CaptureBackend, WindowIdentity

        backend = Win32CaptureBackend()
        outcome = backend.dismiss_notices(WindowIdentity(hwnd, 0, title))
        if outcome["dismissed"]:
            time.sleep(0.6)
    except Exception:  # noqa: BLE001 - never fail the launch on cleanup
        pass

    try:
        # Windows grants foreground only to a process that received the last
        # input event, and an agent driving Studio in a loop never has. Being
        # the source of one first -- a modifier pressed and released, changing
        # nothing -- is the documented way through.
        #
        # Without it the agentic path stops at "click the Studio window once",
        # which is the manual step this whole loop exists to remove.
        user32.keybd_event(0x12, 0, 0, 0)          # VK_MENU down
        user32.keybd_event(0x12, 0, 0x0002, 0)     # VK_MENU up
        user32.ShowWindow(hwnd, 9)                 # SW_RESTORE, in case minimised
        # Topmost, then back: the z-order change is honoured where a bare
        # SetForegroundWindow is refused, and dropping topmost again afterwards
        # avoids leaving Studio pinned over everything the user opens next.
        HWND_TOPMOST, HWND_NOTOPMOST = -1, -2
        SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW = 0x0002, 0x0001, 0x0040
        flags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW
        user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, flags)
        user32.SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, flags)
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)

        # Last escalation, and the one that actually holds: minimise then
        # restore. Windows treats a restore as a user-initiated activation, so
        # it grants foreground where SetForegroundWindow alone is refused. Ugly,
        # visible, and the difference between an unattended loop and "click the
        # Studio window once".
        if user32.GetForegroundWindow() != hwnd:
            user32.ShowWindow(hwnd, 6)   # SW_MINIMIZE
            time.sleep(0.2)
            user32.ShowWindow(hwnd, 9)   # SW_RESTORE
            time.sleep(0.4)
            user32.SetForegroundWindow(hwnd)

        if target_thread and target_thread != current_thread:
            user32.AttachThreadInput(target_thread, current_thread, True)
            user32.SetFocus(hwnd)
            user32.AttachThreadInput(target_thread, current_thread, False)
    finally:
        if attached:
            user32.AttachThreadInput(foreground_thread, current_thread, False)

    time.sleep(1.0)

    if user32.GetForegroundWindow() != hwnd:
        # Last resort: ask Windows to hand foreground rights over explicitly.
        # `AllowSetForegroundWindow(ASFW_ANY)` lets any process take foreground,
        # and `SwitchToThisWindow` is the shell's own activation path -- the one
        # Alt-Tab uses, which is not subject to the same lock.
        user32.AllowSetForegroundWindow(-1)     # ASFW_ANY
        user32.SwitchToThisWindow(hwnd, True)
        time.sleep(0.6)

    if user32.GetForegroundWindow() != hwnd:
        raise RuntimeError(
            "could not bring Roblox Studio to the foreground; Windows refused the focus change. "
            "Click the Studio window once, or run this while Studio is already focused."
        )

    return user32, hwnd, title


def stop_play_solo(bridge: Any | None = None, wait_seconds: float = 30.0) -> dict[str, Any]:
    """End a Play Solo session.

    F5 starts a session but does nothing to one already running -- stopping is
    Shift+F5. Without this a scenario asking for a fresh player silently reuses
    the old one and fails on state it never set.
    """
    if os.name != "nt":
        raise RuntimeError("Play Solo automation is implemented for Windows only")

    user32, _hwnd, title = _focus_studio()

    VK_SHIFT, VK_F5 = 0x10, 0x74
    user32.keybd_event(VK_SHIFT, 0, 0, 0)
    user32.keybd_event(VK_F5, 0, 0, 0)
    user32.keybd_event(VK_F5, 0, 2, 0)
    user32.keybd_event(VK_SHIFT, 0, 2, 0)

    result: dict[str, Any] = {"keySent": "Shift+F5", "focusedWindow": title}
    if bridge is None:
        return result

    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        try:
            sessions = bridge.status().get("sessions", [])
        except Exception:
            sessions = []
        if not [item for item in sessions if item.get("context") in {"run", "server", "client"}]:
            result["stopped"] = True
            return result
        time.sleep(1.0)

    result["stopped"] = False
    return result


def start_play_solo(bridge: Any | None = None, wait_seconds: float = 90.0, restart: bool = False) -> dict[str, Any]:
    """Start a Play Solo session, the only way to get a real Player.

    This is the one action that cannot be scripted. `RunService:Run()` gives
    real physics and navigation but no Player, and ProximityPrompt activation is
    attributed to a Player -- so prompt-driven gameplay needs Play Solo.

    Studio ignores synthesised key messages (PostMessage was measured doing
    nothing), so the window must be focused for the keystroke to land. That
    takes the screen for a moment; it is the documented cost of this call, not
    an accident.
    """
    if os.name != "nt":
        raise RuntimeError("Play Solo automation is implemented for Windows only")

    # A session already running would swallow the F5 and leave the old player in
    # place, so end it first when a fresh one was asked for.
    stopped: dict[str, Any] | None = None
    if restart and bridge is not None:
        try:
            running = [
                item for item in bridge.status().get("sessions", [])
                if item.get("context") in {"run", "server", "client"}
            ]
        except Exception:
            running = []
        if running:
            stopped = stop_play_solo(bridge)
            time.sleep(2)

    # The client bridge goes in *before* the session starts, because
    # `bridge.install_client` is an edit-context command and there is no edit
    # context once F5 has landed.
    #
    # This lived in the scenario runner and only there, so every hand-driven
    # `rqe studio play_solo` produced a session with no client half. Nothing
    # reported it: `InvokeClient` on a RemoteFunction with no `OnClientInvoke`
    # handler does not error, it yields forever, so `client.camera_set` came
    # back as a bridge timeout and read like a flaky plugin. Every `client.*`
    # command was unreachable from the manual path -- camera control, GUI
    # clicks, viewport reads, player state.
    installed: dict[str, Any] | None = None
    if bridge is not None:
        try:
            installed = {"ok": True, "detail": bridge.call("bridge.install_client", timeout=40)}
        except Exception as error:
            # Reported, not raised. Play Solo without the client half is still
            # worth having -- capture and the server commands work -- and a
            # caller that only wanted a Player should not be stopped by an
            # instrumentation failure. It just must not look like success.
            installed = {"ok": False, "error": str(error)}

    user32, _hwnd, title = _focus_studio()

    known: set[str] = set()
    if bridge is not None:
        try:
            known = {item["session"] for item in bridge.status().get("sessions", [])}
        except Exception:
            known = set()

    VK_F5 = 0x74
    user32.keybd_event(VK_F5, 0, 0, 0)
    user32.keybd_event(VK_F5, 0, 2, 0)

    result: dict[str, Any] = {"keySent": "F5", "focusedWindow": title}
    if installed is not None:
        result["clientBridge"] = installed
    if stopped is not None:
        result["stoppedPrevious"] = stopped

    if bridge is None:
        result["waited"] = False
        return result

    started = time.monotonic()
    deadline = started + wait_seconds
    play_sessions: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        try:
            sessions = bridge.status().get("sessions", [])
        except Exception:
            sessions = []
        play_sessions = [
            item for item in sessions
            if item["session"] not in known and item.get("context") in {"run", "server", "client"}
        ]
        if play_sessions:
            break
        time.sleep(1.0)

    result["waited"] = True
    result["seconds"] = round(time.monotonic() - started, 1)
    result["playSessions"] = play_sessions
    result["started"] = bool(play_sessions)
    return result


def restart_for_bridge(
    place: Path,
    archive_root: Path,
    bridge: Any | None = None,
    wait_seconds: float = 180.0,
    background: bool = True,
) -> dict[str, Any]:
    """Stop Studio, clear what blocks an unattended start, launch, and connect.

    With a ``bridge`` the call returns only once the plugin has handshaken, so
    the caller knows Studio is genuinely ready rather than merely launched.
    """
    steps: dict[str, Any] = {}

    # Snapshot first: the Studio about to be killed may still be connected, and
    # its session lingers for a while afterwards. Waiting for "any session"
    # would return instantly against that corpse and report a restart as ready
    # before the new Studio had even loaded.
    known: set[str] = set()
    if bridge is not None:
        try:
            known = {item["session"] for item in bridge.status().get("sessions", [])}
        except Exception:  # a hub that is not up yet is not an error here
            known = set()

    steps["stop"] = stop_studio()

    # We killed those processes, so their sessions are definitively dead. Say so
    # explicitly: a killed plugin's poll handler stays blocked until it tries to
    # write, so the hub would keep treating the corpse as a live candidate.
    if bridge is not None and known:
        try:
            steps["retiredSessions"] = bridge.drop_sessions(sorted(known), "studio terminated by rqe studio restart")
        except Exception as exc:
            steps["retiredSessions"] = {"error": str(exc)}

    steps["recovery"] = archive_recovery_files(archive_root)
    steps["lockCleared"] = clear_place_lock(place)
    steps["launch"] = launch_studio(place, background=background)

    if bridge is None:
        steps["handshake"] = {"waited": False, "reason": "no bridge supplied"}
        return steps

    started = time.monotonic()
    deadline = started + wait_seconds
    fresh: list[dict[str, Any]] = []
    while time.monotonic() < deadline:
        try:
            sessions = bridge.status().get("sessions", [])
        except Exception:
            sessions = []
        fresh = [item for item in sessions if item["session"] not in known and item.get("polls", 0) > 0]
        if fresh:
            break
        time.sleep(1.0)

    steps["handshake"] = {
        "waited": True,
        "seconds": round(time.monotonic() - started, 1),
        "sessions": fresh,
        "supersededSessions": sorted(known),
    }

    if background:
        # Studio raises its own windows once they exist, regardless of how the
        # process was asked to start. Push them back down now that it is ready,
        # so an automated run never takes the screen from whoever is using it.
        steps["minimized"] = minimize_studio()

    return steps
