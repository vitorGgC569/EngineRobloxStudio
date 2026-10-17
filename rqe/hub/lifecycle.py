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

import json
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from ..workspace import hub_url

STUDIO_PROCESS = "RobloxStudioBeta.exe"
RECOVERY_GLOB = "*_AutoRecovery_*.rbx*"
PROCESS_RECEIPT_DIRECTORY = "studio-processes"


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _windows_powershell_environment(overrides: dict[str, str]) -> dict[str, str]:
    """Environment for ``powershell.exe`` that cannot inherit PowerShell 7 modules.

    Windows PowerShell 5.1 treats an inherited ``PSModulePath`` as complete. A
    parent ``pwsh`` session stores that variable as ``PSMODULEPATH`` and points
    it at PowerShell 7 modules, so ``Get-AuthenticodeSignature`` never runs and
    Studio restart reports that no signed executable exists. ``os.environ.copy()``
    is a plain dict: assigning ``PSModulePath`` leaves the original
    ``PSMODULEPATH`` key beside it, and CreateProcess may hand the child either
    value. Drop every case variant, then set only the Windows PowerShell system
    module directory. Signature checking stays on.
    """

    environment = dict(os.environ)
    for key in [key for key in environment if key.lower() == "psmodulepath"]:
        del environment[key]
    system_root = next(
        (value for key, value in environment.items() if key.lower() == "systemroot" and value),
        r"C:\Windows",
    )
    environment["PSModulePath"] = (
        system_root.rstrip("\\/") + r"\System32\WindowsPowerShell\v1.0\Modules"
    )
    environment.update(overrides)
    return environment


_VERIFIER_OUTPUT_LIMIT = 240


def _verifier_snippet(text: str) -> str:
    """One short line of verifier output, safe to put in a restart reason."""

    collapsed = " ".join(str(text or "").split())
    if len(collapsed) <= _VERIFIER_OUTPUT_LIMIT:
        return collapsed
    return collapsed[:_VERIFIER_OUTPUT_LIMIT]


def _verifier_failure(
    target: Path,
    context: str,
    output: str,
    exit_code: int | None = None,
) -> RuntimeError:
    """Verification failed. Keep the context and the output that explains why.

    The old error named only the executable path. PowerShell had already
    printed the module-path or signature failure on stderr, and that text was
    discarded, so the restart looked like a missing Studio.
    """

    snippet = _verifier_snippet(output)
    parts = [f"context={context}"]
    if exit_code is not None:
        parts.append(f"exit={exit_code}")
    if snippet:
        parts.append(f"output={snippet}")
    error = RuntimeError(
        f"could not verify Studio executable {target} ({', '.join(parts)})"
    )
    setattr(error, "verifier", {
        "context": context,
        "exitCode": exit_code,
        "output": snippet,
    })
    return error


def _blocked_executable_verification(exc: BaseException) -> dict[str, Any]:
    """Same blocked restart shape as an unsafe stop, plus the verifier detail."""

    verifier = getattr(exc, "verifier", None)
    if not isinstance(verifier, dict):
        verifier = {
            "context": "studio-executable",
            "exitCode": None,
            "output": _verifier_snippet(str(exc)),
        }
    return {
        "blocked": True,
        "reason": str(exc),
        "verifier": verifier,
        "handshake": {"waited": False, "sessions": []},
    }


def _studio_binary_metadata(path: Path) -> dict[str, Any]:
    """Verify Authenticode identity and return stable version/hash metadata."""

    target = path.resolve(strict=True)
    if target.name.lower() != STUDIO_PROCESS.lower():
        raise RuntimeError(f"unexpected Studio executable name: {target.name}")
    if os.name != "nt":
        raise RuntimeError("Roblox Studio executable verification requires Windows")
    environment = _windows_powershell_environment({
        "RQE_VERIFY_EXECUTABLE": str(target),
    })
    script = (
        "$p=$env:RQE_VERIFY_EXECUTABLE;"
        "$f=Get-Item -LiteralPath $p -ErrorAction Stop;"
        "$s=Get-AuthenticodeSignature -LiteralPath $p;"
        "[pscustomobject]@{status=$s.Status.ToString();"
        "signer=if($s.SignerCertificate){$s.SignerCertificate.Subject}else{''};"
        "version=$f.VersionInfo.FileVersion}|ConvertTo-Json -Compress"
    )
    completed = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
        env=environment,
    )
    if completed.returncode != 0:
        output = (completed.stderr or "").strip() or (completed.stdout or "").strip()
        raise _verifier_failure(target, "powershell-exit", output, completed.returncode)
    try:
        metadata = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        output = (completed.stdout or "").strip() or (completed.stderr or "").strip()
        raise _verifier_failure(target, "invalid-json", output, completed.returncode) from exc
    if not isinstance(metadata, dict):
        raise _verifier_failure(target, "invalid-json", completed.stdout or "", completed.returncode)
    if metadata.get("status") != "Valid" or "Roblox Corporation" not in str(metadata.get("signer") or ""):
        output = (completed.stdout or "").strip() or (
            f"status={metadata.get('status')!s} signer={metadata.get('signer')!s}"
        )
        raise _verifier_failure(target, "bad-signature", output, completed.returncode)
    version_numbers = tuple(int(item) for item in re.findall(r"\d+", str(metadata.get("version") or "")))
    if not version_numbers:
        raise _verifier_failure(
            target,
            "unparsed-version",
            completed.stdout or "",
            completed.returncode,
        )
    return {
        "path": str(target),
        "version": ".".join(str(item) for item in version_numbers),
        "versionTuple": version_numbers,
        "signatureStatus": metadata["status"],
        "signer": metadata["signer"],
        "sha256": _sha256_file(target),
    }


