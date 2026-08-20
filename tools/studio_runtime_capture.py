from __future__ import annotations

import argparse
import ctypes
import json
import subprocess
import time
from ctypes import wintypes
from pathlib import Path
from typing import Any

from PIL import ImageGrab


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".tmp" / "MinersRidgeTycoon-qa-v7.rbxlx"
OUTPUT = ROOT / "reports" / "studio-runtime"
USER32 = ctypes.windll.user32 if hasattr(ctypes, "windll") else None


def enum_studio_windows() -> list[tuple[int, str]]:
    if USER32 is None:
        return []
    windows: list[tuple[int, str]] = []
    enum_proc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    @enum_proc
    def callback(hwnd, _lparam):
        length = USER32.GetWindowTextLengthW(hwnd)
        if length <= 0:
            return True
        buffer = ctypes.create_unicode_buffer(length + 1)
        USER32.GetWindowTextW(hwnd, buffer, length + 1)
        title = buffer.value
        if USER32.IsWindowVisible(hwnd) and "roblox studio" in title.lower():
            windows.append((int(hwnd), title))
        return True

    USER32.EnumWindows(callback, 0)
    return windows


def focus_studio() -> tuple[int, str] | None:
    windows = enum_studio_windows()
    if not windows:
        return None
    windows.sort(key=lambda item: (".rbxlx" not in item[1].lower(), -len(item[1])))
    hwnd, title = windows[0]
    USER32.ShowWindow(hwnd, 9)
    USER32.SetForegroundWindow(hwnd)
    time.sleep(0.5)
    return hwnd, title


def window_rect(hwnd: int) -> tuple[int, int, int, int]:
    rect = wintypes.RECT()
    if not USER32.GetWindowRect(hwnd, ctypes.byref(rect)):
        raise RuntimeError("não foi possível ler a área da janela do Studio")
    return rect.left, rect.top, rect.right, rect.bottom


def key_event(vk: int, down: bool) -> None:
    USER32.keybd_event(vk, 0, 0 if down else 2, 0)


def press(vk: int, modifiers: tuple[int, ...] = ()) -> None:
    for modifier in modifiers:
        key_event(modifier, True)
    key_event(vk, True)
    key_event(vk, False)
    for modifier in reversed(modifiers):
        key_event(modifier, False)


def hold(vk: int, duration: float) -> None:
    key_event(vk, True)
    time.sleep(duration)
    key_event(vk, False)


def set_clipboard(value: str) -> None:
    subprocess.run(
        ["powershell", "-NoProfile", "-Command", "Set-Clipboard", "-Value", value],
        check=True,
        capture_output=True,
        text=True,
    )


def capture(hwnd: int, filename: str) -> dict[str, Any]:
    rect = window_rect(hwnd)
    image = ImageGrab.grab(bbox=rect, include_layered_windows=True)
    path = OUTPUT / filename
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "PNG", optimize=True)
    return {"file": filename, "width": image.width, "height": image.height, "bytes": path.stat().st_size}


def open_build(hwnd: int) -> None:
    if not BUILD.exists():
        raise FileNotFoundError(f"build ausente: {BUILD}")
    # Reuse the current Studio window and its native Open Place dialog.
    press(ord("O"), modifiers=(0x11,))
    time.sleep(1.2)
    set_clipboard(str(BUILD))
    press(ord("V"), modifiers=(0x11,))
    time.sleep(0.4)
    press(0x0D)
    time.sleep(12)
    USER32.SetForegroundWindow(hwnd)


def run(play: bool) -> dict[str, Any]:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    target = focus_studio()
    if not target:
        return {"status": "BLOCKED", "reason": "Roblox Studio não está aberto", "liveStudioCapture": False}
    hwnd, title = target
    captures = [capture(hwnd, "studio-open.png")]
    # Do not open a second Studio window when the requested QA place is already loaded.
    if BUILD.name.lower() not in title.lower():
        open_build(hwnd)
        hwnd, title = focus_studio() or (hwnd, title)
    captures.append(capture(hwnd, "studio-project-loaded.png"))
    if play:
        # F5 reuses this Studio window and starts the current place playtest.
        press(0x74)
        time.sleep(15)
        captures.append(capture(hwnd, "spawn-runtime.png"))
        # Small human-mode movement samples for a second frame, without teleporting or white-box access.
        hold(ord("W"), 1.2)
        hold(ord("D"), 0.8)
        captures.append(capture(hwnd, "route-runtime.png"))
    manifest = {
        "captureType": "studio-window-runtime",
        "liveStudioCapture": bool(play and any(item["file"] == "spawn-runtime.png" for item in captures)),
        "studioWindowTitle": title,
        "build": str(BUILD),
        "snapshots": captures,
        "issues": [],
    }
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return {"status": "PASS" if manifest["liveStudioCapture"] else "WARN", **manifest}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--play", action="store_true", help="inicia F5 na instância já aberta")
    args = parser.parse_args()
    print(json.dumps(run(args.play), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
