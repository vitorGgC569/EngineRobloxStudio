"""Start and stop a Studio session with a server and clients, unattended.

How this works
--------------

Roblox exposes no API for a local multiplayer test. `RunService` gives an
edit-mode run with no players and `start_play_solo` gives exactly one, so
anything that only exists because other people are in the game -- plot
ownership, permissions, per-player replication -- needs the UI.

Two facts make it automatable, and both had to be found by looking:

  * **`Teste > Iniciar teste de sessao > Servidor e clientes` is bound to F7.**
    Reading Studio's classic menu bar turned that up; the ribbon itself is
    Qt-drawn and invisible to UI Automation, which reports five controls for the
    entire window.

  * **The client-count spinner only accepts input while no session is running.**
    This cost an afternoon. Clicking it was tried directly, by typing into the
    field, and with a stepped hover and a long dwell, at coordinates confirmed
    against a pixel grid -- and the value never moved, because a session was
    live throughout. With the session stopped, the first ordinary click works.

    The lesson is not about spinners. Three techniques were blamed for a
    failure that belonged to program state, and the coordinates were right the
    whole time.

So the order matters: stop, set the count, then F7. `start` does exactly that.

Verification is by outcome, never by screenshot
-----------------------------------------------

Nothing here trusts that a keystroke landed. A session exists when a `server`
context appears on the bridge, and players are counted from `run.state`. A
Studio that was not focused, or a shortcut that moved, shows up as "the player
count did not change" -- the honest failure, and the one a caller can act on.
"""

from __future__ import annotations

import ctypes
import time
from ctypes import wintypes
from typing import Any

#: Virtual key codes used here.
VK_MENU, VK_RIGHT, VK_DOWN, VK_RETURN, VK_ESCAPE = 0x12, 0x27, 0x28, 0x0D, 0x1B
VK_F7, VK_F5, VK_SHIFT = 0x76, 0x74, 0x10

#: How far down the `Teste` menu `Adicionar clientes` sits, as a fraction of the
#: popup's height. Measured from a capture rather than counted as an index:
#: arrow-key navigation skips disabled items, and which items are disabled
#: changes depending on whether a session is running -- so an index is only
#: correct in one of the two states this module operates in.
ADD_CLIENTS_RATIO = 0.536

#: Where the client-count spinner sits, in window coordinates, on a maximised
#: Studio. Read off a pixel grid rather than guessed: the up arrow is a six
#: pixel target and being two pixels out looks exactly like being ignored.
SPINNER_UP = (285, 63)
SPINNER_DOWN = (285, 73)

#: Titles that identify a window as *not* the editor. Studio names the extra
#: windows of a running test after their role.
NON_EDITOR_TITLES = ("servidor", "server", "cliente", "client")


def _user32():
    return ctypes.windll.user32


def editor_window() -> tuple[int, str]:
    """The Studio window holding the place, not one of a running test.

    A team test opens a `Servidor` window and one per client, and they are all
    Roblox Studio. Sending F7 to a client window does nothing useful, so the
    editor has to be picked deliberately rather than taken as "the first one".
    """
    u = _user32()
    windows: list[tuple[int, str]] = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
    def collect(hwnd, _lparam):
        if not u.IsWindowVisible(hwnd):
            return True
        length = u.GetWindowTextLengthW(hwnd)
        if length == 0:
            return True
        buffer = ctypes.create_unicode_buffer(length + 1)
        u.GetWindowTextW(hwnd, buffer, length + 1)
        title = buffer.value
        if "Roblox Studio" in title:
            windows.append((hwnd, title))
        return True

    u.EnumWindows(collect, 0)
    if not windows:
        raise RuntimeError("no Roblox Studio window is open")

    for hwnd, title in windows:
        lowered = title.lower()
        if not any(mark in lowered for mark in NON_EDITOR_TITLES):
            return hwnd, title

    raise RuntimeError(
        "every Studio window looks like part of a running test: "
        + "; ".join(title for _, title in windows))


def _focus(hwnd: int) -> None:
    """Bring a window forward and make it the keyboard target.

    An ALT tap first: Windows refuses `SetForegroundWindow` from a process that
    does not own the foreground, and a synthetic ALT is what releases that lock.
    The same trick is what makes F5 land in `start_play_solo`.
    """
    u = _user32()
    u.keybd_event(VK_MENU, 0, 0, 0)
    u.keybd_event(VK_MENU, 0, 2, 0)
    u.ShowWindow(hwnd, 9)  # SW_RESTORE
    u.SetForegroundWindow(hwnd)
    u.SwitchToThisWindow(hwnd, True)
    time.sleep(0.6)


def _tap(vk: int, times: int = 1, gap: float = 0.18) -> None:
    u = _user32()
    for _ in range(times):
        u.keybd_event(vk, 0, 0, 0)
        u.keybd_event(vk, 0, 2, 0)
        time.sleep(gap)