def studio_executable() -> Path:
    """Locate the highest signed Roblox Studio file version on this machine."""
    local_app_data = os.environ.get("LOCALAPPDATA")
    candidates: list[Path] = []
    if local_app_data:
        versions = Path(local_app_data) / "Roblox" / "Versions"
        if versions.exists():
            candidates.extend(versions.glob(f"version-*/{STUDIO_PROCESS}"))
    resolved = shutil.which(STUDIO_PROCESS)
    if resolved:
        candidates.append(Path(resolved))
    verified: list[dict[str, Any]] = []
    rejected: list[str] = []
    verifier: dict[str, Any] | None = None
    seen: set[Path] = set()
    for candidate in candidates:
        try:
            resolved = candidate.resolve(strict=True)
            if resolved in seen:
                continue
            seen.add(resolved)
            verified.append(_studio_binary_metadata(resolved))
        except (OSError, RuntimeError) as exc:
            rejected.append(str(exc))
            if verifier is None and isinstance(getattr(exc, "verifier", None), dict):
                verifier = exc.verifier
    if verified:
        chosen = max(verified, key=lambda item: item["versionTuple"])
        return Path(chosen["path"])
    detail = f" ({'; '.join(rejected[:3])})" if rejected else ""
    error = FileNotFoundError("no valid Roblox-signed Studio executable was found" + detail)
    if verifier is None:
        verifier = {
            "context": "not-found",
            "exitCode": None,
            "output": _verifier_snippet(detail or "no Studio executable candidate"),
        }
    setattr(error, "verifier", verifier)
    raise error


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


def _process_receipt_directory() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if not local_app_data:
        raise RuntimeError("LOCALAPPDATA is not set; cannot track RQE-owned Studio processes")
    return Path(local_app_data).resolve() / "RQE" / PROCESS_RECEIPT_DIRECTORY


def _process_identity(pid: int) -> dict[str, Any] | None:
    """Read identity fields that prevent a recycled PID from being killed."""

    if os.name != "nt" or pid < 1:
        return None
    environment = _windows_powershell_environment({
        "RQE_PROCESS_ID": str(pid),
    })
    script = (
        "$p=Get-Process -Id ([int]$env:RQE_PROCESS_ID) -ErrorAction SilentlyContinue;"
        "if($null -ne $p){"
        "$path='';try{$path=$p.Path}catch{};"
        "[pscustomobject]@{pid=$p.Id;path=$path;"
        "startedAt=$p.StartTime.ToUniversalTime().ToString('o')}|ConvertTo-Json -Compress}"
    )
    try:
        completed = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
            env=environment,
        )
        if completed.returncode != 0 or not completed.stdout.strip():
            return None
        payload = json.loads(completed.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, ValueError):
        return None
    if not isinstance(payload, dict) or int(payload.get("pid") or 0) != pid:
        return None
    return {
        "pid": pid,
        "path": str(payload.get("path") or ""),
        "startedAt": str(payload.get("startedAt") or ""),
    }


def _record_studio_process(pid: int, executable: Path, place: Path) -> Path:
    identity = _process_identity(pid)
    if identity is None or not identity["startedAt"]:
        raise RuntimeError(f"could not verify launched Studio process {pid}")
    directory = _process_receipt_directory()
    directory.mkdir(parents=True, exist_ok=True)
    receipt = directory / f"{pid}.json"
    temporary = directory / f".{pid}.{os.getpid()}.tmp"
    payload = {
        "schemaVersion": 1,
        "pid": pid,
        "path": str(executable.resolve()),
        "startedAt": identity["startedAt"],
        "place": str(place.resolve()),
        "recordedAt": datetime.now(timezone.utc).isoformat(),
    }
    temporary.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, receipt)
    return receipt


def _owned_studio_processes() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    directory = _process_receipt_directory()
    if not directory.exists():
        return [], []
    owned: list[dict[str, Any]] = []
    ignored: list[dict[str, Any]] = []
    for receipt in directory.glob("*.json"):
        try:
            record = json.loads(receipt.read_text(encoding="utf-8"))
            pid = int(record["pid"])
            identity = _process_identity(pid)
            same_path = (
                identity is not None
                and identity["path"]
                and Path(identity["path"]).resolve() == Path(record["path"]).resolve()
            )
            same_start = identity is not None and identity["startedAt"] == record.get("startedAt")
            if same_path and same_start and Path(record["path"]).name.lower() == STUDIO_PROCESS.lower():
                owned.append({**record, "receipt": str(receipt)})
            else:
                ignored.append({"pid": pid, "reason": "process identity no longer matches its RQE receipt"})
                receipt.unlink(missing_ok=True)
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            ignored.append({"receipt": str(receipt), "reason": "invalid process receipt"})
    return owned, ignored


def _pid_alive(pid: int) -> bool:
    return _process_identity(pid) is not None


def stop_studio(wait_seconds: float = 15.0) -> dict[str, Any]:
    """Stop only Studio PIDs previously launched and receipted by RQE."""

    was_running = studio_running()
    owned, ignored = _owned_studio_processes()
    if not owned:
        result: dict[str, Any] = {
            "stopped": False,
            "wasRunning": was_running,
            "ownedPids": [],
            "ignoredReceipts": ignored,
        }
        if was_running:
            result["reason"] = "Studio is running but no matching RQE-owned process receipt exists"
        return result
    pids = [int(item["pid"]) for item in owned]
    for pid in pids:
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        remaining = [pid for pid in pids if _pid_alive(pid)]
        if not remaining:
            for item in owned:
                Path(item["receipt"]).unlink(missing_ok=True)
            return {
                "stopped": True,
                "wasRunning": was_running,
                "ownedPids": pids,
                "forcedPids": [],
                "ignoredReceipts": ignored,
            }
        time.sleep(0.5)
    remaining = [pid for pid in pids if _pid_alive(pid)]
    for pid in remaining:
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    force_deadline = time.monotonic() + min(5.0, wait_seconds)
    while time.monotonic() < force_deadline and any(_pid_alive(pid) for pid in remaining):
        time.sleep(0.25)
    still_alive = [pid for pid in remaining if _pid_alive(pid)]
    for item in owned:
        if int(item["pid"]) not in still_alive:
            Path(item["receipt"]).unlink(missing_ok=True)
    return {
        "stopped": not still_alive,
        "wasRunning": was_running,
        "ownedPids": pids,
        "forcedPids": remaining,
        "ignoredReceipts": ignored,
        "remainingPids": still_alive,
        "reason": "owned Studio process did not exit in time" if still_alive else "",
    }