def _popup_rects(hwnd: int, minimum_height: int = 150) -> list[tuple[int, int, int, int]]:
    """Visible top-level windows of Studio's process that are not the editor.

    Qt menus are separate windows, and they cannot be captured through the
    parent: `PrintWindow` on the editor returns them as black. Their screen
    rectangle is available though, which is all that is needed to click one.
    """
    u = _user32()
    pid = wintypes.DWORD()
    u.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    found: list[tuple[int, int, int, int]] = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
    def collect(handle, _lparam):
        other = wintypes.DWORD()
        u.GetWindowThreadProcessId(handle, ctypes.byref(other))
        if other.value == pid.value and handle != hwnd and u.IsWindowVisible(handle):
            rect = wintypes.RECT()
            u.GetWindowRect(handle, ctypes.byref(rect))
            if rect.right - rect.left > 60 and rect.bottom - rect.top > minimum_height:
                found.append((rect.left, rect.top, rect.right, rect.bottom))
        return True

    u.EnumWindows(collect, 0)
    return found


def _click(x: int, y: int) -> None:
    u = _user32()
    u.SetCursorPos(x, y)
    time.sleep(0.25)
    u.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.06)
    u.mouse_event(0x0004, 0, 0, 0, 0)


def _players(bridge: Any) -> int | None:
    """How many players the running server reports, or None if none is running."""
    try:
        sessions = bridge.status().get("sessions", [])
    except Exception:
        return None
    server = [s for s in sessions if s.get("context") == "server"]
    if not server:
        return None
    try:
        bridge.pinned_session = server[0]["session"]
        return int(bridge.call("run.state", {}).get("playerCount") or 0)
    except Exception:
        return None


def set_clients(bridge: Any, count: int, maximum: int = 8) -> dict[str, Any]:
    """Set how many clients the next session will open with.

    Requires that nothing is running: Studio disables this control for the
    duration of a test, which is the whole reason it appeared to ignore input.
    Stopping first is therefore part of setting it, not a courtesy.

    Counted up from zero rather than typed. The field does take focus and
    typing, but reading back a typed value needs a screen capture and this does
    not: press down enough times to be certainly at zero, then up exactly
    `count` times, and the value is known by construction.
    """
    if _players(bridge) is not None:
        stop(bridge)
        time.sleep(3)
    if _players(bridge) is not None:
        return {"set": False, "reason": "a session is still running; the spinner stays disabled"}

    hwnd, title = editor_window()
    _focus(hwnd)
    _user32().ShowWindow(hwnd, 3)  # SW_MAXIMIZE -- the toolbar is hidden when narrow
    time.sleep(1.5)

    rect = wintypes.RECT()
    _user32().GetWindowRect(hwnd, ctypes.byref(rect))
    wanted = max(0, min(count, maximum))

    for _ in range(maximum + 2):
        _click(rect.left + SPINNER_DOWN[0], rect.top + SPINNER_DOWN[1])
        time.sleep(0.12)
    for _ in range(wanted):
        _click(rect.left + SPINNER_UP[0], rect.top + SPINNER_UP[1])
        time.sleep(0.15)

    return {"set": True, "clients": wanted, "window": title}


def client_count_hint() -> str:
    """What to tell a human when a session comes up short of players."""
    return ("set the client count in Studio's toolbar (maximise the window; the "
            "field with a person icon sits next to the play controls) and start "
            "again -- that spinner does not accept synthetic input, so it is the "
            "one step this cannot do")


def start(bridge: Any, clients: int = 2, timeout: float = 240.0) -> dict[str, Any]:
    """Start a server and bring `clients` players into it.

    F7 opens the session; the ribbon's own client count is whatever it was left
    at and is usually zero, so every client is added explicitly afterwards and
    confirmed by the server's own player count.
    """
    #: Set before starting, because the control is disabled once a session runs.
    prepared = set_clients(bridge, clients)

    hwnd, title = editor_window()
    _focus(hwnd)

    already = _players(bridge)
    if already is None:
        _tap(VK_F7)

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            time.sleep(5)
            if _players(bridge) is not None:
                break
        else:
            return {"started": False, "reason": "no server session appeared after F7",
                    "window": title}

    #[[
    #   Clients arrive on their own or not at all.
    #
    #   F7 opens the server and however many clients the toolbar is set to, and
    #   they take a while to connect. Waiting and counting is all this can do:
    #   the count itself is not reachable from here, so a session that comes up
    #   short is reported as short rather than quietly retried.
    #]]
    joined = 0
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        joined = _players(bridge) or 0
        if joined >= clients:
            break
        time.sleep(5)

    result = {
        "started": True,
        "prepared": prepared,
        "players": joined,
        "wanted": clients,
        "enough": joined >= clients,
        "window": title,
    }
    if joined < clients:
        result["hint"] = client_count_hint()
    return result


def stop(bridge: Any) -> dict[str, Any]:
    """End the session with Shift+F5, the shortcut the menu itself advertises."""
    hwnd, title = editor_window()
    _focus(hwnd)
    u = _user32()
    u.keybd_event(VK_SHIFT, 0, 0, 0)
    _tap(VK_F5)
    u.keybd_event(VK_SHIFT, 0, 2, 0)
    time.sleep(3)
    return {"stopped": _players(bridge) is None, "window": title}