#: Where the hub listens. Matches `rqe.py studio serve`'s default.
HUB_URL = hub_url()


def hub_alive(url: str = HUB_URL, timeout: float = 3.0) -> bool:
    """Is the bridge hub answering?"""
    import urllib.error
    import urllib.request

    payload = json.dumps({"jsonrpc": "2.0", "id": 1,
                          "method": "bridge.ping", "params": {}}).encode()
    request = urllib.request.Request(
        url.rstrip("/") + "/rpc", data=payload,
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout):
            return True
    except urllib.error.HTTPError:
        #: An error *response* still proves something is listening, which is
        #: the only question being asked here.
        return True
    except (urllib.error.URLError, OSError):
        return False


def ensure_hub(root: Path | str | None = None, url: str = HUB_URL,
               wait_seconds: float = 25.0) -> dict[str, Any]:
    """Start the bridge hub if nothing is answering, and wait for it.

    The hub is long-running infrastructure and the documentation says to leave
    it up, which is exactly why its absence is so disorienting: every command
    fails with connection refused and none of them mention the hub. It has
    died mid-session -- taking a whole restart flow with it -- and the recovery
    was to notice and start it by hand.

    Nothing here kills it: `stop_studio` targets the Studio image only. This is
    for the case where it is already gone, so a restart can carry on instead of
    stopping to be rescued.
    """
    if hub_alive(url):
        return {"started": False, "alive": True}

    #: Walk up for `rqe.py` rather than assuming a depth. A caller passes the
    #: place file, the repo root, or nothing, and all three should work.
    base = Path(root).resolve() if root else Path.cwd().resolve()
    if base.is_file():
        base = base.parent
    entry = None
    for candidate in (base, *base.parents):
        if (candidate / "rqe.py").is_file():
            entry = candidate / "rqe.py"
            break
    if entry is None:
        return {"started": False, "alive": False,
                "reason": f"no rqe.py at or above {base}; pass root="}
    base = entry.parent

    #: Detached, so it outlives the caller the way a hub started by hand does.
    subprocess.Popen(
        [sys.executable, str(entry), "studio", "serve"],
        cwd=str(base),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "DETACHED_PROCESS", 0),
    )

    deadline = time.monotonic() + wait_seconds
    while time.monotonic() < deadline:
        if hub_alive(url):
            return {"started": True, "alive": True,
                    "seconds": round(wait_seconds - (deadline - time.monotonic()), 1)}
        time.sleep(0.5)
    return {"started": True, "alive": False,
            "reason": f"hub did not answer within {wait_seconds}s"}


def archive_recovery_files(archive_root: Path) -> dict[str, Any]:
    """Move auto-recovery files aside so Studio starts without the modal.

    Studio shows "Um arquivo de recuperaÃ§Ã£o automÃ¡tica foi detectado" whenever
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
    binary = _studio_binary_metadata(executable)

    startupinfo = None
    if background and os.name == "nt":
        startupinfo = subprocess.STARTUPINFO()
        startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startupinfo.wShowWindow = SW_SHOWMINNOACTIVE

    process = subprocess.Popen(
        [str(executable), str(place)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "DETACHED_PROCESS", 0),
        startupinfo=startupinfo,
    )
    try:
        receipt = _record_studio_process(process.pid, executable, place)
    except Exception:
        # Never leave an untracked process behind after promising PID-scoped
        # lifecycle control. Terminate only the PID created above.
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        raise
    return {
        "launched": True,
        "pid": process.pid,
        "processReceipt": str(receipt),
        "executable": str(executable),
        "executableVersion": binary["version"],
        "executableSha256": binary["sha256"],
        "signatureStatus": binary["signatureStatus"],
        "place": str(place),
        "background": background,
    }


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
        # [[
        #     Release the foreground lock, then ask again.
        #
        #     Windows refuses `SetForegroundWindow` from a process that does
        #     not own the foreground, and the lock only clears on input. A
        #     synthesised ALT press and release counts: it is the documented
        #     way to reset the foreground lock timeout, and it costs nothing
        #     because ALT alone does nothing to Studio.
        #
        #     Retried rather than tried once. Whether this succeeds depends on
        #     what else the desktop is doing at that instant, and the whole
        #     release pipeline â€” Play Solo, and therefore every runtime and
        #     visual measurement â€” hangs off it. One refusal is not evidence
        #     that it cannot be done.
        # ]]
        VK_MENU = 0x12
        for _ in range(6):
            user32.keybd_event(VK_MENU, 0, 0, 0)
            user32.keybd_event(VK_MENU, 0, 2, 0)
            user32.AllowSetForegroundWindow(-1)   # ASFW_ANY
            user32.ShowWindow(hwnd, 9)            # SW_RESTORE
            user32.SetForegroundWindow(hwnd)
            user32.SwitchToThisWindow(hwnd, True)
            time.sleep(0.5)
            if user32.GetForegroundWindow() == hwnd:
                break

    if user32.GetForegroundWindow() != hwnd:
        raise RuntimeError(
            "could not bring Roblox Studio to the foreground; Windows refused the focus change. "
            "Click the Studio window once, or run this while Studio is already focused."
        )

    return user32, hwnd, title


def _stop_play_solo_foreground_legacy(bridge: Any | None = None, wait_seconds: float = 30.0) -> dict[str, Any]:
    """End a Play Solo session.

    F5 starts a session but does nothing to one already running -- stopping is
    Shift+F5. Without this a scenario asking for a fresh player silently reuses
    the old one and fails on state it never set.
    """
    if os.name != "nt":
        raise RuntimeError("Play Solo automation is implemented for Windows only")

    # [[
    #    Stop a simulation the way it was started.
    #
    #    Shift+F5 ends a *Play* session. It does nothing at all to one started
    #    by `RunService:Run()` through the bridge, which is what `run.start`
    #    does and what every measurement pass leaves behind â€” so this returned
    #    `stopped: false`, `bridge.install_client` was then refused for
    #    "context run", the F5 that followed was swallowed by the still-running
    #    simulation, and Play Solo never began. Four symptoms, one cause, none
    #    of them naming it.
    #
    #    So a `run` context is stopped over the bridge and only a real play
    #    session gets the keystroke. Best effort: if the command fails the
    #    keystroke below is still worth sending.
    # ]]
    running_headless = False
    if bridge is not None:
        try:
            running_headless = any(
                item.get("context") == "run"
                for item in bridge.status().get("sessions", [])
            )
        except Exception:
            running_headless = False
    stopped_over_bridge: Any | None = None
    if running_headless:
        try:
            with bridge.lease_scope(
                agent_id="studio-lifecycle-stop-run",
                context="running",
                ttl_seconds=60.0,
                release_required=False,
            ):
                stopped_over_bridge = bridge.run_stop()
        except Exception as error:
            stopped_over_bridge = {"error": str(error)}
        else:
            # [[
            #     Wait for the editor to come back, do not guess at it.
            #
            #     `RunService:Stop()` returns before Studio has finished
            #     restoring the edit DataModel, and that restore *discards*
            #     what the run touched. Installing the client half two fixed
            #     seconds later wrote it into a document that was about to be
            #     thrown away: the channel reported installed, the play session
            #     started without it, and `client.viewport` timed out saying
            #     the client half is not running â€” which was true, and said
            #     nothing about why.
            #
            #     So this waits for an edit-context session to actually be
            #     there, and gives up after a bounded time rather than looping
            #     forever on a Studio that never came back.
            # ]]
            deadline = time.monotonic() + 30.0
            while time.monotonic() < deadline:
                try:
                    contexts = {item.get("context")
                                for item in bridge.status().get("sessions", [])}
                except Exception:
                    contexts = set()
                if "edit" in contexts and not (contexts & {"run", "server", "client"}):
                    break
                time.sleep(1.0)
            # A beat more: the session announces itself as soon as the plugin
            # reconnects, which is a little before the DataModel settles.
            time.sleep(2)

            # [[
            #     Re-pin: a session id does not survive stopping the run.
            #
            #     The pin exists so consecutive reads cannot mix two
            #     DataModels, and it is worth having. But Studio tears the
            #     plugin down with the simulation and reconnects it under a
            #     *new* id, so every pinned call afterwards answered
            #     "E_NOT_FOUND: no connected plugin session" â€” including the
            #     one that installs the client half. That was reported as an
            #     instrumentation nicety and swallowed, and surfaced much later
            #     as `client.viewport` timing out, a one-pixel viewport, an
            #     untrustworthy capture set and a visual score of zero.
            # ]]
            if getattr(bridge, "pinned_session", None):
                try:
                    live = [item for item in bridge.status().get("sessions", [])
                            if item.get("context") == "edit"]
                except Exception:
                    live = []
                if len(live) == 1:
                    bridge.pinned_session = str(live[0]["session"])
                else:
                    # Two editors, or none: pinning to a guess would install
                    # the client half into the wrong place, which is worse
                    # than not pinning at all.
                    bridge.pinned_session = None

    VK_SHIFT, VK_F5 = 0x10, 0x74

    def press() -> str:
        """Focus Studio and send Shift+F5. Returns the window it landed on."""
        user32, _hwnd, window = _focus_studio()
        user32.keybd_event(VK_SHIFT, 0, 0, 0)
        user32.keybd_event(VK_F5, 0, 0, 0)
        user32.keybd_event(VK_F5, 0, 2, 0)
        user32.keybd_event(VK_SHIFT, 0, 2, 0)
        return window

    title = press()
    result: dict[str, Any] = {"keySent": "Shift+F5", "focusedWindow": title,
                              "attempts": 1}
    if stopped_over_bridge is not None:
        result["runStop"] = stopped_over_bridge
    if bridge is None:
        return result

    #[[
    #    Retry the keystroke, do not send it once and hope.
    #
    #    This sent Shift+F5 a single time and then waited out the whole timeout
    #    watching for the session to disappear. When Studio is mid-frame, busy
    #    compiling, or briefly not the foreground window, the key is simply
    #    lost -- and the call then reported `stopped: false` forty seconds later
    #    having done nothing since the first second.
    #
    #    Studio ignores synthesised messages that are not sent to a focused
    #    window, so a lost keystroke is not rare; it is the normal outcome of
    #    pressing at a bad moment. Pressing again every few seconds costs
    #    nothing and turns a coin-flip into a certainty.
    #]]
    live: list[dict[str, Any]] = []
    deadline = time.monotonic() + wait_seconds
    next_press = time.monotonic() + 4.0
    while time.monotonic() < deadline:
        try:
            sessions = bridge.status().get("sessions", [])
        except Exception:
            sessions = []
        live = [item for item in sessions
                if item.get("context") in {"run", "server", "client"}]
        if not live:
            result["stopped"] = True
            return result

        if time.monotonic() >= next_press:
            title = press()
            result["attempts"] += 1
            result["focusedWindow"] = title
            next_press = time.monotonic() + 4.0
        time.sleep(1.0)

    #: Say what was still there. `stopped: false` on its own tells a caller
    #: that something went wrong and nothing about what to do next.
    result["stopped"] = False
    result["stillRunning"] = [
        {"session": item.get("session"), "context": item.get("context"),
         "place": item.get("place")}
        for item in live
    ]
    result["hint"] = (
        "Shift+F5 was sent {n} times to '{w}' and the session outlived it. "
        "If the window named there is not Studio, focus is going elsewhere; "
        "otherwise restart_for_bridge() ends it unconditionally."
    ).format(n=result["attempts"], w=title)
    return result



def stop_play_solo(
    bridge: Any | None = None,
    wait_seconds: float = 30.0,
    allow_foreground_fallback: bool = False,
) -> dict[str, Any]:
    """Stop Play/Run natively; foreground Shift+F5 is explicit fallback only."""
    native_error = ""
    stopped_over_bridge: Any | None = None

    if bridge is not None:
        try:
            sessions = bridge.status().get("sessions", [])
        except Exception as exc:
            sessions = []
            native_error = str(exc)

        run_sessions = [item for item in sessions if item.get("context") == "run"]
        if run_sessions:
            try:
                bridge.pinned_session = str(run_sessions[0]["session"])
                with bridge.lease_scope(
                    agent_id="studio-lifecycle-stop-run",
                    session_id=bridge.pinned_session,
                    context="running",
                    ttl_seconds=60.0,
                    release_required=False,
                ):
                    stopped_over_bridge = bridge.run_stop()
                deadline = time.monotonic() + min(wait_seconds, 30.0)
                while time.monotonic() < deadline:
                    live = [
                        item for item in bridge.status().get("sessions", [])
                        if item.get("context") in {"run", "server", "client"}
                    ]
                    if not live:
                        return {
                            "stopped": True,
                            "native": True,
                            "controller": "RunService",
                            "foregroundFallbackUsed": False,
                            "runStop": stopped_over_bridge,
                        }
                    time.sleep(0.5)
                native_error = "run.stop returned but runtime sessions remained active"
            except Exception as exc:
                native_error = f"{type(exc).__name__}: {exc}"

        runtime = [
            item for item in sessions
            if item.get("context") in {"server", "client"}
        ]
        for candidate in runtime:
            try:
                bridge.pinned_session = str(candidate["session"])
                capabilities = bridge.call("bridge.capabilities", {}, timeout=12)
                methods = set(capabilities.get("methods") or [])
                if not {"test.status", "test.finish"}.issubset(methods):
                    continue
                status = bridge.call("test.status", {}, timeout=12)
                args = status.get("args") if isinstance(status, dict) else None
                test_id = args.get("rqeTestId") if isinstance(args, dict) else None
                if not test_id:
                    continue
                with bridge.lease_scope(
                    agent_id="studio-lifecycle-native-stop",
                    session_id=bridge.pinned_session,
                    ttl_seconds=45.0,
                    release_required=False,
                ):
                    bridge.call(
                        "test.finish",
                        {
                            "testId": str(test_id),
                            "result": {
                                "source": "rqe.hub.lifecycle",
                                "stopped": True,
                            },
                        },
                        timeout=20,
                    )
                deadline = time.monotonic() + wait_seconds
                while time.monotonic() < deadline:
                    live = [
                        item for item in bridge.status().get("sessions", [])
                        if item.get("context") in {"run", "server", "client"}
                    ]
                    if not live:
                        return {
                            "stopped": True,
                            "native": True,
                            "controller": "StudioTestService",
                            "foregroundFallbackUsed": False,
                            "testId": str(test_id),
                        }
                    time.sleep(0.5)
                native_error = "test.finish returned but runtime sessions remained active"
                break
            except Exception as exc:
                native_error = f"{type(exc).__name__}: {exc}"

    if not allow_foreground_fallback:
        result = {
            "stopped": False,
            "native": False,
            "foregroundFallbackUsed": False,
            "reason": (
                "native StudioTestService stop was unavailable or inconclusive; "
                "foreground Shift+F5 fallback is disabled"
            ),
        }
        if native_error:
            result["nativeError"] = native_error
        if stopped_over_bridge is not None:
            result["runStop"] = stopped_over_bridge
        return result

    legacy = _stop_play_solo_foreground_legacy(bridge, wait_seconds=wait_seconds)
    legacy["native"] = False
    legacy["foregroundFallbackUsed"] = True
    if native_error:
        legacy["nativeError"] = native_error
    return legacy


def _start_play_solo_foreground_legacy(bridge: Any | None = None, wait_seconds: float = 90.0, restart: bool = False) -> dict[str, Any]:
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
    def _client_script_present() -> bool:
        """Is the LocalScript actually in the place, or only reported to be?

        `bridge.install_client` answers `installed: true` from the DataModel it
        wrote to, and that is not the same claim as "the play session about to
        start will run it". Studio restoring the editor after a run, or a
        second connected session, can leave the report true and the place
        without it â€” which surfaces much later as `client.viewport` timing out
        with "the client half is not installed or not running", three commands
        away from anything that mentions installing.
        """
        try:
            children = bridge.call(
                "instance.children",
                {"path": "StarterPlayer.StarterPlayerScripts"},
                timeout=20,
            )
        except Exception:
            return False
        if not isinstance(children, dict):
            return False
        return any(
            str(item.get("name")) == "RQEClientBridge"
            for item in (children.get("children") or [])
            if isinstance(item, dict)
        )

    installed: dict[str, Any] | None = None
    if bridge is not None:
        try:
            with bridge.lease_scope(
                agent_id="studio-lifecycle-install-client",
                context="edit",
                ttl_seconds=120.0,
            ):
                detail = bridge.call("bridge.install_client", timeout=40)
                present = _client_script_present()
                if not present:
                    # One retry, because the common cause is a race with Studio
                    # finishing its restore rather than anything being wrong.
                    time.sleep(3)
                    detail = bridge.call("bridge.install_client", timeout=40)
                    present = _client_script_present()
            installed = {"ok": present, "verified": present, "detail": detail}
            if not present:
                installed["error"] = (
                    "bridge.install_client reported success but "
                    "StarterPlayerScripts.RQEClientBridge is not in the place")
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
        live = [
            item for item in sessions
            if item.get("context") in {"run", "server", "client"}
        ]
        play_sessions = [item for item in live if item["session"] not in known]
        if play_sessions:
            break
        time.sleep(1.0)
    else:
        #[[
        #   A session that was already up is still a session.
        #
        #   This only ever counted sessions *new since F5*, so a play session
        #   that survived the previous call -- which is the normal state after
        #   any repeated `play_solo`, and after a restart that did not fully
        #   tear down -- was filtered out and `started` came back False with
        #   the game visibly running.
        #
        #   `forge playtest` reads that field and refuses the run with "the
        #   game would not start". So the gate that exists to catch a broken
        #   game was refusing a working one, which is the instrument blaming
        #   the product: the exact failure `rqe/evidence.py` was written about.
        #
        #   `restart=True` is how a caller asks for a *fresh* session, and it
        #   already stops the old one above. Freshness is that flag's job, not
        #   this field's.
        #]]
        live = [
            item for item in (bridge.status().get("sessions", []) or [])
            if item.get("context") in {"run", "server", "client"}
        ]

    result["waited"] = True
    result["seconds"] = round(time.monotonic() - started, 1)
    result["playSessions"] = play_sessions
    #: Kept separate so a caller that genuinely needs a new session can still
    #: tell, without every caller having to know the difference.
    result["newSessions"] = [item["session"] for item in play_sessions]
    result["existingSessions"] = [
        item["session"] for item in live if item["session"] in known
    ]
    result["started"] = bool(play_sessions) or bool(live)

    #[[
    #   When it did not start, say what was in the way.
    #
    #   A modal dialog owns the Studio window, so F5 lands on the dialog and
    #   nothing happens -- and the caller got `started: False` and no reason at
    #   all. This session lost a full build-and-restart cycle to a package
    #   permission notice sitting silently behind the return value.
    #
    #   Reported, not dismissed. Closing a dialog nobody read is how an agent
    #   agrees to something on the user's behalf; naming it is how the person
    #   who can decide finds out there is something to decide.
    #]]
    if not play_sessions:
        try:
            from rqe.capture import Win32CaptureBackend

            backend = Win32CaptureBackend()
            blocking = [
                popup.title.strip()
                for window in backend.studio_windows()
                for popup in backend.modal_windows(window)
                if popup.title.strip()
            ]
            if blocking:
                result["blockedBy"] = blocking
                result["reason"] = (
                    "a Studio dialog is holding the window, so F5 never reached "
                    "the editor: " + "; ".join(sorted(set(blocking)))
                )
        except Exception:
            pass

    return result



def start_play_solo(
    bridge: Any | None = None,
    wait_seconds: float = 90.0,
    restart: bool = False,
    allow_foreground_fallback: bool = False,
) -> dict[str, Any]:
    """Start a real-player session through StudioTestService by default."""
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
            stopped = stop_play_solo(
                bridge,
                allow_foreground_fallback=allow_foreground_fallback,
            )
            if not stopped.get("stopped") and not allow_foreground_fallback:
                return {
                    "started": False,
                    "native": False,
                    "controller": "StudioTestService",
                    "foregroundFallbackUsed": False,
                    "reason": "a previous runtime session could not be stopped natively",
                    "stoppedPrevious": stopped,
                }
            time.sleep(1.0)

    installed: dict[str, Any] | None = None
    if bridge is not None:
        def client_script_present() -> bool:
            try:
                children = bridge.call(
                    "instance.children",
                    {"path": "StarterPlayer.StarterPlayerScripts"},
                    timeout=20,
                )
            except Exception:
                return False
            return isinstance(children, dict) and any(
                str(item.get("name")) == "RQEClientBridge"
                for item in (children.get("children") or [])
                if isinstance(item, dict)
            )

        try:
            edit_sessions = [
                item for item in bridge.status().get("sessions", [])
                if item.get("context") == "edit"
            ]
            if edit_sessions:
                bridge.pinned_session = str(edit_sessions[0]["session"])
            with bridge.lease_scope(
                agent_id="studio-lifecycle-install-client",
                context="edit",
                session_id=getattr(bridge, "pinned_session", None),
                ttl_seconds=120.0,
            ):
                detail = bridge.call("bridge.install_client", timeout=40)
                present = client_script_present()
                if not present:
                    time.sleep(1.0)
                    detail = bridge.call("bridge.install_client", timeout=40)
                    present = client_script_present()
            installed = {"ok": present, "verified": present, "detail": detail}
            if not present:
                installed["error"] = (
                    "bridge.install_client reported success but "
                    "StarterPlayerScripts.RQEClientBridge is not in the place"
                )
        except Exception as exc:
            installed = {"ok": False, "error": str(exc)}

    native_attempt: dict[str, Any] | None = None
    if bridge is not None:
        try:
            sessions = bridge.status().get("sessions", [])
            edit_sessions = [
                item for item in sessions
                if item.get("context") == "edit" and int(item.get("polls") or 0) > 0
            ]
            if edit_sessions:
                edit_id = str(edit_sessions[0]["session"])
                bridge.pinned_session = edit_id
                capabilities = bridge.call("bridge.capabilities", {}, timeout=15)
                methods = set(capabilities.get("methods") or [])
                if "test.start" in methods:
                    known = {str(item.get("session")) for item in sessions}
                    with bridge.lease_scope(
                        agent_id="studio-lifecycle-native-play",
                        session_id=edit_id,
                        ttl_seconds=60.0,
                        release_required=False,
                    ):
                        native_attempt = bridge.call(
                            "test.start",
                            {
                                "mode": "play",
                                "players": 1,
                                "args": {"source": "rqe.hub.lifecycle"},
                            },
                            timeout=20,
                        )

                    started_at = time.monotonic()
                    deadline = started_at + wait_seconds
                    while time.monotonic() < deadline:
                        current = bridge.status().get("sessions", [])
                        live = [
                            item for item in current
                            if item.get("context") in {"server", "client", "run"}
                            and str(item.get("session")) not in known
                        ]
                        if live:
                            bridge.pinned_session = str(live[0]["session"])
                            result = {
                                "started": True,
                                "native": True,
                                "controller": "StudioTestService",
                                "foregroundFallbackUsed": False,
                                "test": native_attempt,
                                "seconds": round(time.monotonic() - started_at, 2),
                                "playSessions": live,
                                "newSessions": [item["session"] for item in live],
                                "existingSessions": [],
                            }
                            if installed is not None:
                                result["clientBridge"] = installed
                            if stopped is not None:
                                result["stoppedPrevious"] = stopped
                            return result
                        time.sleep(0.5)
                    native_attempt = {
                        "fallback": True,
                        "error": "StudioTestService did not produce a running session before timeout",
                        "test": native_attempt,
                    }
                else:
                    native_attempt = {
                        "fallback": True,
                        "error": "connected plugin does not expose test.start",
                    }
            else:
                native_attempt = {
                    "fallback": True,
                    "error": "no healthy edit bridge session is available",
                }
        except Exception as exc:
            native_attempt = {
                "fallback": True,
                "error": f"{type(exc).__name__}: {exc}",
            }

    if not allow_foreground_fallback:
        result = {
            "started": False,
            "native": False,
            "controller": "StudioTestService",
            "foregroundFallbackUsed": False,
            "reason": (
                "native StudioTestService start was unavailable or did not "
                "produce a running session; foreground F5 fallback is disabled"
            ),
            "nativeAttempt": native_attempt,
        }
        if installed is not None:
            result["clientBridge"] = installed
        if stopped is not None:
            result["stoppedPrevious"] = stopped
        return result

    legacy = _start_play_solo_foreground_legacy(
        bridge,
        wait_seconds=wait_seconds,
        restart=False,
    )
    legacy["native"] = False
    legacy["foregroundFallbackUsed"] = True
    legacy["nativeAttempt"] = native_attempt
    if installed is not None:
        legacy["clientBridge"] = installed
    if stopped is not None:
        legacy["stoppedPrevious"] = stopped
    return legacy



def ensure_studio_session(
    place: Path | str,
    archive_root: Path | str,
    bridge: Any,
    wait_seconds: float = 45.0,
    *,
    background: bool = True,
    allow_cold_launch: bool = False,
    required_methods: tuple[str, ...] = (
        "test.start",
        "test.status",
        "test.finish",
        "studio.capture_background",
    ),
) -> dict[str, Any]:
    """Reuse one exact, healthy Studio build without surprising foreground UI.

    Cold launch is opt-in because Roblox Studio can raise its own window after
    Windows creates the process, even when the process starts minimized. Normal
    playtest/capture loops should keep one RQE-owned edit session warm and use
    StudioTestService/StudioCaptureService inside that process.
    """
    from .install import plugin_build_identity

    place = Path(place).resolve()
    expected = plugin_build_identity(Path(__file__).resolve().parents[2])
    owned, ignored = _owned_studio_processes()
    matching = [
        item for item in owned
        if Path(str(item.get("place") or "")).resolve() == place
    ]

    try:
        sessions = bridge.status().get("sessions", [])
    except Exception as exc:
        sessions = []
        status_error = str(exc)
    else:
        status_error = None

    def place_name(item: dict[str, Any]) -> str:
        place_info = item.get("place")
        if not isinstance(place_info, dict):
            return ""
        return str(place_info.get("name") or "").strip().casefold()

    def session_matches_place(item: dict[str, Any]) -> bool:
        name = place_name(item)
        expected_names = {
            place.stem.casefold(),
            place.name.casefold(),
        }
        return bool(name and name in expected_names)

    def is_local_file_placeholder(item: dict[str, Any]) -> bool:
        # A place opened from a file is always named "Game", with place id 0.
        # That label cannot tell two local places apart, so it is only accepted
        # when this file has the one owned process and the one such session.
        place_info = item.get("place")
        if not isinstance(place_info, dict) or place_name(item) != "game":
            return False
        try:
            place_id = int(place_info.get("id") or 0)
        except (TypeError, ValueError):
            return False
        return place_id == 0

    def polling_edit(item: dict[str, Any]) -> bool:
        return item.get("context") == "edit" and int(item.get("polls") or 0) > 0

    named_edits = [
        item for item in sessions
        if polling_edit(item) and session_matches_place(item)
    ]
    placeholder_edits = [
        item for item in sessions
        if polling_edit(item) and is_local_file_placeholder(item)
    ]
    if named_edits:
        edit_sessions = named_edits
    elif len(matching) == 1 and len(placeholder_edits) == 1:
        edit_sessions = placeholder_edits
    else:
        edit_sessions = []
    compatible = [
        item for item in edit_sessions
        if item.get("pluginVersion") == expected["pluginVersion"]
        and item.get("pluginBuildId") == expected["pluginBuildId"]
    ]

    if matching and compatible:
        selected = compatible[0]
        bridge.pinned_session = str(selected["session"])
        capabilities = bridge.call("bridge.capabilities", {}, timeout=15)
        methods = set(capabilities.get("methods") or [])
        missing = sorted(set(required_methods) - methods)
        if not missing:
            if background:
                minimize_studio()
            return {
                "ready": True,
                "reused": True,
                "coldLaunched": False,
                "session": selected["session"],
                "process": matching[0],
                "plugin": expected,
                "capabilitiesVerified": sorted(required_methods),
                "ignoredReceipts": ignored,
            }
        stale_reason = (
            "connected plugin is missing native methods: " + ", ".join(missing)
        )
    elif edit_sessions:
        stale_reason = (
            "connected edit session does not match the installed plugin build "
            f"{expected['pluginVersion']} / {expected['pluginBuildId']}"
        )
    elif matching:
        stale_reason = (
            "matching Studio process exists but no healthy edit bridge session "
            "is polling"
        )
    else:
        stale_reason = "no matching RQE-owned Studio process is available"

    if not allow_cold_launch:
        return {
            "ready": False,
            "reused": False,
            "coldLaunched": False,
            "needsColdLaunch": True,
            "reason": stale_reason,
            "plugin": expected,
            "statusError": status_error,
            "editSessions": edit_sessions,
            "matchingProcesses": matching,
            "ignoredReceipts": ignored,
        }

    restarted = restart_for_bridge(
        place,
        archive_root,
        bridge=bridge,
        wait_seconds=wait_seconds,
        background=background,
    )
    # A blocked restart never launched. Leave that result alone: marking it
    # ready from an empty handshake used to hide a verifier failure.
    if restarted.get("blocked"):
        return restarted

    handshake = restarted.get("handshake")
    if not isinstance(handshake, dict):
        handshake = {}
    fresh = [
        item for item in (handshake.get("sessions") or [])
        if isinstance(item, dict) and item.get("session")
    ]
    restarted["reused"] = False
    restarted["coldLaunched"] = True
    # Any polling session is not a capable plugin. The reuse path above
    # refuses a build that is missing test.start or studio.capture_background;
    # a cold launch has to apply the same gate or a handshake looks ready.
    if not fresh:
        restarted["ready"] = False
        return restarted

    selected = fresh[0]
    bridge.pinned_session = str(selected["session"])
    capabilities = bridge.call("bridge.capabilities", {}, timeout=15)
    methods = set(capabilities.get("methods") or [])
    missing = sorted(set(required_methods) - methods)
    if missing:
        restarted["ready"] = False
        restarted["reason"] = (
            "connected plugin is missing native methods: " + ", ".join(missing)
        )
        return restarted
    restarted["ready"] = True
    return restarted


def ensure_for_bridge(
    place: Path | str,
    archive_root: Path | str,
    bridge: Any,
    wait_seconds: float = 120.0,
    background: bool = True,
    required_methods: tuple[str, ...] = (
        "test.start",
        "test.status",
        "test.finish",
        "studio.capture_background",
    ),
    *,
    allow_cold_launch: bool = False,
) -> dict[str, Any]:
    """Compatibility alias for the single persistent-session policy."""
    return ensure_studio_session(
        place,
        archive_root,
        bridge,
        wait_seconds=wait_seconds,
        background=background,
        allow_cold_launch=allow_cold_launch,
        required_methods=required_methods,
    )


def restart_for_bridge(
    place: Path | str,
    archive_root: Path | str,
    bridge: Any | None = None,
    wait_seconds: float = 180.0,
    background: bool = True,
) -> dict[str, Any]:
    """Stop Studio, clear what blocks an unattended start, launch, and connect.

    With a ``bridge`` the call returns only once the plugin has handshaken, so
    the caller knows Studio is genuinely ready rather than merely launched.

    Paths are coerced rather than demanded. This is the first call in the
    documented restart flow, and it used to raise ``TypeError`` on a plain
    string -- which every example of a path in a shell or a JSON payload is.
    Refusing the obvious spelling of an argument at the entry point to a
    workflow is a defect in the workflow, not in the caller.
    """
    #: Tens of seconds each. Counted separately from bridge calls so a
    #: reader can tell a slow run from a chatty one.
    from ..ledger import record_studio_restart

    record_studio_restart()

    place = Path(place)
    archive_root = Path(archive_root)
    steps: dict[str, Any] = {}

    #: Before anything else: a restart that talks to a dead hub fails at every
    #: step for a reason none of the steps name.
    steps["hub"] = ensure_hub(place)

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

    # The signature check used to live inside launch_studio, which runs only
    # after stop_studio. A PowerShell or Authenticode failure then left Studio
    # dead and reported nothing but the executable path. Resolve it first, and
    # if it cannot be verified, leave the running Studio alone.
    try:
        studio_executable()
    except (OSError, RuntimeError) as exc:
        steps.update(_blocked_executable_verification(exc))
        return steps

    steps["stop"] = stop_studio()
    if steps["stop"].get("wasRunning") and not steps["stop"].get("stopped"):
        steps["blocked"] = True
        steps["reason"] = steps["stop"].get("reason") or "Studio could not be stopped safely"
        steps["handshake"] = {"waited": False, "sessions": []}
        return steps

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

    background_guard_minimizations = 0
    if background:
        background_guard_minimizations += minimize_studio()

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
        # Cold launch is still best-effort on Windows: Studio may create/raise
        # windows after process startup. Minimize immediately after launch and
        # once again after the plugin handshake. Normal automation should reuse
        # a persistent session instead of cold launching.
        steps["minimized"] = minimize_studio()
        steps["backgroundGuardMinimizations"] = background_guard_minimizations

    return steps


def start_multi_client_session(
    bridge: Any,
    client_count: int = 2,
    wait_seconds: float = 120.0,
) -> dict[str, Any]:
    """Compatibility entry point for native StudioTestService multiplayer."""
    from . import teamtest

    return teamtest.start(
        bridge,
        clients=client_count,
        timeout=wait_seconds,
        allow_foreground_fallback=False,
    )

